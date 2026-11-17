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


def workload(commit):
    return "spec:\n  source:\n    repository: https://github.com/koorikla/hello-world\n    commit: \"%s\"\n" % commit


class FakeApi:
    def __init__(self, components, heads, files=None, compare=None, runs=None):
        self._components = components
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

    def test_rate_limit_stops_the_pass(self):
        class Limited(FakeApi):
            def branch_head(self, slug, branch, etag):
                raise ab.RateLimited("limit")
        api = Limited([component()], {})
        with self.assertRaises(ab.RateLimited):
            reconcile(api)


if __name__ == "__main__":
    unittest.main()
