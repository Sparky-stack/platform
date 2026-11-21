#!/usr/bin/env python3
"""Unit tests for ci/scripts/openchoreo/validate-manifests.py against ci/fixtures/openchoreo-app (hello-world's shape).
Run: uv run --no-project --with pyyaml --with jsonschema python3 ci/tests/openchoreo-validate-manifests.test.py
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

CI = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = CI / "scripts" / "openchoreo" / "validate-manifests.py"
FIXTURE = CI / "fixtures" / "openchoreo-app"


def run(edit=None):
    with tempfile.TemporaryDirectory() as d:
        root = pathlib.Path(d) / "openchoreo"
        shutil.copytree(FIXTURE, root)
        if edit:
            path, old, new = edit
            text = (root / path).read_text()
            assert old in text, (path, old)
            (root / path).write_text(text.replace(old, new, 1))
        p = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
        return p.returncode, p.stdout


class Validate(unittest.TestCase):
    def test_fixture_is_valid(self):
        rc, out = run()
        self.assertEqual(rc, 0, out)
        self.assertIn("validated 8 objects", out)

    def bad(self, edit, needle):
        rc, out = run(edit)
        self.assertEqual(rc, 1, out)
        self.assertIn(needle, out)

    def test_unknown_field(self):  # strict: the API server would prune it silently
        self.bad(("workload.yaml", "  endpoints:", "  endpoint:"), "Additional properties are not allowed")

    def test_namespace(self):
        self.bad(("orders-db.yaml", "  name: orders-db\n", "  name: orders-db\n  namespace: x\n"), "metadata.namespace")

    def test_binding_name(self):
        self.bad(("release-bindings/staging.yaml", "name: hello-world-staging", "name: hw-staging"), "name must be")

    def test_secret_key(self):
        self.bad(("workload.yaml", "key: greeting", "key: nope"), "has no SecretReference key")

    def test_unknown_component(self):
        self.bad(("workload.yaml", "componentName: hello-world", "componentName: other"), "names no Component")

    def test_project_mismatch(self):
        self.bad(("orders-db.yaml", "projectName: demo", "projectName: other"), "projectName differs")

    def test_resource_without_binding(self):
        self.bad(("release-bindings/orders-db-development.yaml", "environment: development", "environment: dev2"),
                 "no ResourceReleaseBinding for development")

    def test_gated_follows_latest(self):
        self.bad(("release-bindings/orders-db-development.yaml", "environment: development", "environment: production"),
                 "production is gated")

    def test_unknown_kind(self):
        self.bad(("orders-db.yaml", "kind: Resource", "kind: Database"), "no platform schema")


if __name__ == "__main__":
    unittest.main()
