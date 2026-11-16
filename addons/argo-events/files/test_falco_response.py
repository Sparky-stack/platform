"""Unit tests for falco_response.py (hack/tests/test_promotion_gate.sh runs them too). Stdlib only."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import falco_response as fr  # noqa: E402

RRS = [
    {"spec": {"owner": {"projectName": "demo", "componentName": "hello-world"}, "environmentName": "production"},
     "status": {"resources": [
         {"kind": "Namespace", "name": "dp-default-demo-production-1"},
         {"kind": "Deployment", "name": "hello-world", "namespace": "dp-default-demo-production-1"}]}},
    {"spec": {"owner": {"projectName": "demo", "componentName": "hello"}, "environmentName": "production"},
     "status": {"resources": [{"kind": "Deployment", "name": "hello", "namespace": "dp-default-demo-production-1"}]}},
]


class Tests(unittest.TestCase):
    def test_priority(self):
        self.assertTrue(fr.severe_enough("Critical", "critical"))
        self.assertTrue(fr.severe_enough("Emergency", "critical"))
        self.assertFalse(fr.severe_enough("Error", "critical"))
        self.assertFalse(fr.severe_enough("bogus", "critical"))

    def test_longest_owner_wins(self):
        rr, res = fr.match_workload(RRS, "dp-default-demo-production-1", "hello-world-6c9d8-abcde")
        self.assertEqual(rr["spec"]["owner"]["componentName"], "hello-world")
        self.assertEqual(res["name"], "hello-world")

    def test_other_namespace_no_match(self):
        self.assertEqual(fr.match_workload(RRS, "dp-default-demo-staging-1", "hello-world-1-2"), (None, None))

    def test_enrich_skips_low_priority_and_platform_namespaces(self):
        os.environ["MINIMUM_PRIORITY"] = "critical"
        low = fr.enrich({"priority": "Warning", "output_fields": {"k8s.ns.name": "dp-x"}}, "dev1")
        self.assertIn("priority below", low["skipped"])
        platform = fr.enrich({"priority": "Critical", "output_fields": {"k8s.ns.name": "kube-system"}}, "dev1")
        self.assertIn("not an OpenChoreo app namespace", platform["skipped"])


EVENT = {"uuid": "4e1a2b3c-0000-4000-8000-000000000001", "priority": "Critical",
         "rule": "Platform crypto miner indicators", "output": "Crypto miner indicator",
         "output_fields": {"k8s.ns.name": "dp-default-demo-production-1", "k8s.pod.name": "hello-world-6c9d8-abcde",
                           "cluster": "prod1"}}


class ClusterIdentity(unittest.TestCase):
    """The cluster comes from the authenticated per-cluster endpoint (Workflow parameter), not from the payload."""

    def setUp(self):
        os.environ["MINIMUM_PRIORITY"] = "critical"
        os.environ["ORG_NAMESPACE"] = "default"
        self.posted = []
        self.kube = fr.kube

        def fake_kube(method, path, body=None):
            if method == "POST":
                self.posted.append(body)
                return {}
            if path.endswith("/renderedreleases"):
                return {"items": RRS}
            if path.endswith("/environments/production"):
                return {"spec": {"dataPlaneRef": {"kind": "ClusterDataPlane", "name": "prod1"}}}
            raise AssertionError(path)
        fr.kube = fake_kube

    def tearDown(self):
        fr.kube = self.kube

    def test_no_authenticated_cluster_is_skipped(self):
        self.assertIn("no authenticated cluster", fr.enrich(EVENT, "")["skipped"])

    def test_payload_naming_another_cluster_is_skipped(self):
        ctx = fr.enrich(EVENT, "dev1")
        self.assertIn("names cluster prod1 but arrived on the endpoint of cluster dev1", ctx["skipped"])

    def test_namespace_of_another_clusters_data_plane_is_skipped(self):
        event = dict(EVENT, output_fields={k: v for k, v in EVENT["output_fields"].items() if k != "cluster"})
        ctx = fr.enrich(event, "dev1")
        self.assertIn("runs on data plane prod1, but the event came from cluster dev1", ctx["skipped"])

    def test_own_workload_resolves_and_the_event_names_the_cluster(self):
        ctx = fr.enrich(EVENT, "prod1")
        self.assertNotIn("skipped", ctx)
        self.assertEqual((ctx["cluster"], ctx["component"], ctx["dataPlane"]), ("prod1", "hello-world", "prod1"))
        fr.record(ctx)
        self.assertEqual(len(self.posted), 1)
        self.assertIn("cluster=prod1 ", self.posted[0]["note"])


if __name__ == "__main__":
    unittest.main()
