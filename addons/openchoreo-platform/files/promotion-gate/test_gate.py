"""Unit tests for the promotion gate's pure functions (hack/tests/test_promotion_gate.sh). Stdlib only."""
import base64
import datetime as dt
import json
import os
import re
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


class Smoke(unittest.TestCase):
    """smoke: 2xx only; connect podHostIP reaches the Gateway by node IP with the app host as Host header (#156)."""

    @classmethod
    def setUpClass(cls):
        import http.server
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                host = self.headers.get("Host", "")
                code = {"/ok/": 200, "/down/": 503, "/moved/": 302}.get(self.path, 404)
                if not host.startswith("staging-default.dev1.apps.localhost:"):
                    code = 404             # like the Gateway: unknown Host -> no route
                self.send_response(code)
                if code == 302:
                    self.send_header("Location", "/ok/")
                self.end_headers()

            def log_message(self, *a):
                pass

        cls.srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.port = cls.srv.server_address[1]
        cls.base = "http://staging-default.dev1.apps.localhost:%d" % cls.port

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def probe(self, path, ip="127.0.0.1"):
        gate.smoke([self.base + path], "/", attempts=2, connect_ip=ip, sleep=lambda s: None)

    def test_pod_host_ips_only_running_pods(self):
        tree = {"renderedReleases": [{"nodes": [
            {"kind": "Pod", "object": {"status": {"phase": "Running", "hostIP": "172.18.0.15"}}},
            {"kind": "Pod", "object": {"status": {"phase": "Pending", "hostIP": "172.18.0.16"}}},
            {"kind": "Service", "object": {"status": {"hostIP": "172.18.0.17"}}}]}]}
        self.assertEqual(gate.pod_host_ips(tree), ["172.18.0.15"])
        self.assertEqual(gate.pod_host_ips({}), [])

    def test_request_connects_to_node_with_host_header(self):
        req = gate.smoke_request("http://staging-default.dev1.apps.localhost:19080/hello-world-http/", "172.18.0.15")
        self.assertEqual(req.full_url, "http://172.18.0.15:19080/hello-world-http/")
        self.assertEqual(req.get_header("Host"), "staging-default.dev1.apps.localhost:19080")
        self.assertRaises(gate.GateFailed, gate.smoke_request, "https://a.example/", "172.18.0.15")

    def test_200_via_node_ip_passes(self):
        self.probe("/ok")

    def test_non_2xx_fails(self):
        for path in ("/down", "/moved", "/missing"):
            with self.subTest(path=path), self.assertRaisesRegex(gate.GateFailed, "smoke test failed.*HTTP"):
                self.probe(path)

    def test_without_connect_the_localhost_name_is_not_the_gateway(self):
        # what the probe did before #156 locally: the host resolves to loopback, nothing serves its port there
        with self.assertRaises(gate.GateFailed):
            gate.smoke(["http://127.0.0.1:9/ok"], "/", attempts=1, sleep=lambda s: None)


def staging_binding(ready="True", ready_since="2026-11-16T18:33:15Z", spec_changed="2026-11-16T18:33:01Z",
                    ready_gen=3, observed=3, delivery=None):
    """A ReleaseBinding as openchoreo-api 1.3.3 returns it (no status.delivery) unless delivery is given."""
    status = {"observedGeneration": observed, "lastSpecUpdateTime": spec_changed, "conditions": [
        {"type": "Ready", "status": ready, "observedGeneration": ready_gen, "lastTransitionTime": ready_since,
         "reason": "Ready", "message": "ReleaseBinding is ready"}]}
    if delivery is not None:
        status["delivery"] = delivery
    return {"metadata": {"name": "hello-world-staging"}, "spec": {"environment": "staging"}, "status": status}


class RolloutEvidence(unittest.TestCase):
    def test_api_shape_ready_after_spec_change(self):
        self.assertIn("Ready since 2026-11-16T18:33:15Z", gate.rollout_evidence(staging_binding()))

    def test_stale_ready_from_previous_release_fails(self):
        # releaseName just changed (18:33:01); Ready=True is still the previous release's (17:47:51)
        with self.assertRaisesRegex(gate.GateFailed, "before the spec change"):
            gate.rollout_evidence(staging_binding(ready_since="2026-11-16T17:47:51Z"))

    def test_not_ready_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, "not Ready"):
            gate.rollout_evidence(staging_binding(ready="False"))

    def test_ready_of_an_older_generation_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, "generation 2"):
            gate.rollout_evidence(staging_binding(ready_gen=2))

    def test_missing_transition_time_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, "lastTransitionTime"):
            gate.rollout_evidence(staging_binding(ready_since=None))

    def test_cr_shape_delivery_of_current_rollout(self):
        d = {"rolloutId": "r.2", "startedAt": "2026-11-16T18:33:03Z", "succeededAt": "2026-11-16T18:33:15Z"}
        self.assertEqual(gate.rollout_evidence(staging_binding(delivery=d)), "rollout succeeded 2026-11-16T18:33:15Z")

    def test_cr_shape_stale_delivery_fails(self):
        # the live race: spec changed, delivery still describes the previous release's finished rollout
        d = {"rolloutId": "r.1", "startedAt": "2026-11-16T17:47:01Z", "succeededAt": "2026-11-16T17:47:51Z"}
        with self.assertRaisesRegex(gate.GateFailed, "started before the spec change"):
            gate.rollout_evidence(staging_binding(delivery=d))

    def test_cr_shape_rollout_in_progress_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, "not succeeded"):
            gate.rollout_evidence(staging_binding(delivery={"rolloutId": "r.2", "startedAt": "2026-11-16T18:33:03Z"}))


def read(path):
    with open(path) as f:
        return f.read()


def workload(project, component, repo):
    return {"spec": {"owner": {"projectName": project, "componentName": component}, "source": {"repository": repo}}}


class Repository(unittest.TestCase):
    def test_from_workload(self):
        wl = [workload("demo", "hello-world", "https://github.com/Sparky-stack/hello-world")]
        self.assertEqual(gate.workload_repository(wl, "demo", "hello-world", "Sparky-stack"), "Sparky-stack/hello-world")
        wl = [workload("demo", "hello-world", "https://github.com/Sparky-stack/hello-world.git")]
        self.assertEqual(gate.workload_repository(wl, "demo", "hello-world", "Sparky-stack"), "Sparky-stack/hello-world")

    def test_other_owner_rejected(self):
        wl = [workload("demo", "hello-world", "https://github.com/evil/hello-world")]
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository(wl, "demo", "hello-world", "Sparky-stack")

    def test_not_github_or_odd_url_rejected(self):
        for url in ("https://gitlab.com/koorikla/x", "git@github.com:Sparky-stack/x.git", "https://github.com/Sparky-stack/x/y",
                    "https://github.com/Sparky-stack/../x", "https://github.com/Sparky-stack/..", ""):
            with self.assertRaises(gate.GateFailed, msg=url):
                gate.workload_repository([workload("demo", "c", url)], "demo", "c", "Sparky-stack")

    def test_other_component_or_ambiguous_rejected(self):
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository([workload("other", "c", "https://github.com/Sparky-stack/x")], "demo", "c", "Sparky-stack")
        two = [workload("demo", "c", "https://github.com/Sparky-stack/x"), workload("demo", "c", "https://github.com/Sparky-stack/y")]
        with self.assertRaises(gate.GateFailed):
            gate.workload_repository(two, "demo", "c", "Sparky-stack")


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


SCOPE = {"namespace": "default", "project": "demo", "component": "hello-world", "environment": "staging"}
STAGING_NS = "dp-default-demo-staging-ba410b48"


def vector(*values, **labels):
    return [{"metric": dict(labels), "value": [1763400000.0, str(v)]} for v in values]


class FakePrometheus:
    """Stand-in for gate.promql: answers kube_pod_labels and the two envoy_cluster_upstream_rq sums."""

    def __init__(self, namespaces=(STAGING_NS,), total=(), failed=()):
        self.namespaces, self.total, self.failed, self.queries = namespaces, total, failed, []

    def __call__(self, query):
        self.queries.append(query)
        if query.startswith("max by (namespace)"):
            return [{"metric": {"namespace": n}, "value": [0, "1"]} for n in self.namespaces]
        if "envoy_response_code" in query:
            return vector(*self.failed)
        return vector(*self.total)


class ErrorRate(unittest.TestCase):
    def setUp(self):
        self.real = gate.promql
        self.logs = []
        self.real_log = gate.log
        gate.log = self.logs.append

    def tearDown(self):
        gate.promql = self.real
        gate.log = self.real_log

    def run_gate(self, prom, max_rate=0.05):
        gate.promql = prom
        return gate.observe_error_rate(SCOPE, 15, max_rate)

    def test_queries_match_the_kgateway_envoy_cluster_of_the_component_service(self):
        failed, total = gate.error_rate_queries([STAGING_NS], "hello-world", 15)
        self.assertEqual(total, 'sum(increase(envoy_cluster_upstream_rq{envoy_cluster_name=~'
                                '"kube_(dp-default-demo-staging-ba410b48)_hello-world_[0-9]+"}[15m]))')
        self.assertEqual(failed, 'sum(increase(envoy_cluster_upstream_rq{envoy_cluster_name=~'
                                 '"kube_(dp-default-demo-staging-ba410b48)_hello-world_[0-9]+",'
                                 'envoy_response_code=~"5.."}[15m]))')
        # PromQL regexes are fully anchored: the pattern is exactly this component's Service, not hello-world-api's
        pattern = re.search(r'=~"([^"]+)"', total).group(1)
        self.assertTrue(re.fullmatch(pattern, "kube_dp-default-demo-staging-ba410b48_hello-world_8080"))
        self.assertFalse(re.fullmatch(pattern, "kube_dp-default-demo-staging-ba410b48_hello-world-api_8080"))
        self.assertFalse(re.fullmatch(pattern, "kube_dp-default-demo-development-ad621210_hello-world_8080"))

    def test_namespace_lookup_is_scoped_to_org_project_component_environment(self):
        prom = FakePrometheus(total=(0,))
        self.run_gate(prom)
        self.assertEqual(prom.queries[0], 'max by (namespace) (max_over_time(kube_pod_labels{'
                                          'label_openchoreo_dev_namespace="default",label_openchoreo_dev_project="demo",'
                                          'label_openchoreo_dev_component="hello-world",'
                                          'label_openchoreo_dev_environment="staging"}[15m]))')

    def test_healthy(self):
        result = self.run_gate(FakePrometheus(total=(100.0,), failed=(2.0,)))
        self.assertEqual(result, "5xx rate 0.0200 (2 of 100 requests in 15m)")
        self.assertIn("(2 of 100 requests in 15m, %s)" % STAGING_NS, self.logs[-1])

    def test_counts_are_logged_as_request_counts_not_truncated_rates(self):
        self.run_gate(FakePrometheus(total=(51.7,), failed=(0.6,)), max_rate=0.5)
        self.assertIn("(1 of 52 requests", self.logs[-1])

    def test_over_threshold_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, r"5xx rate 0\.2400 \(24 of 100 requests in 15m\) above 0\.0500"):
            self.run_gate(FakePrometheus(total=(76.0, 24.0), failed=(24.0,)))

    def test_exactly_at_threshold_passes(self):
        self.assertIn("0.0500", self.run_gate(FakePrometheus(total=(100.0,), failed=(5.0,))))

    def test_no_traffic_is_reported_not_failed(self):
        for total in ((), (0.0,), (0.3,)):
            prom = FakePrometheus(total=total, failed=())
            self.assertEqual(self.run_gate(prom), "no traffic in 15m")
            self.assertFalse(any("envoy_response_code" in q for q in prom.queries))

    def test_no_5xx_series_is_zero_errors(self):
        self.assertEqual(self.run_gate(FakePrometheus(total=(40.0,), failed=())), "5xx rate 0.0000 (0 of 40 requests in 15m)")

    def test_environment_moved_between_namespaces_in_the_window_counts_both(self):
        prom = FakePrometheus(namespaces=("dp-a-1", "dp-b-2"), total=(10.0,))
        self.run_gate(prom)
        self.assertIn('"kube_(dp-a-1|dp-b-2)_hello-world_[0-9]+"', prom.queries[1])

    def test_no_pods_in_prometheus_fails(self):
        with self.assertRaisesRegex(gate.GateFailed, "no pods of demo/hello-world in staging"):
            self.run_gate(FakePrometheus(namespaces=(), total=(10.0,)))

    def test_non_dns_label_input_or_namespace_is_rejected(self):
        gate.promql = FakePrometheus(total=(1.0,))
        with self.assertRaisesRegex(gate.GateFailed, "not a DNS-1123 label"):
            gate.observe_error_rate(dict(SCOPE, component='x"}or vector(1)'), 15, 0.05)
        with self.assertRaisesRegex(gate.GateFailed, "bad namespace"):
            self.run_gate(FakePrometheus(namespaces=("a|.*",), total=(1.0,)))

    def test_promql_parses_the_api_envelope(self):
        real_http = gate.http
        calls = []
        os.environ["PROMETHEUS_URL"] = "http://prom:9091/"
        try:
            gate.http = lambda method, url, **kw: calls.append((method, url)) or {
                "status": "success", "data": {"resultType": "vector", "result": vector(3, 4)}}
            self.assertEqual(gate.scalar(self.real('sum(x{a="b"})')), 7.0)
            self.assertEqual(calls, [("GET", "http://prom:9091/api/v1/query?query=sum%28x%7Ba%3D%22b%22%7D%29")])
            gate.http = lambda method, url, **kw: {"status": "error", "error": "parse error"}
            with self.assertRaisesRegex(gate.GateFailed, "parse error"):
                self.real("bad(")
        finally:
            gate.http = real_http
            os.environ.pop("PROMETHEUS_URL", None)


def b64(text):
    return base64.b64encode(text.encode()).decode()


BINDING = "spec:\n  environment: production\n  releaseName: %s\n"


class FakeGitHub:
    """Stand-in for gate.gh: a repo with main pinning `main_release` and, optionally, an open gate PR."""

    def __init__(self, main_release="hello-world-old", pr_release=None):
        self.calls = []
        self.files = {"main": BINDING % main_release}
        self.pulls = []
        if pr_release:
            self.files["pr-head"] = BINDING % pr_release
            self.pulls = [{"number": 15, "head": {"sha": "pr-head"}, "html_url": "https://github.com/o/r/pull/15"}]

    def __call__(self, method, path, body=None, ok=(200, 201)):
        self.calls.append((method, path.split("?")[0], body))
        if method == "GET" and "/contents/" in path:
            return {"content": b64(self.files[path.split("ref=")[1]]), "sha": "blob"}
        if method == "GET" and "/pulls" in path:
            return self.pulls
        if method == "GET" and "/git/ref/heads/" in path:
            return {"object": {"sha": "main-head"}}
        if method == "POST" and path.endswith("/git/refs"):
            raise gate.GateFailed("Reference already exists")
        if method == "PATCH" and "/git/refs/heads/" in path:
            self.pulls = []                       # GitHub auto-closes the PR of a branch reset to its base
            return {}
        if method == "PUT":
            return {"commit": {"sha": "new-commit"}}
        if "/pulls" in path:
            number = int(path.rsplit("/", 1)[1]) if method == "PATCH" else 16
            return {"number": number, "html_url": "https://github.com/o/r/pull/%d" % number}
        return {}

    def writes(self):
        return [(m, p) for m, p, _ in self.calls if m != "GET"]


class Promote(unittest.TestCase):
    def setUp(self):
        self.real, self.real_log = gate.gh, gate.log
        gate.log = lambda msg: None
        os.environ.update(COMPONENT="hello-world", STATUS_CONTEXT="openchoreo/promotion-gate", SOURCE_ENV="staging")

    def tearDown(self):
        gate.gh, gate.log = self.real, self.real_log
        for k in ("COMPONENT", "STATUS_CONTEXT", "SOURCE_ENV"):
            os.environ.pop(k, None)

    def promote(self, fake, release="hello-world-new"):
        gate.gh = fake
        return gate.promote("o/r", "deploy/production.yaml", "production", release, ["ok"])

    def test_first_run_opens_a_pr_on_a_fresh_branch(self):
        fake = FakeGitHub()
        self.assertEqual(self.promote(fake), "https://github.com/o/r/pull/16")
        self.assertEqual(fake.writes(), [
            ("POST", "/repos/o/r/git/refs"), ("PATCH", "/repos/o/r/git/refs/heads/promote/hello-world-production"),
            ("PUT", "/repos/o/r/contents/deploy/production.yaml"), ("POST", "/repos/o/r/pulls"),
            ("POST", "/repos/o/r/statuses/new-commit")])

    def test_second_run_for_the_same_release_keeps_the_open_pr(self):
        # #155: a duplicate run reset the branch, GitHub closed the first PR and the gate opened another
        fake = FakeGitHub(pr_release="hello-world-new")
        self.assertEqual(self.promote(fake), "https://github.com/o/r/pull/15")
        self.assertEqual(fake.writes(), [("PATCH", "/repos/o/r/pulls/15"), ("POST", "/repos/o/r/statuses/pr-head")])
        self.assertEqual(fake.pulls[0]["number"], 15)   # still open

    def test_open_pr_for_another_release_is_replaced(self):
        fake = FakeGitHub(pr_release="hello-world-older")
        self.promote(fake)
        writes = fake.writes()
        self.assertIn(("PATCH", "/repos/o/r/git/refs/heads/promote/hello-world-production"), writes)
        self.assertIn(("POST", "/repos/o/r/pulls"), writes)          # new PR, not a PATCH of the closed one
        self.assertNotIn(("PATCH", "/repos/o/r/pulls/15"), writes)
        self.assertEqual(writes[-1], ("POST", "/repos/o/r/statuses/new-commit"))

    def test_release_already_on_main_is_a_no_op(self):
        fake = FakeGitHub(main_release="hello-world-new")
        self.assertIsNone(self.promote(fake))
        self.assertEqual(fake.writes(), [])


if __name__ == "__main__":
    unittest.main()
