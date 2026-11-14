#!/usr/bin/env python3
"""Mock-API smoke test for addons/harbor/files/harbor-config.py (stdlib only).

An in-memory fake of the Harbor v2.0 endpoints the reconciler uses. Runs the real script twice against the desired
state rendered by the chart (argv[2]) and checks: everything is created on the first run, the second run creates
nothing (idempotent), robot secrets are set from the environment, wrong admin credentials are refused, and no secret
value is ever printed. argv[1] = path of harbor-config.py. Exit 0 on success, prints FAIL lines otherwise.
"""
import base64
import json
import os
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADMIN_PW = "Adm1n-FAKE-pw"
SECRETS = {"ROBOT_BUILDER": "Bu1lder-FAKE-secret", "ROBOT_NODES": "N0des-FAKE-secret",
           "GHCR_TOKEN": "ghcr-FAKE-token"}


class Fake:
    def __init__(self):
        self.objs = {"registries": [], "projects": [], "replication/policies": [], "robots": []}
        self.next_id = 1
        self.calls = []
        self.robot_secrets = {}
        self.cve = None


FAKE = Fake()
ID_KEY = {"projects": "project_id"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=None):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        u = urllib.parse.urlsplit(self.path)
        path = u.path.removeprefix("/api/v2.0")
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length)) if length else None
        FAKE.calls.append((method, path))
        if path == "/health":  # unauthenticated, like Harbor's
            return self.reply(200, {"status": "healthy"})
        want = "Basic " + base64.b64encode(f"admin:{ADMIN_PW}".encode()).decode()
        if self.headers.get("Authorization") != want:
            return self.reply(401, {"errors": [{"code": "UNAUTHORIZED"}]})
        if path == "/system/CVEAllowlist" and method == "PUT":
            FAKE.cve = body
            return self.reply(200)
        for coll in FAKE.objs:
            if path == "/" + coll:
                if method == "GET":
                    q = urllib.parse.parse_qs(u.query).get("q", [""])[0]
                    key, _, val = q.partition("=")
                    return self.reply(200, [o for o in FAKE.objs[coll] if not q or o.get(key) == val])
                if method == "POST":
                    oid = FAKE.next_id
                    FAKE.next_id += 1
                    obj = dict(body)
                    obj[ID_KEY.get(coll, "id")] = oid
                    if coll == "projects":
                        obj["name"] = body["project_name"]
                    if coll == "robots":
                        obj["name"] = "robot$" + body["name"]
                    FAKE.objs[coll].append(obj)
                    return self.reply(201, {"id": oid, "name": obj["name"]} if coll == "robots" else None)
            if path.startswith("/" + coll + "/"):
                oid = int(path.rsplit("/", 1)[1])
                obj = next((o for o in FAKE.objs[coll] if o.get(ID_KEY.get(coll, "id")) == oid), None)
                if obj is None:
                    return self.reply(404)
                if method == "PATCH" and coll == "robots":
                    FAKE.robot_secrets[obj["name"]] = body["secret"]
                    return self.reply(200)
                if method == "PUT":
                    obj.update({k: v for k, v in body.items() if k != "name" or coll != "robots"})
                    return self.reply(200)
        return self.reply(404, {"errors": [{"code": "NOT_FOUND", "message": f"{method} {path}"}]})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_PATCH(self):
        self.handle_any("PATCH")


def run(script, state, pw=ADMIN_PW):
    env = {"PATH": os.environ.get("PATH", "/usr/bin"), "HARBOR_URL": f"http://127.0.0.1:{PORT}",
           "HARBOR_ADMIN_PASSWORD": pw, "GHCR_USERNAME": "ghcr-user", **SECRETS}
    return subprocess.run([sys.executable, script, state], env=env, capture_output=True, text=True, timeout=120)


failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


if __name__ == "__main__":
    script, state_file = sys.argv[1], sys.argv[2]
    state = json.load(open(state_file, encoding="utf-8"))
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    PORT = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    r1 = run(script, state_file)
    out1 = r1.stdout + r1.stderr
    check(r1.returncode == 0, f"first run succeeds (rc={r1.returncode}: {out1[-300:]!r})")
    names = lambda c: sorted(o["name"] for o in FAKE.objs[c])
    check(names("projects") == sorted(p["name"] for p in state.get("projects", [])), "every project created")
    check(names("registries") == sorted(r["name"] for r in state.get("registries", [])), "every registry created")
    check(names("replication/policies") == sorted(r["name"] for r in state.get("replication", [])),
          "every replication policy created")
    check(names("robots") == sorted("robot$" + r["name"] for r in state.get("robots", [])), "every robot created")
    for r in state.get("robots", []):
        check(FAKE.robot_secrets.get("robot$" + r["name"]) == SECRETS.get(r["secretEnv"]),
              f"robot {r['name']}: secret set from {r['secretEnv']}")
    ghcr = [o for o in FAKE.objs["registries"] if (o.get("credential") or {}).get("access_secret")]
    check(all(o["credential"]["access_secret"] == SECRETS["GHCR_TOKEN"] for o in ghcr) and bool(ghcr) ==
          any(r.get("credentials") for r in state.get("registries", [])), "GHCR credential from GHCR_TOKEN")
    check(FAKE.cve == {"items": [{"cve_id": c} for c in state.get("cveAllowlist", [])]}, "system CVE allowlist applied")
    for proj in state.get("projects", []):
        if proj.get("registry"):
            obj = next(o for o in FAKE.objs["projects"] if o["name"] == proj["name"])
            reg = next(o for o in FAKE.objs["registries"] if o["name"] == proj["registry"])
            check(obj.get("registry_id") == reg["id"], f"proxy-cache project {proj['name']} -> registry {reg['name']}")

    n_objs = {c: len(v) for c, v in FAKE.objs.items()}
    FAKE.calls.clear()
    r2 = run(script, state_file)
    out2 = r2.stdout + r2.stderr
    check(r2.returncode == 0, "second run succeeds")
    check({c: len(v) for c, v in FAKE.objs.items()} == n_objs, "second run is idempotent (no duplicates)")
    check(not any(m == "POST" for m, _ in FAKE.calls), "second run creates nothing")
    check("created" not in r2.stdout, "second run reports no creation")

    r3 = run(script, state_file, pw="wrong")
    check(r3.returncode != 0 and "HTTP 401" in r3.stderr, "wrong admin password fails with the API's 401")

    leaked = [s for s in list(SECRETS.values()) + [ADMIN_PW] if s in out1 + out2 + r3.stdout + r3.stderr]
    check(not leaked, "no secret value in the script's output")
    srv.shutdown()
    print(f"  {len(failures)} failed")
    sys.exit(1 if failures else 0)
