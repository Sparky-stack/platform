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
#   - while an auto-build run of the component is still running, no second one starts (no out-of-order image bumps).
# The ConfigMap STATE_CONFIGMAP is only a cache (branch ETags, last handled head per component): GitHub answers a
# conditional request with 304 when nothing changed, which does not count against the rate limit. Losing it costs API
# calls, never a duplicate build.
#
# GitHub: a short-lived installation token (contents: read) minted and rotated by ESO (GithubAccessToken generator
# from the platform's GitHub App), mounted at TOKEN_FILE. This script never sees the App's private key.
# Kubernetes: the pod's ServiceAccount (list Components, get ClusterWorkflows, create WorkflowRuns, one ConfigMap).
#
# Stdlib only. The WorkflowTemplate embeds this file in an Argo template: the source must not contain two opening
# braces (hack/tests/test_workflow_scripts.sh).
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
TRIGGER_LABEL = "platform.koorikla.io/trigger"
COMMIT_ANNOTATION = "platform.koorikla.io/commit"
DEFAULT_WORKLOAD_PATH = "deploy/openchoreo/workload.yaml"


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


def build_run(component, namespace, paths, sha, labels):
    """The WorkflowRun OpenChoreo's own trigger would create for this commit, with a deterministic name."""
    wf = component["spec"]["workflow"]
    params = wf.get("parameters") or {}
    if "commit" in paths:
        params = set_path(params, paths["commit"], sha)
    name = component["metadata"]["name"]
    return {
        "apiVersion": "openchoreo.dev/v1alpha1",
        "kind": "WorkflowRun",
        "metadata": {
            "name": run_name(name, sha),
            "namespace": namespace,
            "labels": dict(labels, **{
                "openchoreo.dev/project": component["spec"]["owner"]["projectName"],
                "openchoreo.dev/component": name,
            }),
            "annotations": {COMMIT_ANNOTATION: sha},
        },
        "spec": {"workflow": {"kind": wf.get("kind") or "Workflow", "name": wf["name"], "parameters": params}},
    }


# --- reconcile --------------------------------------------------------------------------------------------------------
class Reconciler:
    """One pass over the Components. `api` provides the cluster and GitHub calls (fake in tests)."""

    def __init__(self, api, namespace, allowed_prefixes, state, repository="", max_runs=5, stale_seconds=7200,
                 labels=None, now=None):
        self.api = api
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

    def record(self, name, sha, result, run=""):
        self.state["components"][name] = {"sha": sha, "result": result, "run": run,
                                          "at": self.now.strftime("%Y-%m-%dT%H:%M:%SZ")}

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
        if last.get("sha") == sha:
            return                                  # nothing new since the last pass
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
        built = workload_commit(self.api.file_at(slug, workload_path, sha))
        if built and (sha.startswith(built) or built.startswith(sha)):
            log("%s: %s %s is the built commit" % (name, slug, sha[:12]))
            self.record(name, sha, "up-to-date")
            return
        if built:
            files = self.api.changed_files(slug, built, sha)
            gitops_dir = posixpath.dirname(workload_path)
            if files is not None and only_under(files, gitops_dir):
                log("%s: %s %s changes only %s/ since built %s: nothing to build"
                    % (name, slug, sha[:12], gitops_dir, built[:12]))
                self.record(name, sha, "up-to-date")
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


# --- clients ------------------------------------------------------------------------------------------------------------
def http(method, url, headers=None, body=None, context=None, timeout=20):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"User-Agent": "koorikla-auto-build"}
    hdrs.update(headers or {})
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=context) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


class Api:
    SA = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, namespace, state_namespace, state_configmap, token_file, github_api="https://api.github.com",
                 min_remaining=100):
        self.namespace = namespace
        self.state_namespace = state_namespace
        self.state_configmap = state_configmap
        self.github_api = github_api.rstrip("/")
        self.min_remaining = min_remaining
        with open(token_file) as f:
            self.gh_token = f.read().strip()
        if not self.gh_token:
            raise Failed("empty GitHub token in %s" % token_file)
        with open(os.path.join(self.SA, "token")) as f:
            self.kube_token = f.read().strip()
        self.kube_url = "https://%s:%s" % (env("KUBERNETES_SERVICE_HOST"), env("KUBERNETES_SERVICE_PORT", "443"))
        self.kube_ctx = ssl.create_default_context(cafile=os.path.join(self.SA, "ca.crt"))
        self.remaining = None

    # Kubernetes
    def kube(self, method, path, body=None, ok=(200, 201)):
        status, _, raw = http(method, self.kube_url + path, body=body, context=self.kube_ctx,
                              headers={"Authorization": "Bearer " + self.kube_token, "Accept": "application/json"})
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

    # GitHub
    def gh(self, path, accept="application/vnd.github+json", etag="", ok=(200,)):
        headers = {"Authorization": "Bearer " + self.gh_token, "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"}
        if etag:
            headers["If-None-Match"] = etag
        status, hdrs, raw = http("GET", self.github_api + path, headers=headers)
        hdrs = hdrs or {}
        if str(hdrs.get("X-RateLimit-Remaining") or "").isdigit():
            self.remaining = int(str(hdrs.get("X-RateLimit-Remaining")))
        if status in (403, 429) and (hdrs.get("Retry-After") or self.remaining == 0):
            raise RateLimited("GitHub rate limit (HTTP %d, retry after %ss, reset %s)"
                              % (status, hdrs.get("Retry-After", "?"), hdrs.get("X-RateLimit-Reset", "?")))
        if status not in ok:
            raise Failed("GET %s -> HTTP %d: %s" % (path, status, raw[:300].decode(errors="replace")))
        if self.remaining is not None and self.remaining < self.min_remaining:
            raise RateLimited("GitHub rate limit nearly used (%d left): pausing until the next pass" % self.remaining)
        return status, hdrs, raw

    def branch_head(self, slug, branch, etag):
        status, hdrs, raw = self.gh("/repos/%s/commits/%s" % (slug, urllib.parse.quote(branch, safe="")),
                                    accept="application/vnd.github.sha", etag=etag, ok=(200, 304))
        if status == 304:
            return None, etag
        return raw.decode().strip(), hdrs.get("ETag", "")

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


def main():
    namespace = env("ORG_NAMESPACE", "default")
    repository = env("REPOSITORY")
    m = GITHUB_URL_RE.match(repository) if repository else None
    if repository and not m:
        log("REPOSITORY %r is not a github.com repository URL: nothing to do" % repository)
        return 0
    api = Api(namespace, env("STATE_NAMESPACE"), env("STATE_CONFIGMAP", "auto-build-state"), env("TOKEN_FILE"),
              env("GITHUB_API", "https://api.github.com"), int(env("MIN_RATE_REMAINING", "100")))
    state, current = api.load_state()
    rec = Reconciler(api, namespace, env("ALLOWED_PREFIXES").split(), state,
                     repository="%s/%s" % (m.group(1), m.group(2)) if m else "",
                     max_runs=int(env("MAX_RUNS", "5")), stale_seconds=int(env("STALE_SECONDS", "7200")))
    try:
        created = rec.run()
    except RateLimited as e:
        log("paused: %s" % e)
        created = rec.created
    api.save_state(rec.state, current)
    log("pass done: %d WorkflowRun(s) created%s, GitHub rate limit remaining %s"
        % (len(created), (": " + ", ".join(created)) if created else "", api.remaining))
    return 1 if rec.errors else 0


if __name__ == "__main__":
    sys.exit(main())
