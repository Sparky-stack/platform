#!/usr/bin/env python3
# Auto-build trigger (addon openchoreo-platform, Argo WorkflowTemplate auto-build; docs/build-plane.md "Auto-build").
#
# One reconcile pass: for every Component in the org namespace with spec.autoBuild: true (OpenChoreo's own opt-in, the
# flag its webhook honours), read the head of the Component's build branch on GitHub and create the build WorkflowRun
# for that commit unless it is already built. Both triggers run exactly this pass:
#   poll     CronWorkflow auto-build-poll (installations without inbound webhooks, e.g. the local k3d stack)
#   webhook  Argo Events Sensor auto-build (addon argo-events) on a GitHub push, REPOSITORY = the pushed repo; the
#            payload only selects the repository, the head is read from GitHub like a poll
# so the build path is the same whichever trigger an installation selects.
#
# Idempotent per commit:
#   - the WorkflowRun is named <component>-<sha[:12]>: a second create for the same commit is AlreadyExists;
#   - "already built" is read from git, not from cluster state: the Workload file at the head commit carries
#     spec.source.commit (written by the build's GitOps hand-off); if every change since that commit is inside the
#     GitOps directory (the hand-off commit itself, promotions) there is nothing to build;
#   - while an auto-build run of the component is still running, no second one starts (no out-of-order image bumps);
#   - "built" also means the image is still there: when the Workload pins an image of the platform registry
#     (REGISTRY_HOST) whose digest that registry does not have (a clean bootstrap: git pins an artifact of the previous
#     stack's Harbor), the Workload's own spec.source.commit is rebuilt (never the branch head, which is a GitOps-only
#     commit the build's checkout skips) as WorkflowRun <component>-<sha[:12]>-<digest[:8]>: one rebuild per missing
#     digest. The hand-off then commits the new digest. Unknown answers (registry down, no credentials) never rebuild.
#     A failed rebuild is retried (-r2, -r3, REBUILD_RETRY_SECONDS apart): until one succeeds the environment pulls a
#     missing image, so one killed pod must not leave it there. After REBUILD_ATTEMPTS failures the pass logs and
#     exits non-zero once per head. A failed build never changes what is deployed: only its signed hand-off does.
# The ConfigMap STATE_CONFIGMAP is only a cache (branch ETags, last handled head per component): GitHub answers a
# conditional request with 304 when nothing changed, which does not count against the rate limit. Losing it costs API
# calls, never a duplicate build.
#
# GitHub: a short-lived installation token (contents: read) minted and rotated by ESO (GithubAccessToken generator
# from the platform's GitHub App), mounted at TOKEN_FILE. This script never sees the App's private key.
# Kubernetes: the pod's ServiceAccount (list Components, get ClusterWorkflows, create WorkflowRuns, one ConfigMap).
# Registry: a pull-only robot (REGISTRY_AUTH_DIR username/password) and the registry CA (REGISTRY_CA_FILE); one manifest
# HEAD per up-to-date component and pass.
#
# PR previews (PREVIEWS=true, docs/preview-environments.md): the same pass then walks the preview Applications Argo CD
# generated for open pull requests (ApplicationSet previews-<project>, charts/tenant) and, per PR head commit, builds it
# (WorkflowRun <component>-pr<n>-<sha[:12]>, GitOps hand-off off: nothing is written to the repo), cuts ComponentRelease
# <component>-pr-<n>-<sha[:12]> from the Component's latest release with the PR image (owned by the preview
# Environment, so it goes with it), posts commit status openchoreo/preview with the preview URL, and expires the
# preview after the TTL by labelling the PR (the Application then renders empty and Argo CD prunes it). It re-checks
# the Component's opt-in annotation and never builds pull requests from forks. GitHub: a second token (statuses,
# pull requests) at PREVIEW_TOKEN_FILE.
#
# Stdlib only. The WorkflowTemplate embeds this file in an Argo template: the source must not contain two opening
# braces (hack/tests/test_workflow_scripts.sh).
import base64
import datetime as dt
import json
import os
import posixpath
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

EXT = "x-openchoreo-component-parameter-repository-"
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
GITHUB_URL_RE = re.compile(r"^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+?)(\.git)?/?$")
COMMIT_LINE_RE = re.compile(r"^\s+commit:\s*[\"']?([0-9a-f]{7,40})[\"']?\s*(#.*)?$", re.M)
IMAGE_LINE_RE = re.compile(r"^\s+image:\s*[\"']?([^\s\"'#]+)[\"']?\s*(#.*)?$", re.M)
IMAGE_REF_RE = re.compile(r"^([A-Za-z0-9.-]+(?::[0-9]{1,5})?)/([a-z0-9]+(?:[._/-][a-z0-9]+)*)"
                          r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@(sha256:[0-9a-f]{64})$")
MANIFEST_TYPES = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                            "application/vnd.docker.distribution.manifest.list.v2+json",
                            "application/vnd.docker.distribution.manifest.v2+json"])
TRIGGER_LABEL = "platform.koorikla.io/trigger"
COMMIT_ANNOTATION = "platform.koorikla.io/commit"
DEFAULT_WORKLOAD_PATH = "deploy/openchoreo/workload.yaml"
REBUILD_ATTEMPTS = 3          # runs per missing digest: a failed rebuild (k3s restart mid-bootstrap) is retried
REBUILD_RETRY_SECONDS = 300   # wait after a failed attempt before the next one
PREVIEW_LABEL = "platform.koorikla.io/preview"
EXPIRES_LABEL = "platform.koorikla.io/expires-at"
PR_LABEL = "platform.koorikla.io/pull-request"
COMPONENT_LABEL = "platform.koorikla.io/component"
REPOSITORY_ANNOTATION = "platform.koorikla.io/repository"
RELEASE_ANNOTATION = "platform.koorikla.io/release"
# On a ResourceReleaseBinding: "latest" = the pass keeps spec.resourceRelease on the Resource's latest ResourceRelease.
RESOURCE_RELEASE_ANNOTATION = "platform.koorikla.io/resource-release"
NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
NUMBER_RE = re.compile(r"^[1-9][0-9]{0,6}$")
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$")


def env(name, default=""):
    return os.environ.get(name, default).strip()


def log(msg):
    print(msg, flush=True)


class Failed(Exception):
    pass


class RateLimited(Failed):
    pass


# --- pure helpers (unit-tested in test_auto_build.py) -----------------------------------------------------------------
def extension_paths(schema, prefix=""):
    """Dotted parameter paths marked x-openchoreo-component-parameter-repository-<kind>: {kind: path}."""
    out = {}
    for name, prop in ((schema or {}).get("properties") or {}).items():
        if not isinstance(prop, dict):
            continue
        path = prefix + name
        for key, value in prop.items():
            if key.startswith(EXT) and value is True:
                out[key[len(EXT):]] = path
        out.update(extension_paths(prop, path + "."))
    return out


def get_path(obj, dotted):
    cur = obj
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def set_path(obj, dotted, value):
    """Copy of obj with obj[dotted] = value (intermediate maps created)."""
    out = json.loads(json.dumps(obj or {}))
    cur = out
    parts = dotted.split(".")
    for part in parts[:-1]:
        if not isinstance(cur.get(part), dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value
    return out


def schema_default(schema, dotted):
    cur = schema or {}
    for part in dotted.split("."):
        cur = ((cur or {}).get("properties") or {}).get(part)
        if not isinstance(cur, dict):
            return None
    return cur.get("default")


def repo_slug(url, allowed_prefixes):
    """owner/name of a github.com repository URL under one of the allowed prefixes, else None."""
    if not isinstance(url, str):
        return None
    m = GITHUB_URL_RE.match(url)
    if not m or ".." in m.group(2):
        return None
    canonical = "https://github.com/%s/%s" % (m.group(1), m.group(2))
    if not any(canonical.lower().startswith(p.lower()) for p in allowed_prefixes):
        return None
    return "%s/%s" % (m.group(1), m.group(2))


def run_name(component, sha):
    return "%s-%s" % (component[:40].rstrip("-"), sha[:12])


def workload_commit(text):
    """spec.source.commit of a Workload manifest (first `commit:` line), or None."""
    m = COMMIT_LINE_RE.search(text or "")
    return m.group(1) if m else None


def workload_image(text):
    """spec.container.image of a Workload manifest (first `image:` line), or None."""
    m = IMAGE_LINE_RE.search(text or "")
    return m.group(1) if m else None


def image_parts(ref):
    """(registry host, repository, digest) of a <host>/<repository>[:tag]@sha256:<digest> reference, else None."""
    m = IMAGE_REF_RE.match(ref or "")
    return (m.group(1).lower(), m.group(2), m.group(3)) if m else None


def rebuild_name(component, sha, digest, attempt=1):
    """WorkflowRun that rebuilds `sha` because `digest` is missing: one per (commit, missing digest), plus a suffixed
    run per retry after a failed attempt (-r2, -r3; the component is cut 3 characters shorter to stay <= 63)."""
    if attempt <= 1:
        return "%s-%s-%s" % (component[:40].rstrip("-"), sha[:12], digest.split(":")[-1][:8])
    return "%s-%s-%s-r%d" % (component[:37].rstrip("-"), sha[:12], digest.split(":")[-1][:8], attempt)


def bearer_challenge(header):
    """{realm, service, scope} of a `WWW-Authenticate: Bearer ...` challenge, or None."""
    if not (header or "").lower().startswith("bearer "):
        return None
    return dict((k.lower(), v) for k, v in re.findall(r'([A-Za-z]+)="([^"]*)"', header[7:]))


def only_under(files, directory):
    """True when every changed path is inside directory (and there is at least one)."""
    directory = directory.strip("/")
    if not files or not directory or directory == ".":
        return False
    return all(f == directory or f.startswith(directory + "/") for f in files)


def completed(run):
    for c in (run.get("status") or {}).get("conditions") or []:
        if c.get("type") == "WorkflowCompleted" and c.get("status") == "True":
            return True
    return False


def parse_time(value):
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    except (TypeError, ValueError):
        return None


def build_run(component, namespace, paths, sha, labels, name=None, overrides=None):
    """The WorkflowRun OpenChoreo's own trigger would create for this commit, with a deterministic name.
    overrides: {dotted parameter path: value} on top (previews: gitops.enabled false)."""
    wf = component["spec"]["workflow"]
    params = wf.get("parameters") or {}
    if "commit" in paths:
        params = set_path(params, paths["commit"], sha)
    for path, value in sorted((overrides or {}).items()):
        params = set_path(params, path, value)
    comp = component["metadata"]["name"]
    return {
        "apiVersion": "openchoreo.dev/v1alpha1",
        "kind": "WorkflowRun",
        "metadata": {
            "name": name or run_name(comp, sha),
            "namespace": namespace,
            "labels": dict(labels, **{
                "openchoreo.dev/project": component["spec"]["owner"]["projectName"],
                "openchoreo.dev/component": comp,
            }),
            "annotations": {COMMIT_ANNOTATION: sha},
        },
        "spec": {"workflow": {"kind": wf.get("kind") or "Workflow", "name": wf["name"], "parameters": params}},
    }


# --- reconcile --------------------------------------------------------------------------------------------------------
class Reconciler:
    """One pass over the Components. `api` provides the cluster and GitHub calls (fake in tests)."""

    def __init__(self, api, namespace, allowed_prefixes, state, repository="", max_runs=5, stale_seconds=7200,
                 labels=None, now=None, registry_host=""):
        self.api = api
        self.registry_host = registry_host.lower()
        self.namespace = namespace
        self.allowed = allowed_prefixes
        self.state = state
        self.state.setdefault("heads", {})
        self.state.setdefault("components", {})
        self.repository = repository.lower()
        self.max_runs = max_runs
        self.stale = dt.timedelta(seconds=stale_seconds)
        self.labels = labels or {TRIGGER_LABEL: "auto-build"}
        self.now = now or dt.datetime.now(dt.timezone.utc)
        self.created = []
        self.errors = []
        self._schemas = {}
        self._heads = {}

    def schema(self, kind, name):
        key = (kind, name)
        if key not in self._schemas:
            self._schemas[key] = self.api.workflow_schema(kind, name, self.namespace) or {}
        return self._schemas[key]

    def head(self, slug, branch):
        key = "%s@%s" % (slug, branch)
        if key not in self._heads:
            cached = self.state["heads"].get(key) or {}
            sha, etag = self.api.branch_head(slug, branch, cached.get("etag", ""))
            if sha is None:                       # 304 Not Modified
                sha = cached.get("sha")
            if not sha or not SHA_RE.match(sha):
                raise Failed("%s: no commit SHA for branch %s" % (slug, branch))
            self.state["heads"][key] = {"sha": sha, "etag": etag or cached.get("etag", "")}
            self._heads[key] = sha
        return self._heads[key]

    def busy(self, component):
        """Names of this component's auto-build runs that are still running (and not stale)."""
        out = []
        for run in self.api.component_runs(component, self.labels):
            if completed(run):
                continue
            started = parse_time((run.get("metadata") or {}).get("creationTimestamp"))
            if started and self.now - started > self.stale:
                continue
            out.append(run["metadata"]["name"])
        return out

    def record(self, name, sha, result, run="", image=""):
        self.state["components"][name] = {"sha": sha, "result": result, "run": run,
                                          "at": self.now.strftime("%Y-%m-%dT%H:%M:%SZ")}
        if image:
            self.state["components"][name]["image"] = image

    def missing(self, image):
        """True only when the platform registry says the image's digest does not exist (False: present, unknown, or
        not an image of the platform registry)."""
        parts = image_parts(image)
        if not self.registry_host or not parts or parts[0] != self.registry_host:
            return False
        return self.api.image_exists(*parts) is False

    def next_rebuild(self, name, commit, digest):
        """(run name, why not now) for the rebuild of `commit`: the first attempt without a run is created (why ""),
        a running or succeeded attempt waits; a failed attempt is retried after REBUILD_RETRY_SECONDS (the k3s restart
        that killed a step is long over), at most REBUILD_ATTEMPTS runs in total, then "failed"."""
        for attempt in range(1, REBUILD_ATTEMPTS + 1):
            rn = rebuild_name(name, commit, digest, attempt)
            run = self.api.get_run(rn)
            if run is None:
                return rn, ""
            if not completed(run):
                return rn, "is running"
            if succeeded(run):
                return rn, "succeeded (the hand-off commit follows)"
            done = parse_time((run.get("status") or {}).get("completedAt"))
            if attempt < REBUILD_ATTEMPTS and done and self.now - done < dt.timedelta(seconds=REBUILD_RETRY_SECONDS):
                return rn, "failed, retried after %ds" % REBUILD_RETRY_SECONDS
        return rn, "failed"

    def rebuild_failed(self, run_name_):
        run = self.api.get_run(run_name_) if run_name_ else None
        return bool(run) and completed(run) and not succeeded(run)

    def up_to_date(self, comp, paths, slug, sha, built, image):
        """The head needs no build of its own. Rebuild the Workload's commit `built` if its pinned image is gone."""
        name = comp["metadata"]["name"]
        if not self.missing(image):
            self.record(name, sha, "up-to-date", image=image or "")
            return
        commit = built if SHA_RE.match(built) else self.api.commit_sha(slug, built)
        rn, wait = self.next_rebuild(name, commit, image_parts(image)[2])
        if wait == "failed":
            # Every attempt failed: the environment stays on the pinned (missing) image, nothing newer is deployed.
            # Loud once per head; the next push (or deleting the failed runs) starts over.
            msg = ("%s: rebuild of %s %s for missing %s FAILED %d times (last WorkflowRun %s): the Workload keeps "
                   "pulling a missing image until the build is fixed" % (name, slug, commit[:12], image,
                                                                         REBUILD_ATTEMPTS, rn))
            log(msg)
            self.errors.append(msg)
            self.record(name, sha, "rebuild-failed", rn)
            return
        if wait:
            log("%s: %s is not in the registry; rebuild %s %s" % (name, image, rn, wait))
            self.record(name, sha, "rebuilt", rn)
            return
        if len(self.created) >= self.max_runs:
            log("%s: build budget of this pass (%d) used, next pass" % (name, self.max_runs))
            return
        created = self.api.create_run(build_run(comp, self.namespace, paths, commit, self.labels, name=rn))
        log("%s: %s is not in the registry: rebuild of %s %s -> WorkflowRun %s%s"
            % (name, image, slug, commit[:12], rn, "" if created else " (already existed)"))
        self.created.append(rn)
        self.record(name, sha, "rebuilt", rn)

    def component(self, comp):
        name = comp["metadata"]["name"]
        spec = comp.get("spec") or {}
        if spec.get("autoBuild") is not True:
            return
        wf = spec.get("workflow") or {}
        if not wf.get("name"):
            log("%s: autoBuild without spec.workflow: skipped" % name)
            return
        schema = self.schema(wf.get("kind") or "Workflow", wf["name"])
        paths = extension_paths(schema)
        params = wf.get("parameters") or {}
        if "url" not in paths:
            log("%s: workflow %s marks no repository url parameter: skipped" % (name, wf["name"]))
            return
        slug = repo_slug(get_path(params, paths["url"]), self.allowed)
        if not slug:
            log("%s: repository %r is not a github.com repository under %s: skipped"
                % (name, get_path(params, paths["url"]), " ".join(self.allowed)))
            return
        if self.repository and slug.lower() != self.repository:
            return
        branch = (get_path(params, paths["branch"]) if "branch" in paths else None) or \
            (schema_default(schema, paths["branch"]) if "branch" in paths else None)
        if not branch:
            log("%s: no build branch (parameter %s): skipped" % (name, paths.get("branch", "-")))
            return
        sha = self.head(slug, branch)
        last = self.state["components"].get(name) or {}
        recheck = (last.get("result") == "up-to-date" and self.missing(last.get("image"))) or \
            (last.get("result") == "rebuilt" and self.rebuild_failed(last.get("run")))
        if last.get("sha") == sha and not recheck:
            return                                  # nothing new since the last pass, the image is still there
        rn = run_name(name, sha)
        if self.api.run_exists(rn):
            log("%s: %s@%s %s already has WorkflowRun %s" % (name, slug, branch, sha[:12], rn))
            self.record(name, sha, "built", rn)
            return
        busy = self.busy(name)
        if busy:
            log("%s: %s %s waits for running %s" % (name, slug, sha[:12], ", ".join(busy)))
            return
        workload_path = get_path(params, "gitops.workloadPath") or schema_default(schema, "gitops.workloadPath")
        if not isinstance(workload_path, str) or not workload_path:
            workload_path = DEFAULT_WORKLOAD_PATH
        text = self.api.file_at(slug, workload_path, sha)
        built, image = workload_commit(text), workload_image(text)
        if built and (sha.startswith(built) or built.startswith(sha)):
            log("%s: %s %s is the built commit" % (name, slug, sha[:12]))
            self.up_to_date(comp, paths, slug, sha, built, image)
            return
        if built:
            files = self.api.changed_files(slug, built, sha)
            gitops_dir = posixpath.dirname(workload_path)
            if files is not None and only_under(files, gitops_dir):
                log("%s: %s %s changes only %s/ since built %s: nothing to build"
                    % (name, slug, sha[:12], gitops_dir, built[:12]))
                self.up_to_date(comp, paths, slug, sha, built, image)
                return
        if len(self.created) >= self.max_runs:
            log("%s: build budget of this pass (%d) used, next pass" % (name, self.max_runs))
            return
        run = build_run(comp, self.namespace, paths, sha, self.labels)
        created = self.api.create_run(run)
        log("%s: %s %s -> WorkflowRun %s%s" % (name, slug, sha[:12], rn, "" if created else " (already existed)"))
        self.created.append(rn)
        self.record(name, sha, "built", rn)

    def run(self):
        for comp in sorted(self.api.components(), key=lambda c: c["metadata"]["name"]):
            try:
                self.component(comp)
            except RateLimited:
                raise
            except Failed as e:
                log("%s: error: %s" % (comp["metadata"]["name"], e))
                self.errors.append(str(e))
        return self.created


# --- PR previews --------------------------------------------------------------------------------------------------------
def preview_names(component, number, sha):
    """(environment, binding, release, build run) of one PR head commit; charts/preview renders the same names."""
    return ("pr-%s-%s" % (number, component), "%s-pr-%s" % (component, number),
            "%s-pr-%s-%s" % (component, number, sha[:12]), "%s-pr%s-%s" % (component[:30].rstrip("-"), number, sha[:12]))


def succeeded(run):
    for c in (run.get("status") or {}).get("conditions") or []:
        if c.get("type") == "WorkflowSucceeded":
            return c.get("status") == "True"
    return False


def build_image(workflow):
    """The image ref (tag@digest) the koorikla-build `build` step reported, or None (step skipped / not found)."""
    for node in ((workflow or {}).get("status") or {}).get("nodes", {}).values():
        if node.get("templateName") == "build" and node.get("type") == "Pod" and node.get("phase") == "Succeeded":
            for p in (node.get("outputs") or {}).get("parameters") or []:
                if p.get("name") == "image" and "@sha256:" in (p.get("value") or ""):
                    return p["value"]
    return None


def preview_release(base, name, namespace, image, sha, branch, environment, labels):
    """ComponentRelease for the PR: the Component's latest release (platform type, traits, parameters) with the PR's
    image and commit. Owned by the preview Environment: deleting the preview deletes it."""
    spec = json.loads(json.dumps(base.get("spec") or {}))
    workload = spec.setdefault("workload", {})
    workload.setdefault("container", {})["image"] = image
    source = workload.setdefault("source", {})
    source["commit"] = sha
    if branch:
        source["branch"] = branch
    return {
        "apiVersion": "openchoreo.dev/v1alpha1",
        "kind": "ComponentRelease",
        "metadata": {
            "name": name, "namespace": namespace, "labels": labels,
            "annotations": {COMMIT_ANNOTATION: sha, "platform.koorikla.io/base-release": base["metadata"]["name"]},
            "ownerReferences": [{"apiVersion": "openchoreo.dev/v1alpha1", "kind": "Environment",
                                 "name": environment["metadata"]["name"], "uid": environment["metadata"]["uid"]}],
        },
        "spec": spec,
    }


def preview_resource_bindings(release, namespace, project, environment, labels):
    """One ResourceReleaseBinding per Resource the preview's ComponentRelease depends on
    (spec.workload.dependencies.resources[].ref): the preview gets its own instance (e.g. an empty database) in its
    cell, never development's. Owned by the preview Environment like the release, so closing the PR deletes it, and
    retainPolicy Delete removes the data with it. Pinned by ResourcePins (annotation "latest"), sized by the
    ResourceType's environmentConfigs defaults."""
    deps = (((release or {}).get("spec") or {}).get("workload") or {}).get("dependencies") or {}
    env_name = environment["metadata"]["name"]
    out = []
    for ref in sorted(set(d.get("ref", "") for d in deps.get("resources") or [])):
        if not NAME_RE.match(ref):
            continue
        out.append({
            "apiVersion": "openchoreo.dev/v1alpha1",
            "kind": "ResourceReleaseBinding",
            "metadata": {
                "name": "%s-%s" % (ref, env_name), "namespace": namespace, "labels": labels,
                "annotations": {RESOURCE_RELEASE_ANNOTATION: "latest"},
                "ownerReferences": [{"apiVersion": "openchoreo.dev/v1alpha1", "kind": "Environment",
                                     "name": env_name, "uid": environment["metadata"]["uid"]}],
            },
            "spec": {"owner": {"projectName": project, "resourceName": ref}, "environment": env_name,
                     "retainPolicy": "Delete"},
        })
    return out


def ready(binding, release):
    """The binding points at `release` and OpenChoreo reports it Ready for the current generation."""
    if not binding or (binding.get("spec") or {}).get("releaseName") != release:
        return False
    gen = (binding.get("metadata") or {}).get("generation")
    for c in (binding.get("status") or {}).get("conditions") or []:
        if c.get("type") == "Ready":
            return c.get("status") == "True" and c.get("observedGeneration") == gen
    return False


def endpoint_url(binding):
    """First external URL OpenChoreo resolved for the binding (status.endpoints[].externalURLs), or ""."""
    for ep in (binding.get("status") or {}).get("endpoints") or []:
        for scheme in ("https", "http"):
            u = (ep.get("externalURLs") or {}).get(scheme)
            if u and u.get("host"):
                port = u.get("port")
                default = 443 if scheme == "https" else 80
                return "%s://%s%s%s" % (u.get("scheme") or scheme, u["host"],
                                        ":%s" % port if port and port != default else "", u.get("path") or "/")
    return ""


def expires_at(environment, ttl_seconds):
    """Unix seconds the preview expires: Kyverno's stamp, else creation + TTL (what platform-preview-ttl uses)."""
    stamp = ((environment.get("metadata") or {}).get("labels") or {}).get(EXPIRES_LABEL, "")
    if re.match(r"^[0-9]{1,12}$", stamp or ""):
        return int(stamp)
    created = parse_time((environment.get("metadata") or {}).get("creationTimestamp"))
    return int(created.timestamp()) + ttl_seconds if created else None


class Previews:
    """One pass over the preview Applications (`api` provides cluster and GitHub calls, fake in tests)."""

    def __init__(self, api, namespace, allowed_prefixes, state, opt_in, expired_label, ttl_seconds,
                 status_context="openchoreo/preview", repository="", max_runs=5, now=None):
        self.api = api
        self.namespace = namespace
        self.allowed = allowed_prefixes
        self.state = state
        self.state.setdefault("previews", {})
        self.opt_in = opt_in                      # (annotation, value)
        self.expired_label = expired_label
        self.ttl = ttl_seconds
        self.context = status_context
        self.repository = repository.lower()
        self.max_runs = max_runs
        self.now = now or dt.datetime.now(dt.timezone.utc)
        self.created = []
        self.errors = []
        self._schemas = {}

    def status(self, key, slug, sha, state, description, url=""):
        """Commit status on the PR head, posted only when it changed since the last pass."""
        description = description[:140]
        mark = "%s|%s|%s|%s" % (sha, state, description, url)
        if (self.state["previews"].get(key) or {}).get("status") == mark:
            return
        self.api.set_status(slug, sha, state, description, url, self.context)
        log("%s: status %s: %s %s" % (key, state, description, url))
        self.state["previews"][key] = {"status": mark}

    def schema(self, kind, name):
        if (kind, name) not in self._schemas:
            self._schemas[(kind, name)] = self.api.workflow_schema(kind, name, self.namespace) or {}
        return self._schemas[(kind, name)]

    def preview(self, app):
        md = app.get("metadata") or {}
        key = md.get("name", "")
        labels = md.get("labels") or {}
        ann = md.get("annotations") or {}
        comp_name, number = labels.get(COMPONENT_LABEL, ""), labels.get(PR_LABEL, "")
        sha, slug = ann.get(COMMIT_ANNOTATION, ""), ann.get(REPOSITORY_ANNOTATION, "")
        if not (NAME_RE.match(comp_name) and NUMBER_RE.match(number) and SHA_RE.match(sha) and SLUG_RE.match(slug)):
            log("%s: not a well-formed preview Application: skipped" % key)
            return
        if self.repository and slug.lower() != self.repository:
            return
        env_name, binding_name, release, run = preview_names(comp_name, number, sha)
        comp = self.api.get("components", comp_name)
        if not comp:
            log("%s: Component %s not found: skipped" % (key, comp_name))
            return
        annotation, value = self.opt_in
        if ((comp.get("metadata") or {}).get("annotations") or {}).get(annotation) != value:
            log("%s: Component %s has no %s: %s: not built" % (key, comp_name, annotation, value))
            return
        wf = (comp.get("spec") or {}).get("workflow") or {}
        if not wf.get("name"):
            log("%s: Component %s has no spec.workflow: not built" % (key, comp_name))
            return
        schema = self.schema(wf.get("kind") or "Workflow", wf["name"])
        paths = extension_paths(schema)
        comp_slug = repo_slug(get_path(wf.get("parameters") or {}, paths.get("url", "")), self.allowed) \
            if "url" in paths else None
        if not comp_slug or comp_slug.lower() != slug.lower():
            log("%s: repository %s is not Component %s's build repository: skipped" % (key, slug, comp_name))
            return
        pr = self.api.pull(slug, number)
        if pr.get("state") != "open" or (pr.get("head") or {}).get("sha") != sha:
            log("%s: PR #%s is %s at %s, Application at %s: waiting for Argo CD"
                % (key, number, pr.get("state"), ((pr.get("head") or {}).get("sha") or "")[:12], sha[:12]))
            return
        head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name") or ""
        if head_repo.lower() != slug.lower():
            self.status(key, slug, sha, "failure", "No preview: pull requests from forks are not built")
            return
        pr_labels = [lbl.get("name") for lbl in pr.get("labels") or []]
        if self.expired_label in pr_labels:
            self.status(key, slug, sha, "error", "Preview expired after the platform TTL; remove label %s for a fresh "
                        "one" % self.expired_label)
            return
        env = self.api.get("environments", env_name)
        if not env:
            msg = ((app.get("status") or {}).get("operationState") or {}).get("message") or "syncing"
            self.status(key, slug, sha, "pending", "Waiting for environment %s: %s" % (env_name, msg))
            return
        expiry = expires_at(env, self.ttl)
        if expiry is not None and int(self.now.timestamp()) >= expiry:
            self.api.add_label(slug, number, self.expired_label)
            log("%s: TTL over (expired at %d): labelled PR #%s %s" % (key, expiry, number, self.expired_label))
            self.status(key, slug, sha, "error", "Preview expired after the platform TTL; remove label %s for a fresh "
                        "one" % self.expired_label)
            return
        until = dt.datetime.fromtimestamp(expiry, dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC") if expiry else "?"
        if not self.api.get("componentreleases", release):
            wr = self.api.get("workflowruns", run)
            if not wr:
                if len(self.created) >= self.max_runs:
                    log("%s: build budget of this pass used, next pass" % key)
                    return
                obj = build_run(comp, self.namespace, paths, sha,
                                {TRIGGER_LABEL: "preview", PR_LABEL: number}, name=run,
                                overrides={"gitops.enabled": False})
                self.api.create_run(obj)
                self.created.append(run)
                self.status(key, slug, sha, "pending", "Building %s (WorkflowRun %s)" % (sha[:7], run))
                return
            if not completed(wr):
                self.status(key, slug, sha, "pending", "Building %s (WorkflowRun %s)" % (sha[:7], run))
                return
            if not succeeded(wr):
                self.status(key, slug, sha, "failure", "Build of %s failed (WorkflowRun %s)" % (sha[:7], run))
                return
            latest = ((comp.get("status") or {}).get("latestRelease") or {}).get("name")
            base = self.api.get("componentreleases", latest) if latest else None
            if not base:
                self.status(key, slug, sha, "pending", "Waiting for a first release of %s on main" % comp_name)
                return
            ref = (wr.get("status") or {}).get("runReference") or {}
            image = build_image(self.api.argo_workflow(ref.get("name") or run))
            if not image:
                # nothing built (the head only changes the GitOps directory): preview the main image
                image = ((base.get("spec") or {}).get("workload") or {}).get("container", {}).get("image")
            branch = (pr.get("head") or {}).get("ref") or ""
            self.api.create_release(preview_release(
                base, release, self.namespace, image, sha, branch, env,
                {PREVIEW_LABEL: "true", PR_LABEL: number, COMPONENT_LABEL: comp_name,
                 "openchoreo.dev/component": comp_name,
                 "openchoreo.dev/project": comp["spec"]["owner"]["projectName"]}))
            log("%s: ComponentRelease %s <- %s" % (key, release, image))
            self.status(key, slug, sha, "pending", "Deploying %s to %s" % (sha[:7], env_name))
        project = comp["spec"]["owner"]["projectName"]
        for rrb in preview_resource_bindings(self.api.get("componentreleases", release), self.namespace, project, env,
                                             {PREVIEW_LABEL: "true", PR_LABEL: number, COMPONENT_LABEL: comp_name,
                                              "openchoreo.dev/project": project}):
            if self.api.create_resource_binding(rrb):
                log("%s: ResourceReleaseBinding %s (the preview's own %s)"
                    % (key, rrb["metadata"]["name"], rrb["spec"]["owner"]["resourceName"]))
        binding = self.api.get("releasebindings", binding_name)
        if binding and ((binding.get("metadata") or {}).get("annotations") or {}).get(RELEASE_ANNOTATION) != release:
            # OpenChoreo 1.3.3 does not requeue a binding whose ComponentRelease appears after it (ReleaseSynced stays
            # ComponentReleaseNotFound): an annotation change makes it reconcile. Once per release.
            self.api.poke_binding(binding_name, release)
            log("%s: ReleaseBinding %s reconciles %s" % (key, binding_name, release))
            return
        if ready(binding, release):
            url = endpoint_url(binding)
            self.status(key, slug, sha, "success", "Preview %s is up (until %s)" % (env_name, until), url)
        else:
            self.status(key, slug, sha, "pending", "Deploying %s to %s" % (sha[:7], env_name))

    def run(self):
        apps = sorted(self.api.preview_apps(), key=lambda a: a["metadata"]["name"])
        names = set()
        for app in apps:
            names.add(app["metadata"]["name"])
            try:
                self.preview(app)
            except RateLimited:
                raise
            except Failed as e:
                log("%s: error: %s" % (app["metadata"]["name"], e))
                self.errors.append(str(e))
        for gone in [k for k in self.state["previews"] if k not in names]:
            del self.state["previews"][gone]       # PR closed: Argo CD removed the Application
        return self.created


class ResourcePins:
    """Keeps every ResourceReleaseBinding annotated platform.koorikla.io/resource-release: latest on its Resource's
    latest ResourceRelease. OpenChoreo 1.3.3 never writes spec.resourceRelease (the CRD: "advanced manually via occ
    resource promote or kubectl edit"; `occ resource promote` is a client doing exactly this write). The release name
    is <resource>-<hash of the ResourceType spec and parameters>, so pinning it in Git would break on every platform
    change to the type. Gated environments change only through a reviewed pull request (VAP
    openchoreo-gated-bindings-from-git): there the pin stays in Git and this pass never writes."""

    def __init__(self, api, gated_environments):
        self.api = api
        self.gated = set(gated_environments)
        self.errors = []

    def run(self):
        for b in sorted(self.api.resource_bindings(), key=lambda o: o["metadata"]["name"]):
            name = b["metadata"]["name"]
            if ((b["metadata"].get("annotations") or {}).get(RESOURCE_RELEASE_ANNOTATION)) != "latest":
                continue
            spec = b.get("spec") or {}
            if spec.get("environment") in self.gated:
                log("ResourceReleaseBinding %s: %s is gated, pin spec.resourceRelease in Git (annotation ignored)"
                    % (name, spec.get("environment")))
                continue
            try:
                res = self.api.get("resources", (spec.get("owner") or {}).get("resourceName", ""))
                latest = (((res or {}).get("status") or {}).get("latestRelease") or {}).get("name")
                if not latest:
                    log("ResourceReleaseBinding %s: Resource has no release yet, next pass" % name)
                elif spec.get("resourceRelease") != latest:
                    self.api.pin_resource_release(name, latest)
                    log("ResourceReleaseBinding %s: resourceRelease %s -> %s"
                        % (name, spec.get("resourceRelease") or "(unset)", latest))
            except Failed as e:
                log("ResourceReleaseBinding %s: error: %s" % (name, e))
                self.errors.append(str(e))


# --- clients ------------------------------------------------------------------------------------------------------------
def http(method, url, headers=None, body=None, context=None, timeout=20):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"User-Agent": "koorikla-auto-build"}
    hdrs.update(headers or {})
    if data is not None:
        hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=context) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


class Api:
    SA = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, namespace, state_namespace, state_configmap, token_file, github_api="https://api.github.com",
                 min_remaining=100, preview_token_file="", argocd_namespace="argocd", registry_auth_dir="",
                 registry_ca_file=""):
        self.namespace = namespace
        self.state_namespace = state_namespace
        self.state_configmap = state_configmap
        self.github_api = github_api.rstrip("/")
        self.min_remaining = min_remaining
        self.argocd_namespace = argocd_namespace
        self.gh_token = self.read_token(token_file)
        self.preview_token = self.read_token(preview_token_file) if preview_token_file else ""
        with open(os.path.join(self.SA, "token")) as f:
            self.kube_token = f.read().strip()
        self.kube_url = "https://%s:%s" % (env("KUBERNETES_SERVICE_HOST"), env("KUBERNETES_SERVICE_PORT", "443"))
        self.kube_ctx = ssl.create_default_context(cafile=os.path.join(self.SA, "ca.crt"))
        self.remaining = None
        self.registry_auth = None
        if registry_auth_dir:
            with open(os.path.join(registry_auth_dir, "username")) as f, \
                    open(os.path.join(registry_auth_dir, "password")) as g:
                self.registry_auth = (f.read().strip(), g.read().strip())
        self.registry_ctx = ssl.create_default_context(cafile=registry_ca_file or None)
        self._registry_tokens = {}

    @staticmethod
    def read_token(path):
        with open(path) as f:
            token = f.read().strip()
        if not token:
            raise Failed("empty GitHub token in %s" % path)
        return token

    # Kubernetes
    def kube(self, method, path, body=None, ok=(200, 201), content_type="application/json"):
        status, _, raw = http(method, self.kube_url + path, body=body, context=self.kube_ctx,
                              headers={"Authorization": "Bearer " + self.kube_token, "Accept": "application/json",
                                       "Content-Type": content_type})
        if status not in ok:
            raise Failed("%s %s -> HTTP %d: %s" % (method, path, status, raw[:300].decode(errors="replace")))
        return status, (json.loads(raw) if raw else {})

    def components(self):
        _, body = self.kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/components" % self.namespace)
        return body.get("items") or []

    def workflow_schema(self, kind, name, namespace):
        path = ("/apis/openchoreo.dev/v1alpha1/clusterworkflows/%s" % name) if kind == "ClusterWorkflow" else \
            ("/apis/openchoreo.dev/v1alpha1/namespaces/%s/workflows/%s" % (namespace, name))
        _, body = self.kube("GET", path)
        return ((body.get("spec") or {}).get("parameters") or {}).get("openAPIV3Schema") or {}

    def get_run(self, name):
        """A WorkflowRun of the org namespace, or None."""
        return self.get("workflowruns", name)

    def run_exists(self, name):
        status, _ = self.kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/workflowruns/%s"
                              % (self.namespace, name), ok=(200, 404))
        return status == 200

    def component_runs(self, component, labels):
        selector = ",".join(["%s=%s" % kv for kv in sorted(labels.items())] + ["openchoreo.dev/component=" + component])
        _, body = self.kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/workflowruns?labelSelector=%s"
                            % (self.namespace, urllib.parse.quote(selector)))
        return body.get("items") or []

    def create_run(self, run):
        status, _ = self.kube("POST", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/workflowruns" % self.namespace,
                              body=run, ok=(201, 409))
        return status == 201

    # PR previews
    def preview_apps(self):
        _, body = self.kube("GET", "/apis/argoproj.io/v1alpha1/namespaces/%s/applications?labelSelector=%s"
                            % (self.argocd_namespace, urllib.parse.quote(PREVIEW_LABEL + "=true")))
        return body.get("items") or []

    def get(self, resource, name):
        """An openchoreo.dev object of the org namespace, or None."""
        status, body = self.kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/%s/%s"
                                 % (self.namespace, resource, urllib.parse.quote(name)), ok=(200, 404))
        return body if status == 200 else None

    def argo_workflow(self, name):
        status, body = self.kube("GET", "/apis/argoproj.io/v1alpha1/namespaces/%s/workflows/%s"
                                 % (self.state_namespace, urllib.parse.quote(name)), ok=(200, 404))
        return body if status == 200 else None

    def poke_binding(self, name, release):
        self.kube("PATCH", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/releasebindings/%s"
                  % (self.namespace, urllib.parse.quote(name)),
                  body={"metadata": {"annotations": {RELEASE_ANNOTATION: release}}},
                  content_type="application/merge-patch+json")

    def create_release(self, release):
        self.kube("POST", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/componentreleases" % self.namespace,
                  body=release, ok=(201, 409))

    # Resource pins
    def resource_bindings(self):
        _, body = self.kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/resourcereleasebindings"
                            % self.namespace)
        return body.get("items") or []

    def create_resource_binding(self, binding):
        status, _ = self.kube("POST", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/resourcereleasebindings"
                              % self.namespace, body=binding, ok=(201, 409))
        return status == 201

    def pin_resource_release(self, name, release):
        self.kube("PATCH", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/resourcereleasebindings/%s"
                  % (self.namespace, urllib.parse.quote(name)), body={"spec": {"resourceRelease": release}},
                  content_type="application/merge-patch+json")

    def load_state(self):
        status, body = self.kube("GET", "/api/v1/namespaces/%s/configmaps/%s"
                                 % (self.state_namespace, self.state_configmap), ok=(200, 404))
        if status == 404:
            return {}, None
        try:
            return json.loads((body.get("data") or {}).get("state.json") or "{}"), body
        except ValueError:
            return {}, body

    def save_state(self, state, current):
        cm = {"apiVersion": "v1", "kind": "ConfigMap",
              "metadata": {"name": self.state_configmap, "namespace": self.state_namespace,
                           "labels": {"app.kubernetes.io/name": "auto-build"}},
              "data": {"state.json": json.dumps(state, sort_keys=True, indent=1)}}
        base = "/api/v1/namespaces/%s/configmaps" % self.state_namespace
        if current is None:
            self.kube("POST", base, body=cm, ok=(201, 409))
        else:
            cm["metadata"]["resourceVersion"] = current["metadata"]["resourceVersion"]
            self.kube("PUT", base + "/" + self.state_configmap, body=cm, ok=(200, 409))   # 409: a parallel pass won

    # Registry (Distribution API: anonymous, then the Bearer token flow or Basic with the pull-only robot)
    def image_exists(self, host, repository, digest):
        """True/False when the registry answers 200/404 for the manifest, None when it cannot tell."""
        url = "https://%s/v2/%s/manifests/%s" % (host, repository, digest)
        headers = {"Accept": MANIFEST_TYPES}
        scope = "repository:%s:pull" % repository
        try:
            if scope in self._registry_tokens:
                headers["Authorization"] = self._registry_tokens[scope]
            status, hdrs, _ = http("HEAD", url, headers=headers, context=self.registry_ctx)
            if status == 401 and self.registry_auth:
                challenge = (hdrs or {}).get("WWW-Authenticate") or ""
                basic = "Basic " + base64.b64encode(("%s:%s" % self.registry_auth).encode()).decode()
                bearer = bearer_challenge(challenge)
                if bearer and bearer.get("realm", "").startswith("https://"):
                    query = urllib.parse.urlencode({"service": bearer.get("service", ""), "scope": scope})
                    tstatus, _, raw = http("GET", bearer["realm"] + "?" + query, headers={"Authorization": basic},
                                           context=self.registry_ctx)
                    body = json.loads(raw) if tstatus == 200 else {}
                    token = body.get("token") or body.get("access_token")
                    if not token:
                        log("registry %s: token endpoint answered HTTP %d" % (host, tstatus))
                        return None
                    self._registry_tokens[scope] = "Bearer " + token
                else:
                    self._registry_tokens[scope] = basic
                headers["Authorization"] = self._registry_tokens[scope]
                status, _, _ = http("HEAD", url, headers=headers, context=self.registry_ctx)
        except (OSError, ValueError) as e:
            log("registry %s: %s" % (host, e))
            return None
        if status in (200, 404):
            return status == 200
        log("registry %s: HEAD %s/manifests/%s -> HTTP %d" % (host, repository, digest[:19], status))
        return None

    # GitHub
    def gh(self, path, accept="application/vnd.github+json", etag="", ok=(200,), method="GET", body=None, token=""):
        headers = {"Authorization": "Bearer " + (token or self.gh_token), "Accept": accept,
                   "X-GitHub-Api-Version": "2022-11-28"}
        if etag:
            headers["If-None-Match"] = etag
        status, hdrs, raw = http(method, self.github_api + path, headers=headers, body=body)
        hdrs = hdrs or {}
        if str(hdrs.get("X-RateLimit-Remaining") or "").isdigit():
            self.remaining = int(str(hdrs.get("X-RateLimit-Remaining")))
        if status in (403, 429) and (hdrs.get("Retry-After") or self.remaining == 0):
            raise RateLimited("GitHub rate limit (HTTP %d, retry after %ss, reset %s)"
                              % (status, hdrs.get("Retry-After", "?"), hdrs.get("X-RateLimit-Reset", "?")))
        if status not in ok:
            raise Failed("%s %s -> HTTP %d: %s" % (method, path, status, raw[:300].decode(errors="replace")))
        if self.remaining is not None and self.remaining < self.min_remaining:
            raise RateLimited("GitHub rate limit nearly used (%d left): pausing until the next pass" % self.remaining)
        return status, hdrs, raw

    def branch_head(self, slug, branch, etag):
        status, hdrs, raw = self.gh("/repos/%s/commits/%s" % (slug, urllib.parse.quote(branch, safe="")),
                                    accept="application/vnd.github.sha", etag=etag, ok=(200, 304))
        if status == 304:
            return None, etag
        return raw.decode().strip(), hdrs.get("ETag", "")

    def commit_sha(self, slug, ref):
        """Full SHA of a (short) commit ref."""
        _, _, raw = self.gh("/repos/%s/commits/%s" % (slug, urllib.parse.quote(ref, safe="")),
                            accept="application/vnd.github.sha")
        sha = raw.decode().strip()
        if not SHA_RE.match(sha):
            raise Failed("%s: no commit SHA for %s" % (slug, ref))
        return sha

    def file_at(self, slug, path, sha):
        status, _, raw = self.gh("/repos/%s/contents/%s?ref=%s" % (slug, urllib.parse.quote(path), sha),
                                 accept="application/vnd.github.raw+json", ok=(200, 404))
        return raw.decode(errors="replace") if status == 200 else ""

    def changed_files(self, slug, base, head):
        """Paths changed between base and head, or None when GitHub cannot say (diverged, > 300 files)."""
        _, _, raw = self.gh("/repos/%s/compare/%s...%s?per_page=100" % (slug, base, head))
        body = json.loads(raw)
        if body.get("status") not in ("ahead", "identical"):
            return None
        files = [f.get("filename", "") for f in body.get("files") or []]
        if len(files) >= 300:
            return None
        return files

    def pull(self, slug, number):
        _, _, raw = self.gh("/repos/%s/pulls/%s" % (slug, number), token=self.preview_token)
        return json.loads(raw)

    def set_status(self, slug, sha, state, description, url, context):
        body = {"state": state, "description": description, "context": context}
        if url:
            body["target_url"] = url
        self.gh("/repos/%s/statuses/%s" % (slug, sha), method="POST", body=body, ok=(201,), token=self.preview_token)

    def add_label(self, slug, number, label):
        self.gh("/repos/%s/issues/%s/labels" % (slug, number), method="POST", body={"labels": [label]}, ok=(200,),
                token=self.preview_token)


def duration_seconds(value):
    """'48h', '90m', '1h30m' -> seconds (the TTL format of installation.yaml previews.ttl)."""
    m = re.match(r"^(?:([0-9]+)h)?(?:([0-9]+)m)?$", value or "")
    if not m or not (m.group(1) or m.group(2)):
        raise ValueError("not a duration in hours/minutes: %r" % value)
    return int(m.group(1) or 0) * 3600 + int(m.group(2) or 0) * 60


def main():
    namespace = env("ORG_NAMESPACE", "default")
    repository = env("REPOSITORY")
    m = GITHUB_URL_RE.match(repository) if repository else None
    if repository and not m:
        log("REPOSITORY %r is not a github.com repository URL: nothing to do" % repository)
        return 0
    previews = env("PREVIEWS") == "true"
    api = Api(namespace, env("STATE_NAMESPACE"), env("STATE_CONFIGMAP", "auto-build-state"), env("TOKEN_FILE"),
              env("GITHUB_API", "https://api.github.com"), int(env("MIN_RATE_REMAINING", "100")),
              preview_token_file=env("PREVIEW_TOKEN_FILE") if previews else "",
              argocd_namespace=env("ARGOCD_NAMESPACE", "argocd"), registry_auth_dir=env("REGISTRY_AUTH_DIR"),
              registry_ca_file=env("REGISTRY_CA_FILE"))
    state, current = api.load_state()
    slug = "%s/%s" % (m.group(1), m.group(2)) if m else ""
    max_runs = int(env("MAX_RUNS", "5"))
    rec = Reconciler(api, namespace, env("ALLOWED_PREFIXES").split(), state, repository=slug, max_runs=max_runs,
                     stale_seconds=int(env("STALE_SECONDS", "7200")), registry_host=env("REGISTRY_HOST"))
    errors = []
    created = []
    try:
        created = rec.run()
        if previews:
            pv = Previews(api, namespace, env("ALLOWED_PREFIXES").split(), rec.state,
                          (env("PREVIEW_OPT_IN_ANNOTATION"), env("PREVIEW_OPT_IN_VALUE")), env("PREVIEW_EXPIRED_LABEL"),
                          duration_seconds(env("PREVIEW_TTL", "48h")), env("PREVIEW_STATUS_CONTEXT", "openchoreo/preview"),
                          repository=slug, max_runs=max(0, max_runs - len(created)))
            try:
                created = created + pv.run()
            finally:
                errors += pv.errors
    except RateLimited as e:
        log("paused: %s" % e)
        created = created or rec.created
    # Kubernetes only (no GitHub call), so it runs even when GitHub paused the pass; after the previews, whose new
    # ResourceReleaseBindings it pins in the same pass.
    pins = ResourcePins(api, env("GATED_ENVIRONMENTS").split())
    pins.run()
    errors += pins.errors
    api.save_state(rec.state, current)
    log("pass done: %d WorkflowRun(s) created%s, GitHub rate limit remaining %s"
        % (len(created), (": " + ", ".join(created)) if created else "", api.remaining))
    return 1 if rec.errors or errors else 0


if __name__ == "__main__":
    sys.exit(main())
