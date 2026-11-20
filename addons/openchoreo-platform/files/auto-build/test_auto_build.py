#!/usr/bin/env python3
# Unit tests of auto_build.py (stdlib unittest; hack/tests/test_workflow_scripts.sh). A fake Api stands in for the
# cluster and GitHub; every scenario is one reconcile pass, like a CronWorkflow tick or a webhook-triggered run.
import datetime as dt
import unittest

import auto_build as ab

ab.log = lambda msg: None   # quiet: assertions check the outcome

SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
PREFIXES = ["https://github.com/koorikla/"]

SCHEMA = {
    "type": "object",
    "properties": {
        "repository": {
            "type": "object",
            "properties": {
                "url": {"type": "string", ab.EXT + "url": True},
                "revision": {
                    "type": "object",
                    "properties": {
                        "branch": {"type": "string", "default": "main", ab.EXT + "branch": True},
                        "commit": {"type": "string", "default": "", ab.EXT + "commit": True},
                    },
                },
                "appPath": {"type": "string", "default": ".", ab.EXT + "app-path": True},
            },
        },
        "gitops": {"type": "object", "properties": {"workloadPath": {"type": "string",
                                                                     "default": "deploy/openchoreo/workload.yaml"}}},
    },
}


def component(name="hello-world", auto=True, url="https://github.com/koorikla/hello-world.git", branch="main",
              workflow="go"):
    params = {"repository": {"url": url, "appPath": "."}, "docker": {"context": "."}}
    if branch is not None:
        params["repository"]["revision"] = {"branch": branch}
    spec = {"owner": {"projectName": "demo"}, "workflow": {"kind": "ClusterWorkflow", "name": workflow,
                                                           "parameters": params}}
    if auto is not None:
        spec["autoBuild"] = auto
    return {"metadata": {"name": name}, "spec": spec}


def workload(commit, image=""):
    text = "spec:\n  source:\n    repository: https://github.com/koorikla/hello-world\n    commit: \"%s\"\n" % commit
    return text + ("  container:\n    image: %s\n    env:\n      - key: GREETING\n" % image if image else "")


REGISTRY = "harbor.openchoreo.localhost:9443"
DIGEST = "sha256:" + "d" * 64
IMAGE_B = "%s/apps/demo/hello-world:bbbbbbb@%s" % (REGISTRY, DIGEST)


class FakeApi:
    def __init__(self, components, heads, files=None, compare=None, runs=None, registry=None):
        self._components = components
        self.registry = registry or {}    # digest -> True | False | None (unknown); absent = present
        self.heads = heads                # (slug, branch) -> sha
        self.files = files or {}          # (slug, path, sha) -> text
        self.compare = compare or {}      # (slug, base, head) -> [files] | None
        self.runs = runs or {}            # name -> run object
        self.created = []
        self.calls = []

    def components(self):
        return self._components

    def workflow_schema(self, kind, name, namespace):
        self.calls.append(("schema", kind, name))
        return SCHEMA

    def branch_head(self, slug, branch, etag):
        self.calls.append(("head", slug, branch, etag))
        sha = self.heads[(slug, branch)]
        if etag == "etag-" + sha:
            return None, etag             # 304: unchanged
        return sha, "etag-" + sha

    def file_at(self, slug, path, sha):
        self.calls.append(("file", slug, path, sha))
        return self.files.get((slug, path, sha), "")

    def changed_files(self, slug, base, head):
        self.calls.append(("compare", slug, base, head))
        return self.compare.get((slug, base, head))

    def run_exists(self, name):
        return name in self.runs

    def get_run(self, name):
        return self.runs.get(name)

    def image_exists(self, host, repository, digest):
        self.calls.append(("registry", host, repository, digest))
        return self.registry.get(digest, True)

    def commit_sha(self, slug, ref):
        self.calls.append(("commit", slug, ref))
        return {"bbbbbbb": SHA_B}[ref]

    def component_runs(self, comp, labels):
        return [r for r in self.runs.values() if r["metadata"]["labels"].get("openchoreo.dev/component") == comp
                and all(r["metadata"]["labels"].get(k) == v for k, v in labels.items())]

    def create_run(self, run):
        name = run["metadata"]["name"]
        if name in self.runs:
            return False
        self.runs[name] = run
        self.created.append(run)
        return True


def reconcile(api, state=None, **kw):
    rec = ab.Reconciler(api, "default", PREFIXES, state if state is not None else {}, **kw)
    rec.run()
    return rec


SLUG = "koorikla/hello-world"
WL = "deploy/openchoreo/workload.yaml"


class PureHelpers(unittest.TestCase):
    def test_extension_paths(self):
        self.assertEqual(ab.extension_paths(SCHEMA), {"url": "repository.url", "branch": "repository.revision.branch",
                                                      "commit": "repository.revision.commit",
                                                      "app-path": "repository.appPath"})

    def test_schema_default(self):
        self.assertEqual(ab.schema_default(SCHEMA, "repository.revision.branch"), "main")
        self.assertIsNone(ab.schema_default(SCHEMA, "repository.nope"))

    def test_set_path_copies(self):
        params = {"repository": {"url": "u"}}
        out = ab.set_path(params, "repository.revision.commit", SHA_A)
        self.assertEqual(out["repository"]["revision"]["commit"], SHA_A)
        self.assertNotIn("revision", params["repository"])

    def test_repo_slug(self):
        self.assertEqual(ab.repo_slug("https://github.com/koorikla/hello-world.git", PREFIXES), SLUG)
        self.assertEqual(ab.repo_slug("https://github.com/koorikla/hello-world", PREFIXES), SLUG)
        self.assertEqual(ab.repo_slug("https://github.com/Koorikla/hello-world/", PREFIXES), "Koorikla/hello-world")

    def test_repo_slug_rejects(self):
        for url in ["https://github.com/other/x.git", "http://github.com/koorikla/x", "https://gitlab.com/koorikla/x",
                    "https://github.com/koorikla/../x", "https://github.com/koorikla/a/b", "git@github.com:koorikla/x",
                    None, 42, "https://github.com/koorikla-evil/x"]:
            self.assertIsNone(ab.repo_slug(url, PREFIXES), url)

    def test_run_name_is_deterministic_and_short(self):
        self.assertEqual(ab.run_name("hello-world", SHA_A), "hello-world-aaaaaaaaaaaa")
        long = ab.run_name("x" * 39 + "-yyyy", SHA_A)
        self.assertLessEqual(len(long), 53)
        self.assertFalse(long.startswith("-"))
        self.assertNotIn("--", long)

    def test_workload_commit(self):
        self.assertEqual(ab.workload_commit(workload(SHA_A)), SHA_A)
        self.assertEqual(ab.workload_commit("spec:\n  source:\n    commit: abc1234 # built\n"), "abc1234")
        self.assertIsNone(ab.workload_commit("spec:\n  source:\n    commit: \"\"\n"))
        self.assertIsNone(ab.workload_commit(""))

    def test_workload_image(self):
        self.assertEqual(ab.workload_image(workload(SHA_A, IMAGE_B)), IMAGE_B)
        self.assertEqual(ab.workload_image('spec:\n  container:\n    image: "x/y@%s" # pinned\n' % DIGEST), "x/y@" + DIGEST)
        self.assertIsNone(ab.workload_image(workload(SHA_A)))

    def test_image_parts(self):
        self.assertEqual(ab.image_parts(IMAGE_B), (REGISTRY, "apps/demo/hello-world", DIGEST))
        self.assertEqual(ab.image_parts("Harbor.X/a/b@" + DIGEST), ("harbor.x", "a/b", DIGEST))
        for ref in ["%s/apps/demo/hello-world:bbbbbbb" % REGISTRY, "hello-world@" + DIGEST, "h/a/../b@" + DIGEST,
                    "h/a/b@sha256:abc", "h/A/b@" + DIGEST, "", None]:
            self.assertIsNone(ab.image_parts(ref), ref)

    def test_rebuild_name_is_deterministic_and_short(self):
        self.assertEqual(ab.rebuild_name("hello-world", SHA_B, DIGEST), "hello-world-bbbbbbbbbbbb-dddddddd")
        long = ab.rebuild_name("x" * 39 + "-yyyy", SHA_B, DIGEST)
        self.assertLessEqual(len(long), 63)
        self.assertNotIn("--", long)
        self.assertNotEqual(ab.rebuild_name("hello-world", SHA_B, "sha256:" + "e" * 64), ab.run_name("hello-world", SHA_B))

    def test_bearer_challenge(self):
        self.assertEqual(ab.bearer_challenge('Bearer realm="https://h/service/token",service="harbor-registry"'),
                         {"realm": "https://h/service/token", "service": "harbor-registry"})
        self.assertIsNone(ab.bearer_challenge('Basic realm="harbor"'))
        self.assertIsNone(ab.bearer_challenge(None))

    def test_only_under(self):
        self.assertTrue(ab.only_under(["deploy/openchoreo/workload.yaml"], "deploy/openchoreo"))
        self.assertFalse(ab.only_under(["deploy/openchoreo/workload.yaml", "main.go"], "deploy/openchoreo"))
        self.assertFalse(ab.only_under(["deploy/openchoreo-evil/x"], "deploy/openchoreo"))
        self.assertFalse(ab.only_under([], "deploy/openchoreo"))
        self.assertFalse(ab.only_under(["x"], "."))


class Reconcile(unittest.TestCase):
    def test_new_commit_creates_one_run_for_that_sha(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_B}, files={(SLUG, WL, SHA_B): workload(SHA_A)},
                      compare={(SLUG, SHA_A, SHA_B): ["README.md"]})
        rec = reconcile(api)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-bbbbbbbbbbbb"])
        run = api.created[0]
        self.assertEqual(run["spec"]["workflow"]["parameters"]["repository"]["revision"]["commit"], SHA_B)
        self.assertEqual(run["spec"]["workflow"]["parameters"]["repository"]["revision"]["branch"], "main")
        self.assertEqual(run["spec"]["workflow"]["kind"], "ClusterWorkflow")
        self.assertEqual(run["spec"]["workflow"]["name"], "go")
        self.assertEqual(run["metadata"]["labels"], {"platform.koorikla.io/trigger": "auto-build",
                                                     "openchoreo.dev/project": "demo",
                                                     "openchoreo.dev/component": "hello-world"})
        self.assertEqual(run["metadata"]["annotations"], {ab.COMMIT_ANNOTATION: SHA_B})
        self.assertEqual(rec.state["components"]["hello-world"]["sha"], SHA_B)

    def test_second_pass_without_new_commit_creates_nothing_and_asks_github_conditionally(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_B}, files={(SLUG, WL, SHA_B): workload(SHA_A)},
                      compare={(SLUG, SHA_A, SHA_B): ["main.go"]})
        state = {}
        reconcile(api, state)
        api.calls.clear()
        rec = reconcile(api, state)
        self.assertEqual(len(api.created), 1)
        self.assertEqual(rec.created, [])
        self.assertEqual([c for c in api.calls if c[0] != "schema"], [("head", SLUG, "main", "etag-" + SHA_B)])

    def test_lost_state_and_existing_run_no_duplicate(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_B}, files={(SLUG, WL, SHA_B): workload(SHA_A)},
                      compare={(SLUG, SHA_A, SHA_B): ["main.go"]})
        reconcile(api)
        rec = reconcile(api, {})                     # state ConfigMap gone (restart, deleted): the run name guards
        self.assertEqual(len(api.created), 1)
        self.assertEqual(rec.created, [])

    def test_gitops_handoff_commit_is_not_built(self):
        # main = bump commit C written by the build of B; the run for B was garbage-collected and the state is lost
        api = FakeApi([component()], {(SLUG, "main"): SHA_C}, files={(SLUG, WL, SHA_C): workload(SHA_B)},
                      compare={(SLUG, SHA_B, SHA_C): ["deploy/openchoreo/workload.yaml"]})
        rec = reconcile(api)
        self.assertEqual(api.created, [])
        self.assertEqual(rec.state["components"]["hello-world"]["result"], "up-to-date")

    def test_promotion_merge_is_not_built(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_C}, files={(SLUG, WL, SHA_C): workload(SHA_B)},
                      compare={(SLUG, SHA_B, SHA_C): ["deploy/openchoreo/workload.yaml",
                                                      "deploy/openchoreo/release-bindings/staging.yaml"]})
        reconcile(api)
        self.assertEqual(api.created, [])

    def test_unknown_diff_builds(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_C}, files={(SLUG, WL, SHA_C): workload(SHA_B)},
                      compare={(SLUG, SHA_B, SHA_C): None})
        reconcile(api)
        self.assertEqual(len(api.created), 1)

    def test_never_built_component_builds_head(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_A})
        reconcile(api)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-aaaaaaaaaaaa"])

    def test_head_is_built_commit(self):
        api = FakeApi([component()], {(SLUG, "main"): SHA_A}, files={(SLUG, WL, SHA_A): workload(SHA_A)})
        reconcile(api)
        self.assertEqual(api.created, [])

    def test_running_build_blocks_the_next_commit(self):
        running = {"metadata": {"name": "hello-world-aaaaaaaaaaaa", "creationTimestamp": "2026-11-17T12:00:00Z",
                                "labels": {"platform.koorikla.io/trigger": "auto-build",
                                           "openchoreo.dev/component": "hello-world"}},
                   "status": {"conditions": [{"type": "WorkflowRunning", "status": "True"}]}}
        now = dt.datetime(2026, 11, 17, 12, 5, tzinfo=dt.timezone.utc)
        api = FakeApi([component()], {(SLUG, "main"): SHA_B}, files={(SLUG, WL, SHA_B): workload(SHA_C)},
                      compare={(SLUG, SHA_C, SHA_B): ["main.go"]}, runs={running["metadata"]["name"]: running})
        state = {}
        reconcile(api, state, now=now)
        self.assertEqual(api.created, [])
        self.assertNotIn("hello-world", state["components"])          # not recorded: the next pass retries
        running["status"]["conditions"].append({"type": "WorkflowCompleted", "status": "True"})
        reconcile(api, state, now=now)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-bbbbbbbbbbbb"])

    def test_stale_running_build_does_not_block_forever(self):
        stuck = {"metadata": {"name": "hello-world-aaaaaaaaaaaa", "creationTimestamp": "2026-11-17T08:00:00Z",
                              "labels": {"platform.koorikla.io/trigger": "auto-build",
                                         "openchoreo.dev/component": "hello-world"}}, "status": {}}
        api = FakeApi([component()], {(SLUG, "main"): SHA_B}, runs={"hello-world-aaaaaaaaaaaa": stuck})
        reconcile(api, now=dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.timezone.utc))
        self.assertEqual(len(api.created), 1)

    def test_opt_in_only(self):
        api = FakeApi([component(auto=None), component(name="off", auto=False)], {(SLUG, "main"): SHA_A})
        reconcile(api)
        self.assertEqual(api.created, [])
        self.assertEqual(api.calls, [])

    def test_repository_outside_allowed_prefixes_is_never_polled(self):
        api = FakeApi([component(url="https://github.com/someone-else/app.git")], {})
        reconcile(api)
        self.assertEqual(api.created, [])
        self.assertEqual([c for c in api.calls if c[0] == "head"], [])

    def test_branch_defaults_from_schema(self):
        api = FakeApi([component(branch=None)], {(SLUG, "main"): SHA_A})
        reconcile(api)
        self.assertEqual(len(api.created), 1)

    def test_webhook_repository_filter(self):
        comps = [component(), component(name="other", url="https://github.com/koorikla/other.git")]
        api = FakeApi(comps, {(SLUG, "main"): SHA_A, ("koorikla/other", "main"): SHA_B})
        reconcile(api, repository="Koorikla/Hello-World")
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-aaaaaaaaaaaa"])

    def test_one_head_request_per_repo_and_branch(self):
        comps = [component(name="api"), component(name="web")]
        api = FakeApi(comps, {(SLUG, "main"): SHA_A})
        reconcile(api)
        self.assertEqual(len([c for c in api.calls if c[0] == "head"]), 1)
        self.assertEqual(sorted(r["metadata"]["name"] for r in api.created), ["api-aaaaaaaaaaaa", "web-aaaaaaaaaaaa"])

    def test_build_budget_per_pass(self):
        comps = [component(name="c%d" % i) for i in range(4)]
        api = FakeApi(comps, {(SLUG, "main"): SHA_A})
        state = {}
        reconcile(api, state, max_runs=2)
        self.assertEqual(len(api.created), 2)
        reconcile(api, state, max_runs=2)
        self.assertEqual(len(api.created), 4)

    def test_error_in_one_component_does_not_stop_others(self):
        class Broken(FakeApi):
            def branch_head(self, slug, branch, etag):
                if slug == "koorikla/broken":
                    raise ab.Failed("boom")
                return super().branch_head(slug, branch, etag)
        comps = [component(name="a", url="https://github.com/koorikla/broken"), component(name="b")]
        api = Broken(comps, {(SLUG, "main"): SHA_A})
        rec = reconcile(api)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["b-aaaaaaaaaaaa"])
        self.assertEqual(len(rec.errors), 1)

    # --- registry-aware "already built" (#200) ----------------------------------------------------------------------
    def fresh_stack(self, registry, image=IMAGE_B, built=SHA_B, runs=None):
        # main = hand-off commit C of the build of B, pinning an image of the previous stack's Harbor
        return FakeApi([component()], {(SLUG, "main"): SHA_C}, files={(SLUG, WL, SHA_C): workload(built, image)},
                       compare={(SLUG, built, SHA_C): ["deploy/openchoreo/workload.yaml"]}, registry=registry,
                       runs=runs)

    def test_missing_digest_rebuilds_the_workloads_commit_not_the_head(self):
        api = self.fresh_stack({DIGEST: False})
        rec = reconcile(api, registry_host=REGISTRY)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-bbbbbbbbbbbb-dddddddd"])
        run = api.created[0]
        self.assertEqual(run["spec"]["workflow"]["parameters"]["repository"]["revision"]["commit"], SHA_B)
        self.assertEqual(run["metadata"]["annotations"], {ab.COMMIT_ANNOTATION: SHA_B})
        self.assertEqual(run["metadata"]["labels"]["platform.koorikla.io/trigger"], "auto-build")
        self.assertEqual(rec.state["components"]["hello-world"]["result"], "rebuilt")
        self.assertIn(("registry", REGISTRY, "apps/demo/hello-world", DIGEST), api.calls)

    def test_missing_digest_rebuild_is_idempotent(self):
        api = self.fresh_stack({DIGEST: False})
        state = {}
        reconcile(api, state, registry_host=REGISTRY)
        rec = reconcile(api, state, registry_host=REGISTRY)            # next tick, same head
        self.assertEqual(rec.created, [])
        rec = reconcile(api, {}, registry_host=REGISTRY)               # state lost, run (finished) still there
        self.assertEqual(rec.created, [])
        self.assertEqual(len(api.created), 1)

    def test_present_digest_is_up_to_date_and_remembered(self):
        api = self.fresh_stack({DIGEST: True})
        rec = reconcile(api, registry_host=REGISTRY)
        self.assertEqual(api.created, [])
        self.assertEqual(rec.state["components"]["hello-world"]["result"], "up-to-date")
        self.assertEqual(rec.state["components"]["hello-world"]["image"], IMAGE_B)

    def test_digest_that_disappears_later_is_rebuilt(self):
        api = self.fresh_stack({DIGEST: True})
        state = {}
        reconcile(api, state, registry_host=REGISTRY)
        api.registry[DIGEST] = False                                   # Harbor GC / restore without the artifact
        api.calls.clear()
        reconcile(api, state, registry_host=REGISTRY)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-bbbbbbbbbbbb-dddddddd"])

    def test_unknown_registry_answer_never_rebuilds(self):
        api = self.fresh_stack({DIGEST: None})
        reconcile(api, registry_host=REGISTRY)
        self.assertEqual(api.created, [])

    def test_image_of_another_registry_is_not_checked(self):
        api = self.fresh_stack({DIGEST: False}, image="ghcr.io/koorikla/hello-world:bbbbbbb@" + DIGEST)
        reconcile(api, registry_host=REGISTRY)
        self.assertEqual(api.created, [])
        self.assertEqual([c for c in api.calls if c[0] == "registry"], [])

    def test_registry_check_off_without_registry_host(self):
        api = self.fresh_stack({DIGEST: False})
        reconcile(api)
        self.assertEqual(api.created, [])

    def test_short_built_commit_is_resolved(self):
        api = self.fresh_stack({DIGEST: False}, built="bbbbbbb")
        reconcile(api, registry_host=REGISTRY)
        self.assertEqual(api.created[0]["spec"]["workflow"]["parameters"]["repository"]["revision"]["commit"], SHA_B)

    def test_running_build_blocks_the_rebuild(self):
        running = {"metadata": {"name": "hello-world-aaaaaaaaaaaa", "creationTimestamp": "2026-11-17T12:00:00Z",
                                "labels": {"platform.koorikla.io/trigger": "auto-build",
                                           "openchoreo.dev/component": "hello-world"}}, "status": {}}
        api = self.fresh_stack({DIGEST: False}, runs={"hello-world-aaaaaaaaaaaa": running})
        reconcile(api, registry_host=REGISTRY, now=dt.datetime(2026, 11, 17, 12, 5, tzinfo=dt.timezone.utc))
        self.assertEqual(api.created, [])

    # --- a failed rebuild is retried (live: a k3s restart killed `check`, development stayed ImagePullBackOff) -------
    NOW = dt.datetime(2026, 11, 20, 18, 0, tzinfo=dt.timezone.utc)
    REBUILD = "hello-world-bbbbbbbbbbbb-dddddddd"

    def failed_run(self, name, completed_at="2026-11-20T17:36:38Z"):
        run = run_obj(name, done=True, ok=False)
        run["metadata"]["labels"] = {"platform.koorikla.io/trigger": "auto-build", "openchoreo.dev/component": "hello-world"}
        run["status"]["completedAt"] = completed_at
        return run

    def test_failed_rebuild_is_retried_on_the_next_pass(self):
        api = self.fresh_stack({DIGEST: False})
        state = {}
        reconcile(api, state, registry_host=REGISTRY, now=self.NOW)
        api.runs[self.REBUILD] = self.failed_run(self.REBUILD)               # the run fails
        rec = reconcile(api, state, registry_host=REGISTRY, now=self.NOW)    # same head, same state
        self.assertEqual(rec.created, [self.REBUILD + "-r2"])
        self.assertEqual(api.created[-1]["spec"]["workflow"]["parameters"]["repository"]["revision"]["commit"], SHA_B)
        self.assertEqual(state["components"]["hello-world"], dict(state["components"]["hello-world"],
                                                                  result="rebuilt", run=self.REBUILD + "-r2"))

    def test_failed_rebuild_waits_before_the_retry(self):
        api = self.fresh_stack({DIGEST: False}, runs={self.REBUILD: self.failed_run(self.REBUILD, "2026-11-20T17:58:00Z")})
        rec = reconcile(api, registry_host=REGISTRY, now=self.NOW)
        self.assertEqual(rec.created, [])
        self.assertEqual(rec.errors, [])

    def test_succeeded_rebuild_is_not_retried(self):
        ok = self.failed_run(self.REBUILD)
        ok["status"]["conditions"] = run_obj(self.REBUILD, done=True, ok=True)["status"]["conditions"]
        api = self.fresh_stack({DIGEST: False}, runs={self.REBUILD: ok})
        self.assertEqual(reconcile(api, registry_host=REGISTRY, now=self.NOW).created, [])

    def test_rebuild_gives_up_loudly_after_the_last_attempt(self):
        names = [self.REBUILD, self.REBUILD + "-r2", self.REBUILD + "-r3"]
        api = self.fresh_stack({DIGEST: False}, runs={n: self.failed_run(n) for n in names})
        state = {}
        rec = reconcile(api, state, registry_host=REGISTRY, now=self.NOW)
        self.assertEqual(rec.created, [])
        self.assertEqual(len(rec.errors), 1)
        self.assertIn("FAILED 3 times", rec.errors[0])
        self.assertEqual(state["components"]["hello-world"]["result"], "rebuild-failed")
        rec = reconcile(api, state, registry_host=REGISTRY, now=self.NOW)    # reported once per head
        self.assertEqual((rec.created, rec.errors), ([], []))

    def test_retry_names_stay_dns_labels(self):
        self.assertEqual(ab.rebuild_name("hello-world", SHA_B, DIGEST, 2), "hello-world-bbbbbbbbbbbb-dddddddd-r2")
        self.assertLessEqual(len(ab.rebuild_name("x" * 63, SHA_B, DIGEST, 3)), 63)

    def test_rate_limit_stops_the_pass(self):
        class Limited(FakeApi):
            def branch_head(self, slug, branch, etag):
                raise ab.RateLimited("limit")
        api = Limited([component()], {})
        with self.assertRaises(ab.RateLimited):
            reconcile(api)


# --- PR previews ----------------------------------------------------------------------------------------------------------
NOW = dt.datetime(2026, 11, 17, 12, 0, tzinfo=dt.timezone.utc)
OPT_IN = ("platform.koorikla.io/preview-environments", "enabled")
APP = "preview-hello-world-pr-7"


def preview_app(sha=SHA_B, number="7", comp="hello-world", slug=SLUG, message=None):
    app = {"metadata": {"name": "preview-%s-pr-%s" % (comp, number),
                        "labels": {ab.PREVIEW_LABEL: "true", ab.COMPONENT_LABEL: comp, ab.PR_LABEL: number},
                        "annotations": {ab.COMMIT_ANNOTATION: sha, ab.REPOSITORY_ANNOTATION: slug}}}
    if message:
        app["status"] = {"operationState": {"message": message}}
    return app


def opted_in(opt=True, **kw):
    c = component(**kw)
    if opt:
        c["metadata"]["annotations"] = {OPT_IN[0]: OPT_IN[1]}
    c["status"] = {"latestRelease": {"name": "hello-world-77ff9dc697"}}
    return c


def environment(name="pr-7-hello-world", expires=None, created="2026-11-17T11:00:00Z"):
    labels = {ab.PREVIEW_LABEL: "true"}
    if expires is not None:
        labels[ab.EXPIRES_LABEL] = str(expires)
    return {"metadata": {"name": name, "uid": "env-uid", "labels": labels, "creationTimestamp": created}}


BASE_RELEASE = {"metadata": {"name": "hello-world-77ff9dc697"},
                "spec": {"owner": {"projectName": "demo", "componentName": "hello-world"},
                         "componentType": {"kind": "ClusterComponentType", "name": "deployment/service", "spec": {}},
                         "workload": {"container": {"image": "harbor/apps/demo/hello-world:13b19ed@sha256:" + "1" * 64},
                                      "source": {"branch": "main", "commit": SHA_A}}}}
PR_IMAGE = "harbor/apps/demo/hello-world:bbbbbbb@sha256:" + "2" * 64


def pull(sha=SHA_B, state="open", head_repo=SLUG, labels=()):
    return {"state": state, "head": {"sha": sha, "ref": "feat/x", "repo": {"full_name": head_repo} if head_repo else None},
            "labels": [{"name": n} for n in labels]}


def run_obj(name, done=False, ok=True):
    conds = []
    if done:
        conds = [{"type": "WorkflowCompleted", "status": "True"},
                 {"type": "WorkflowSucceeded", "status": "True" if ok else "False"}]
    return {"metadata": {"name": name, "labels": {}}, "status": {"conditions": conds,
                                                                 "runReference": {"name": name}}}


def argo_wf(image=PR_IMAGE):
    nodes = {"n1": {"templateName": "checkout", "type": "Retry", "phase": "Succeeded"}}
    if image:
        nodes["n2"] = {"templateName": "build", "type": "Pod", "phase": "Succeeded",
                       "outputs": {"parameters": [{"name": "digest-ref", "value": "x@sha256:" + "2" * 64},
                                                  {"name": "image", "value": image}]}}
    return {"status": {"nodes": nodes}}


def binding(release="hello-world-pr-7-bbbbbbbbbbbb", ready_=True, poked=True):
    ann = {ab.RELEASE_ANNOTATION: release} if poked else {}
    return {"metadata": {"name": "hello-world-pr-7", "generation": 2, "annotations": ann}, "spec": {"releaseName": release},
            "status": {"conditions": [{"type": "Ready", "status": "True" if ready_ else "False", "observedGeneration": 2}],
                       "endpoints": [{"name": "http", "externalURLs": {"http": {
                           "host": "pr-7-hello-world-default.dev1.apps.localhost", "path": "/hello-world-http",
                           "port": 19080, "scheme": "http"}}}]}}


class FakePreviewApi(FakeApi):
    def __init__(self, apps, comps, pulls, objects=None, workflows=None):
        super().__init__(comps, {})
        self.apps = apps
        self.pulls = pulls                 # number -> pull
        self.objects = objects or {}       # (resource, name) -> object
        self.workflows = workflows or {}
        self.statuses = []
        self.labels_added = []
        self.releases = []
        self.pokes = []

    def preview_apps(self):
        return self.apps

    def get(self, resource, name):
        if resource == "components":
            return next((c for c in self._components if c["metadata"]["name"] == name), None)
        if resource == "workflowruns":
            return self.runs.get(name) or self.objects.get((resource, name))
        return self.objects.get((resource, name))

    def argo_workflow(self, name):
        return self.workflows.get(name)

    def create_release(self, release):
        self.releases.append(release)
        self.objects[("componentreleases", release["metadata"]["name"])] = release

    def pull(self, slug, number):
        self.calls.append(("pull", slug, number))
        return self.pulls[number]

    def set_status(self, slug, sha, state, description, url, context):
        self.statuses.append((sha, state, description, url, context))

    def add_label(self, slug, number, label):
        self.labels_added.append((slug, number, label))

    def poke_binding(self, name, release):
        self.pokes.append((name, release))
        b = self.objects.get(("releasebindings", name))
        b.setdefault("metadata", {}).setdefault("annotations", {})[ab.RELEASE_ANNOTATION] = release

    def create_resource_binding(self, binding):
        key = ("resourcereleasebindings", binding["metadata"]["name"])
        if key in self.objects:
            return False                   # AlreadyExists
        self.objects[key] = binding
        return True

    def resource_bindings(self):
        return [o for (r, _), o in self.objects.items() if r == "resourcereleasebindings"]

    def pin_resource_release(self, name, release):
        self.calls.append(("pin", name, release))
        self.objects[("resourcereleasebindings", name)]["spec"]["resourceRelease"] = release


def previews(api, state=None, **kw):
    pv = ab.Previews(api, "default", PREFIXES, state if state is not None else {}, OPT_IN, "preview-expired",
                     48 * 3600, now=kw.pop("now", NOW), **kw)
    pv.run()
    return pv


class PreviewHelpers(unittest.TestCase):
    def test_names_match_charts_preview(self):
        self.assertEqual(ab.preview_names("hello-world", "7", SHA_B),
                         ("pr-7-hello-world", "hello-world-pr-7", "hello-world-pr-7-bbbbbbbbbbbb",
                          "hello-world-pr7-bbbbbbbbbbbb"))

    def test_preview_run_name_differs_from_the_main_build_of_the_same_commit(self):
        # a PR head that later lands on main unchanged must still get its GitOps build there
        self.assertNotEqual(ab.preview_names("hello-world", "7", SHA_B)[3], ab.run_name("hello-world", SHA_B))

    def test_build_image(self):
        self.assertEqual(ab.build_image(argo_wf()), PR_IMAGE)
        self.assertIsNone(ab.build_image(argo_wf(image=None)))
        self.assertIsNone(ab.build_image(argo_wf(image="harbor/x:tag-without-digest")))
        self.assertIsNone(ab.build_image(None))

    def test_endpoint_url(self):
        self.assertEqual(ab.endpoint_url(binding()),
                         "http://pr-7-hello-world-default.dev1.apps.localhost:19080/hello-world-http")
        self.assertEqual(ab.endpoint_url({"status": {}}), "")

    def test_ready_needs_the_pinned_release_and_current_generation(self):
        self.assertTrue(ab.ready(binding(), "hello-world-pr-7-bbbbbbbbbbbb"))
        self.assertFalse(ab.ready(binding(), "hello-world-pr-7-aaaaaaaaaaaa"))
        self.assertFalse(ab.ready(binding(ready_=False), "hello-world-pr-7-bbbbbbbbbbbb"))
        stale = binding()
        stale["metadata"]["generation"] = 3
        self.assertFalse(ab.ready(stale, "hello-world-pr-7-bbbbbbbbbbbb"))

    def test_expires_at(self):
        self.assertEqual(ab.expires_at(environment(expires=1800000000), 3600), 1800000000)
        created = int(dt.datetime(2026, 11, 17, 11, 0, tzinfo=dt.timezone.utc).timestamp())
        self.assertEqual(ab.expires_at(environment(), 3600), created + 3600)
        self.assertEqual(ab.expires_at(environment(expires="soon"), 3600), created + 3600)

    def test_duration_seconds(self):
        self.assertEqual(ab.duration_seconds("48h"), 172800)
        self.assertEqual(ab.duration_seconds("1h30m"), 5400)
        for bad in ["", "2d", "h", "48"]:
            with self.assertRaises(ValueError):
                ab.duration_seconds(bad)

    def test_preview_release_swaps_image_and_commit_and_is_owned_by_the_environment(self):
        rel = ab.preview_release(BASE_RELEASE, "hello-world-pr-7-bbbbbbbbbbbb", "default", PR_IMAGE, SHA_B, "feat/x",
                                 environment(), {"x": "y"})
        self.assertEqual(rel["spec"]["workload"]["container"]["image"], PR_IMAGE)
        self.assertEqual(rel["spec"]["workload"]["source"], {"branch": "feat/x", "commit": SHA_B})
        self.assertEqual(rel["spec"]["componentType"], BASE_RELEASE["spec"]["componentType"])
        self.assertEqual(rel["metadata"]["ownerReferences"],
                         [{"apiVersion": "openchoreo.dev/v1alpha1", "kind": "Environment", "name": "pr-7-hello-world",
                           "uid": "env-uid"}])
        self.assertEqual(BASE_RELEASE["spec"]["workload"]["container"]["image"][-64:], "1" * 64)   # base untouched


class PreviewReconcile(unittest.TestCase):
    def api(self, objects=None, pulls=None, comps=None, apps=None, workflows=None, runs=None):
        objs = {("environments", "pr-7-hello-world"): environment(expires=int(NOW.timestamp()) + 3600),
                ("componentreleases", "hello-world-77ff9dc697"): BASE_RELEASE}
        objs.update(objects or {})
        api = FakePreviewApi(apps if apps is not None else [preview_app()], comps or [opted_in()],
                             pulls or {"7": pull()}, objs, workflows)
        api.runs.update(runs or {})
        return api

    def test_new_pr_head_is_built_without_gitops(self):
        api = self.api()
        pv = previews(api)
        self.assertEqual([r["metadata"]["name"] for r in api.created], ["hello-world-pr7-bbbbbbbbbbbb"])
        run = api.created[0]
        params = run["spec"]["workflow"]["parameters"]
        self.assertEqual(params["repository"]["revision"], {"branch": "main", "commit": SHA_B})   # never the PR branch
        self.assertEqual(params["gitops"], {"enabled": False})
        self.assertEqual(run["metadata"]["labels"]["platform.koorikla.io/trigger"], "preview")
        self.assertEqual(run["metadata"]["labels"][ab.PR_LABEL], "7")
        self.assertEqual(pv.created, ["hello-world-pr7-bbbbbbbbbbbb"])
        self.assertEqual(api.statuses[-1][:2], (SHA_B, "pending"))
        self.assertEqual(api.statuses[-1][4], "openchoreo/preview")

    def test_running_build_waits_and_posts_the_same_status_once(self):
        api = self.api(runs={"hello-world-pr7-bbbbbbbbbbbb": run_obj("hello-world-pr7-bbbbbbbbbbbb")})
        state = {}
        previews(api, state)
        previews(api, state)
        self.assertEqual(api.created, [])
        self.assertEqual(len(api.statuses), 1)

    def test_finished_build_cuts_the_release_from_the_latest_main_release(self):
        api = self.api(runs={"hello-world-pr7-bbbbbbbbbbbb": run_obj("hello-world-pr7-bbbbbbbbbbbb", done=True)},
                       workflows={"hello-world-pr7-bbbbbbbbbbbb": argo_wf()})
        previews(api)
        self.assertEqual(len(api.releases), 1)
        rel = api.releases[0]
        self.assertEqual(rel["metadata"]["name"], "hello-world-pr-7-bbbbbbbbbbbb")
        self.assertEqual(rel["spec"]["workload"]["container"]["image"], PR_IMAGE)
        self.assertEqual(rel["metadata"]["labels"]["openchoreo.dev/component"], "hello-world")

    def test_head_without_build_output_previews_the_main_image(self):
        api = self.api(runs={"hello-world-pr7-bbbbbbbbbbbb": run_obj("hello-world-pr7-bbbbbbbbbbbb", done=True)},
                       workflows={"hello-world-pr7-bbbbbbbbbbbb": argo_wf(image=None)})
        previews(api)
        self.assertEqual(api.releases[0]["spec"]["workload"]["container"]["image"],
                         BASE_RELEASE["spec"]["workload"]["container"]["image"])

    def test_failed_build_reports_failure_and_cuts_nothing(self):
        api = self.api(runs={"hello-world-pr7-bbbbbbbbbbbb": run_obj("hello-world-pr7-bbbbbbbbbbbb", done=True,
                                                                     ok=False)})
        previews(api)
        self.assertEqual(api.releases, [])
        self.assertEqual(api.statuses[-1][1], "failure")

    def test_ready_binding_posts_success_with_the_preview_url(self):
        api = self.api(objects={("componentreleases", "hello-world-pr-7-bbbbbbbbbbbb"): {"metadata": {}},
                                ("releasebindings", "hello-world-pr-7"): binding()})
        previews(api)
        sha, state, desc, url, ctx = api.statuses[-1]
        self.assertEqual((sha, state), (SHA_B, "success"))
        self.assertEqual(url, "http://pr-7-hello-world-default.dev1.apps.localhost:19080/hello-world-http")
        self.assertIn("pr-7-hello-world", desc)
        self.assertEqual(api.created, [])

    def test_new_release_pokes_the_binding_once_so_openchoreo_reconciles_it(self):
        api = self.api(runs={"hello-world-pr7-bbbbbbbbbbbb": run_obj("hello-world-pr7-bbbbbbbbbbbb", done=True)},
                       workflows={"hello-world-pr7-bbbbbbbbbbbb": argo_wf()},
                       objects={("releasebindings", "hello-world-pr-7"): binding(ready_=False, poked=False)})
        state = {}
        previews(api, state)
        self.assertEqual(api.pokes, [("hello-world-pr-7", "hello-world-pr-7-bbbbbbbbbbbb")])
        previews(api, state)
        self.assertEqual(len(api.pokes), 1)
        self.assertEqual(len(api.releases), 1)

    def test_binding_not_ready_is_pending(self):
        api = self.api(objects={("componentreleases", "hello-world-pr-7-bbbbbbbbbbbb"): {"metadata": {}},
                                ("releasebindings", "hello-world-pr-7"): binding(ready_=False)})
        previews(api)
        self.assertEqual(api.statuses[-1][1], "pending")

    def test_ttl_over_labels_the_pr_and_builds_nothing(self):
        api = self.api(objects={("environments", "pr-7-hello-world"): environment(expires=int(NOW.timestamp()) - 1)})
        previews(api)
        self.assertEqual(api.labels_added, [(SLUG, "7", "preview-expired")])
        self.assertEqual(api.created, [])
        self.assertEqual(api.statuses[-1][1], "error")

    def test_unstamped_environment_expires_from_its_creation(self):
        api = self.api(objects={("environments", "pr-7-hello-world"): environment(created="2026-11-15T11:00:00Z")})
        previews(api)
        self.assertEqual(api.labels_added, [(SLUG, "7", "preview-expired")])

    def test_already_expired_pr_is_left_alone(self):
        api = self.api(pulls={"7": pull(labels=["preview-expired"])})
        previews(api)
        self.assertEqual(api.labels_added, [])
        self.assertEqual(api.created, [])

    def test_missing_environment_waits_and_reports_argo_cds_message(self):
        api = self.api(apps=[preview_app(message="admission webhook denied: tenant demo already runs 2 preview")],
                       objects={("environments", "pr-7-hello-world"): None})
        previews(api)
        self.assertEqual(api.created, [])
        self.assertIn("already runs 2 preview", api.statuses[-1][2])

    def test_fork_prs_are_never_built(self):
        for head in ["someone/hello-world", None]:
            api = self.api(pulls={"7": pull(head_repo=head)})
            previews(api)
            self.assertEqual(api.created, [])
            self.assertEqual(api.statuses[-1][1], "failure")

    def test_opt_in_is_rechecked_on_the_component(self):
        api = self.api(comps=[opted_in(opt=False)])
        previews(api)
        self.assertEqual(api.created, [])
        self.assertEqual(api.statuses, [])
        self.assertNotIn(("pull", SLUG, "7"), api.calls)

    def test_repository_must_be_the_components_build_repository(self):
        api = self.api(apps=[preview_app(slug="koorikla/other")])
        previews(api)
        self.assertEqual(api.created, [])
        self.assertEqual(api.statuses, [])

    def test_stale_application_waits_for_argo_cd(self):
        for pr in [pull(sha=SHA_C), pull(state="closed")]:
            api = self.api(pulls={"7": pr})
            previews(api)
            self.assertEqual(api.created, [])
            self.assertEqual(api.statuses, [])

    def test_malformed_application_is_skipped(self):
        for app in [preview_app(sha="main"), preview_app(number="7; rm"), preview_app(comp="Hello"),
                    preview_app(slug="not a slug")]:
            api = self.api(apps=[app])
            previews(api)
            self.assertEqual(api.created, [])
            self.assertEqual(api.calls, [])

    def test_budget_is_shared_with_the_build_pass(self):
        api = self.api()
        previews(api, max_runs=0)
        self.assertEqual(api.created, [])

    def test_state_of_closed_prs_is_dropped(self):
        api = self.api(apps=[])
        state = {"previews": {APP: {"status": "x"}}}
        previews(api, state)
        self.assertEqual(state["previews"], {})

    def test_webhook_repository_filter(self):
        api = self.api()
        previews(api, repository="koorikla/other")
        self.assertEqual(api.created, [])


DB_RELEASE = {"metadata": {"name": "hello-world-pr-7-bbbbbbbbbbbb"},
              "spec": {"workload": {"container": {"image": PR_IMAGE},
                                    "dependencies": {"resources": [{"ref": "orders-db", "envBindings": {"uri": "X"}}]}}}}


class PreviewResources(unittest.TestCase):
    """#330: a preview of an app with dependencies.resources gets its own instance of each Resource."""

    def api(self, objects=None):
        objs = {("environments", "pr-7-hello-world"): environment(expires=int(NOW.timestamp()) + 3600),
                ("componentreleases", "hello-world-pr-7-bbbbbbbbbbbb"): DB_RELEASE,
                ("releasebindings", "hello-world-pr-7"): binding(ready_=False)}
        objs.update(objects or {})
        return FakePreviewApi([preview_app()], [opted_in()], {"7": pull()}, objs)

    def test_each_declared_resource_gets_a_binding_in_the_preview_environment_owned_by_it(self):
        api = self.api()
        previews(api)
        rrb = api.objects[("resourcereleasebindings", "orders-db-pr-7-hello-world")]
        self.assertEqual(rrb["spec"], {"owner": {"projectName": "demo", "resourceName": "orders-db"},
                                       "environment": "pr-7-hello-world", "retainPolicy": "Delete"})
        self.assertEqual(rrb["metadata"]["annotations"], {ab.RESOURCE_RELEASE_ANNOTATION: "latest"})
        self.assertEqual(rrb["metadata"]["ownerReferences"][0]["kind"], "Environment")
        self.assertEqual(rrb["metadata"]["ownerReferences"][0]["name"], "pr-7-hello-world")
        # The Environment must outlive the binding: OpenChoreo's RenderedRelease finalizer resolves the data plane
        # through it, so a binding outliving its Environment never finalizes (hello-world#35 leak). blockOwnerDeletion
        # makes the foreground delete of the Environment (Argo, TTL policy) wait for the binding.
        self.assertIs(rrb["metadata"]["ownerReferences"][0].get("blockOwnerDeletion"), True)
        self.assertEqual(rrb["metadata"]["labels"][ab.PREVIEW_LABEL], "true")
        self.assertNotIn("resourceRelease", rrb["spec"])     # ResourcePins sets it
        self.assertEqual(api.statuses[-1][1], "pending")     # Ready only once the app binding (and so the DB) is

    def test_existing_binding_is_left_alone(self):
        mine = {"metadata": {"name": "orders-db-pr-7-hello-world"}, "spec": {"resourceRelease": "orders-db-1"}}
        api = self.api({("resourcereleasebindings", "orders-db-pr-7-hello-world"): mine})
        previews(api)
        self.assertIs(api.objects[("resourcereleasebindings", "orders-db-pr-7-hello-world")], mine)

    def test_app_without_resources_gets_none(self):
        api = self.api({("componentreleases", "hello-world-pr-7-bbbbbbbbbbbb"): {"metadata": {}}})
        previews(api)
        self.assertEqual(api.resource_bindings(), [])


def rrb(name, env="development", resource="orders-db", pin=None, follow=True):
    spec = {"owner": {"projectName": "demo", "resourceName": resource}, "environment": env}
    if pin:
        spec["resourceRelease"] = pin
    ann = {ab.RESOURCE_RELEASE_ANNOTATION: "latest"} if follow else {}
    return {"metadata": {"name": name, "annotations": ann}, "spec": spec}


def resource(latest="orders-db-7bbd4b8fc7"):
    return {"metadata": {"name": "orders-db"}, "status": {"latestRelease": {"name": latest}} if latest else {}}


class ResourcePins(unittest.TestCase):
    """#330: ResourceReleaseBindings annotated "latest" need no hand-computed resourceRelease."""

    def run_pins(self, bindings, res=None, gated=("production",)):
        objs = {("resourcereleasebindings", b["metadata"]["name"]): b for b in bindings}
        objs[("resources", "orders-db")] = res if res is not None else resource()
        api = FakePreviewApi([], [], {}, objs)
        pins = ab.ResourcePins(api, gated)
        pins.run()
        return api, pins

    def pin(self, api, name):
        return api.objects[("resourcereleasebindings", name)]["spec"].get("resourceRelease")

    def test_unset_pin_is_set_to_the_resources_latest_release(self):
        api, _ = self.run_pins([rrb("orders-db-development")])
        self.assertEqual(self.pin(api, "orders-db-development"), "orders-db-7bbd4b8fc7")

    def test_new_release_after_a_type_change_moves_the_pin(self):
        api, _ = self.run_pins([rrb("orders-db-development", pin="orders-db-7bbd4b8fc7")],
                               res=resource("orders-db-0123456789"))
        self.assertEqual(self.pin(api, "orders-db-development"), "orders-db-0123456789")

    def test_up_to_date_pin_is_not_written(self):
        api, _ = self.run_pins([rrb("orders-db-development", pin="orders-db-7bbd4b8fc7")])
        self.assertEqual(api.calls, [])

    def test_binding_without_the_annotation_keeps_its_git_pin(self):
        api, _ = self.run_pins([rrb("orders-db-staging", env="staging", pin="orders-db-old", follow=False)])
        self.assertEqual(self.pin(api, "orders-db-staging"), "orders-db-old")

    def test_negative_gated_environment_is_never_written_even_when_annotated(self):
        api, _ = self.run_pins([rrb("orders-db-production", env="production", pin="orders-db-old")])
        self.assertEqual(self.pin(api, "orders-db-production"), "orders-db-old")
        self.assertEqual(api.calls, [])

    def test_resource_without_a_release_yet_waits(self):
        api, _ = self.run_pins([rrb("orders-db-development")], res=resource(latest=None))
        self.assertIsNone(self.pin(api, "orders-db-development"))

    def test_preview_binding_is_pinned_like_any_other(self):
        api, _ = self.run_pins([rrb("orders-db-pr-7-hello-world", env="pr-7-hello-world")])
        self.assertEqual(self.pin(api, "orders-db-pr-7-hello-world"), "orders-db-7bbd4b8fc7")

    def test_error_on_one_binding_does_not_stop_the_others(self):
        class Boom(FakePreviewApi):
            def get(self, kind, name):
                if name == "broken":
                    raise ab.Failed("GET resources/broken -> HTTP 500")
                return super().get(kind, name)
        objs = {("resourcereleasebindings", "a"): rrb("a", resource="broken"),
                ("resourcereleasebindings", "b"): rrb("b"), ("resources", "orders-db"): resource()}
        api = Boom([], [], {}, objs)
        pins = ab.ResourcePins(api, ["production"])
        pins.run()
        self.assertEqual(len(pins.errors), 1)
        self.assertEqual(self.pin(api, "b"), "orders-db-7bbd4b8fc7")


if __name__ == "__main__":
    unittest.main()
