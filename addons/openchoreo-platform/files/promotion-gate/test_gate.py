"""Unit tests for the promotion gate's pure functions (hack/tests/test_promotion_gate.sh). Stdlib only."""
import datetime as dt
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate  # noqa: E402

WINDOW = [{"start": "Fri 16:00", "end": "Mon 08:00", "timeZone": "Europe/Tallinn", "environments": ["production"]}]


def utc(*a):
    return dt.datetime(*a, tzinfo=dt.timezone.utc)


class Freeze(unittest.TestCase):
    def test_inside_weekend_window(self):
        # Fri 2026-11-13 16:30 Tallinn (EET, UTC+2) = 14:30 UTC
        self.assertIsNotNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 13, 14, 30)))
        self.assertIsNotNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 15, 12, 0)))   # Sunday
        self.assertIsNotNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 16, 5, 59)))   # Mon 07:59 local

    def test_outside_window(self):
        self.assertIsNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 13, 13, 59)))     # Fri 15:59 local
        self.assertIsNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 16, 6, 0)))       # Mon 08:00 local
        self.assertIsNone(gate.active_freeze(WINDOW, "production", utc(2026, 11, 18, 10, 0)))      # Wednesday

    def test_daylight_saving(self):
        # Fri 2026-07-17 16:30 Tallinn (EEST, UTC+3) = 13:30 UTC
        self.assertIsNotNone(gate.active_freeze(WINDOW, "production", utc(2026, 7, 17, 13, 30)))
        self.assertIsNone(gate.active_freeze(WINDOW, "production", utc(2026, 7, 17, 12, 59)))

    def test_other_environment_not_frozen(self):
        self.assertIsNone(gate.active_freeze(WINDOW, "staging", utc(2026, 11, 15, 12, 0)))

    def test_bad_bound(self):
        with self.assertRaises(ValueError):
            gate.minute_of_week("Friday16")


class SetRelease(unittest.TestCase):
    def test_uncomments_placeholder(self):
        text = "spec:\n  environment: production\n  # releaseName: hello-world-<hash>\n  componentTypeEnvironmentConfigs: {}\n"
        out = gate.set_release(text, "hello-world-58cb494fc")
        self.assertIn("\n  releaseName: hello-world-58cb494fc\n", out)
        self.assertNotIn("<hash>", out)

    def test_replaces_existing(self):
        out = gate.set_release("spec:\n  environment: production\n  releaseName: old\n", "new")
        self.assertEqual(out, "spec:\n  environment: production\n  releaseName: new\n")

    def test_inserts_after_environment(self):
        out = gate.set_release("spec:\n  environment: production\n  state: Active\n", "r1")
        self.assertEqual(out, "spec:\n  environment: production\n  releaseName: r1\n  state: Active\n")


class Bindings(unittest.TestCase):
    def test_endpoint_urls(self):
        b = {"status": {"endpoints": [{"name": "http", "externalURLs": {"http": {
            "host": "staging-default.dev1.apps.localhost", "path": "/hello-world-http", "port": 19080, "scheme": "http"}}}]}}
        self.assertEqual(gate.endpoint_urls(b), ["http://staging-default.dev1.apps.localhost:19080/hello-world-http"])

    def test_next_environment(self):
        p = {"spec": {"promotionPaths": [
            {"sourceEnvironmentRef": {"name": "development"}, "targetEnvironmentRefs": [{"name": "staging"}]},
            {"sourceEnvironmentRef": {"name": "staging"}, "targetEnvironmentRefs": [{"name": "production"}]}]}}
        self.assertEqual(gate.next_environment(p, "staging"), ["production"])
        self.assertEqual(gate.next_environment(p, "production"), [])


if __name__ == "__main__":
    unittest.main()
