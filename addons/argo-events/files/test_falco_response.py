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
        self.assertIn("skipped", fr.enrich({"priority": "Warning", "output_fields": {"k8s.ns.name": "dp-x"}}))
        self.assertIn("skipped", fr.enrich({"priority": "Critical", "output_fields": {"k8s.ns.name": "kube-system"}}))


if __name__ == "__main__":
    unittest.main()
