"""Unit tests for the promotion gate's pure functions (hack/tests/test_promotion_gate.sh). Stdlib only."""
import base64
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate  # noqa: E402

WINDOW = [{"start": "Fri 16:00", "end": "Mon 08:00", "timeZone": "Europe/Tallinn", "environments": ["production"]}]


def utc(*a):
    return dt.datetime(*a, tzinfo=dt.timezone.utc)


class JsonEnv(unittest.TestCase):
    def setUp(self):
        self._env = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)

    def test_decodes_base64_json(self):
        os.environ["FREEZE_WINDOWS_B64"] = base64.b64encode(json.dumps(WINDOW).encode()).decode()
        self.assertEqual(gate.json_env("FREEZE_WINDOWS", []), WINDOW)

    def test_unset_gives_default(self):
        os.environ.pop("GATED_TARGETS_B64", None)
        self.assertIsNone(gate.json_env("GATED_TARGETS", None))

    def test_plain_json_is_rejected(self):
        # the old JSON-looking form must not be accepted silently
        os.environ["GATED_TARGETS_B64"] = '["production"]'
        with self.assertRaises(ValueError):
            gate.json_env("GATED_TARGETS", None)


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


def read(path):
    with open(path) as f:
        return f.read()


def workload(project, component, repo):
    return {"spec": {"owner": {"projectName": project, "componentName": component}, "source": {"repository": repo}}}


class Repository(unittest.TestCase):
    def test_from_workload(self):
        wl = [workload("demo", "hello-world", "https://github.com/koorikla/hello-world")]
        self.assertEqual(gate.workload_repository(wl, "demo", "hello-world", "koorikla"), "koorikla/hello-world")
        wl = [workload("demo", "hello-world", "https://github.com/koorikla/hello-world.git")]
        self.assertEqual(gate.workload_repository(wl, "demo", "hello-world", "koorikla"), "koorikla/hello-world")

    def test_other_owner_rejected(self):
        wl = [workload("demo", "hello-world", "https://github.com/evil/hello-world")]
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository(wl, "demo", "hello-world", "koorikla")

    def test_not_github_or_odd_url_rejected(self):
        for url in ("https://gitlab.com/koorikla/x", "git@github.com:koorikla/x.git", "https://github.com/koorikla/x/y",
                    "https://github.com/koorikla/../x", "https://github.com/koorikla/..", ""):
            with self.assertRaises(gate.GateFailed, msg=url):
                gate.workload_repository([workload("demo", "c", url)], "demo", "c", "koorikla")

    def test_other_component_or_ambiguous_rejected(self):
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository([workload("other", "c", "https://github.com/koorikla/x")], "demo", "c", "koorikla")
        two = [workload("demo", "c", "https://github.com/koorikla/x"), workload("demo", "c", "https://github.com/koorikla/y")]
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository(two, "demo", "c", "koorikla")


@unittest.skipUnless(shutil.which("openssl"), "openssl not installed")
class AppJwt(unittest.TestCase):
    """RS256 of the App JWT, checked against openssl (the gate itself only has the stdlib)."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.pkcs8 = os.path.join(cls.dir, "k8.pem")
        cls.pkcs1 = os.path.join(cls.dir, "k1.pem")
        cls.pub = os.path.join(cls.dir, "pub.pem")
        subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", cls.pkcs8],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", cls.pkcs8, "-traditional", "-out", cls.pkcs1], check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", cls.pkcs8, "-pubout", "-out", cls.pub], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    def verify(self, message, signature):
        sig = os.path.join(self.dir, "sig")
        msg = os.path.join(self.dir, "msg")
        with open(sig, "wb") as f:
            f.write(signature)
        with open(msg, "wb") as f:
            f.write(message)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sig, msg], capture_output=True)
        return r.returncode == 0

    def test_pkcs1_and_pkcs8_keys_sign_identically(self):
        k1 = gate.rsa_private_key(read(self.pkcs1))
        k8 = gate.rsa_private_key(read(self.pkcs8))
        self.assertEqual(k1, k8)
        self.assertEqual(k1[1], 65537)

    def test_jwt_verifies_with_openssl(self):
        key = gate.rsa_private_key(read(self.pkcs1))
        token = gate.app_jwt("12345", key, now=1_800_000_000)
        head, claims, sig = token.split(".")
        pad = lambda s: s + "=" * (-len(s) % 4)  # noqa: E731
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(head))), {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(json.loads(base64.urlsafe_b64decode(pad(claims))),
                         {"iat": 1_800_000_000 - 60, "exp": 1_800_000_000 + 540, "iss": "12345"})
        self.assertTrue(self.verify((head + "." + claims).encode(), base64.urlsafe_b64decode(pad(sig))))
        self.assertFalse(self.verify(b"tampered", base64.urlsafe_b64decode(pad(sig))))

    def test_rejects_non_rsa_pem(self):
        with self.assertRaises(gate.GateFailed):
            gate.rsa_private_key("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----\n")


class Secrets(unittest.TestCase):
    def test_reads_mounted_file_then_env(self):
        d = tempfile.mkdtemp()
        try:
            with open(os.path.join(d, "github-app-id"), "w") as f:
                f.write("42\n")
            os.environ["SECRETS_DIR"] = d
            os.environ["CLIENT_SECRET"] = "from-env"
            self.assertEqual(gate.secret("github-app-id"), "42")
            self.assertEqual(gate.secret("client-secret"), "from-env")
        finally:
            os.environ.pop("SECRETS_DIR", None)
            os.environ.pop("CLIENT_SECRET", None)
            shutil.rmtree(d)


if __name__ == "__main__":
    unittest.main()
