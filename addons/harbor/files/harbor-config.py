#!/usr/bin/env python3
"""Apply a desired state to Harbor through its v2.0 API, idempotently (stdlib only).

Harbor has no Kubernetes CRDs, so addons/harbor runs this script as an Argo CD PostSync hook Job and as a CronJob.
Desired state: JSON file (argv[1], rendered from addons/harbor/values.yaml `config`):

  {"registries":  [{"name", "type", "url", "credentials": null | "ghcr"}],
   "projects":    [{"name", "public", "registry": null | <registry name>, "metadata": {...}, "storageLimit"}],
   "replication": [{"name", "enabled", "registry", "destProject", "filters": [{"type","value"}], "cron"}],
   "robots":      [{"name", "description", "secretEnv", "permissions": [{"project", "access": [[res, act], ...]}]}],
   "cveAllowlist": []}

Env: HARBOR_URL (core, e.g. http://harbor-core), HARBOR_ADMIN_PASSWORD, GHCR_USERNAME/GHCR_TOKEN, and one env per
robot (secretEnv). Secrets never reach stdout. Creates what is missing and updates what drifted; never deletes
(removing an entry from values leaves the object in Harbor - delete it in the UI if intended).
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("HARBOR_URL", "http://harbor-core").rstrip("/") + "/api/v2.0"
AUTH = "Basic " + base64.b64encode(("admin:" + os.environ["HARBOR_ADMIN_PASSWORD"]).encode()).decode()


class HarborError(Exception):
    pass


def call(method, path, body=None, ok=(200, 201, 204)):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", AUTH)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        raw, status = e.read(), e.code
    if status not in ok:
        raise HarborError(f"{method} {path}: HTTP {status}: {raw[:300].decode(errors='replace')}")
    return json.loads(raw) if raw else None


def find(path, name, key="name"):
    """GET a list filtered with Harbor's q=name=<exact> and return the exact match (or None)."""
    q = urllib.parse.quote(f"{key}={name}")
    for item in call("GET", f"{path}?q={q}&page_size=100") or []:
        if item.get(key) == name:
            return item
    return None


def wait_ready(timeout=600):
    deadline = time.time() + timeout
    while True:
        try:
            if (call("GET", "/health") or {}).get("status") == "healthy":
                return
        except Exception as e:  # noqa: BLE001 - connection refused while core starts
            last = e
        else:
            last = "unhealthy"
        if time.time() > deadline:
            raise HarborError(f"Harbor not healthy after {timeout}s: {last}")
        time.sleep(5)


def credential(kind):
    if not kind:
        return None
    if kind == "ghcr":
        user, token = os.environ.get("GHCR_USERNAME", ""), os.environ.get("GHCR_TOKEN", "")
        if not (user and token):
            return None   # no secrets.ghcrKey: anonymous GHCR (public packages); replication needs a token
        return {"type": "basic", "access_key": user, "access_secret": token}
    raise HarborError(f"unknown credentials kind {kind}")


def ensure_registry(r):
    body = {"name": r["name"], "type": r["type"], "url": r["url"], "insecure": False, "description": "platform"}
    cred = credential(r.get("credentials"))
    if cred:
        body["credential"] = cred
    cur = find("/registries", r["name"])
    if cur is None:
        call("POST", "/registries", body)
        print(f"registry {r['name']}: created")
        cur = find("/registries", r["name"])
        if cur is None:
            raise HarborError(f"registry {r['name']}: not found after create")
    elif cur.get("type") != r["type"]:
        # Harbor keeps the adapter type on PUT; a registry's type can only change by re-creating it. Projects that
        # reference it make DELETE fail (HTTP 412), which is the safe outcome: fix the project first.
        call("DELETE", f"/registries/{cur['id']}")
        call("POST", "/registries", body)
        print(f"registry {r['name']}: re-created as {r['type']}")
        cur = find("/registries", r["name"])
        if cur is None:
            raise HarborError(f"registry {r['name']}: not found after re-create")
    else:
        drift = cur.get("url") != r["url"] or cred is not None
        if drift:
            call("PUT", f"/registries/{cur['id']}", body)  # credentials cannot be read back: always re-sent
            print(f"registry {r['name']}: updated")
    return cur["id"]


def ensure_project(p, registry_ids):
    meta = {k: str(v).lower() for k, v in p.get("metadata", {}).items()}
    meta["public"] = "true" if p.get("public") else "false"
    cur = find("/projects", p["name"])
    if cur is None:
        body = {"project_name": p["name"], "metadata": meta, "storage_limit": p.get("storageLimit", -1)}
        if p.get("registry"):
            body["registry_id"] = registry_ids[p["registry"]]
        call("POST", "/projects", body)
        print(f"project {p['name']}: created")
        return
    have = cur.get("metadata") or {}
    if any(have.get(k) != v for k, v in meta.items()):
        call("PUT", f"/projects/{cur['project_id']}", {"metadata": meta})
        print(f"project {p['name']}: metadata updated")


def ensure_replication(r, registry_ids):
    body = {
        "name": r["name"],
        "enabled": bool(r.get("enabled", True)),
        "src_registry": {"id": registry_ids[r["registry"]]},
        "dest_namespace": r["destProject"],
        "dest_namespace_replace_count": 1,
        "filters": r.get("filters", []),
        "trigger": {"type": "scheduled", "trigger_settings": {"cron": r["cron"]}},
        "override": True,
        "speed": -1,
        "copy_by_chunk": False,
    }
    cur = find("/replication/policies", r["name"])
    if cur is None:
        call("POST", "/replication/policies", body)
        print(f"replication {r['name']}: created")
    else:
        call("PUT", f"/replication/policies/{cur['id']}", body)
        print(f"replication {r['name']}: applied")


def robot_permissions(perms):
    return [
        {"kind": "project", "namespace": p["project"],
         "access": [{"resource": res, "action": act} for res, act in p["access"]]}
        for p in perms
    ]


def ensure_robot(r):
    secret = os.environ.get(r["secretEnv"], "")
    if len(secret) < 8:
        raise HarborError(f"robot {r['name']}: secret env {r['secretEnv']} missing or shorter than 8 chars")
    body = {"name": r["name"], "description": r.get("description", ""), "level": "system", "duration": -1,
            "disable": False, "permissions": robot_permissions(r["permissions"])}
    full = "robot$" + r["name"]  # default robot_name_prefix
    # Harbor's q=name= filter does not match robot names reliably ("$" prefix, level); scan the system robots instead.
    cur = next((x for x in (call("GET", "/robots?page_size=100") or []) if x.get("name") in (full, r["name"])), None)
    if cur is None:
        created = call("POST", "/robots", body) or {}
        rid = created.get("id") or next((x["id"] for x in (call("GET", "/robots?page_size=100") or [])
                                         if x.get("name") in (full, r["name"])), None)
        if rid is None:
            raise HarborError(f"robot {full}: not found after create")
        print(f"robot {full}: created")
    else:
        rid = cur["id"]
        body["name"] = cur["name"]
        call("PUT", f"/robots/{rid}", body)
        print(f"robot {full}: permissions applied")
    # Set the secret from the backend (Harbor otherwise generates one we could not distribute declaratively).
    call("PATCH", f"/robots/{rid}", {"secret": secret})


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        state = json.load(f)
    wait_ready()
    call("PUT", "/system/CVEAllowlist", {"items": [{"cve_id": c} for c in state.get("cveAllowlist", [])]})
    print(f"system CVE allowlist: {len(state.get('cveAllowlist', []))} entries")
    registry_ids = {r["name"]: ensure_registry(r) for r in state.get("registries", [])}
    for p in state.get("projects", []):
        ensure_project(p, registry_ids)
    cred_kind = {r["name"]: r.get("credentials") for r in state.get("registries", [])}
    for r in state.get("replication", []):
        if cred_kind.get(r["registry"]) and credential(cred_kind[r["registry"]]) is None:
            r = {**r, "enabled": False}   # e.g. GHCR listing needs a token; anonymous proxy cache still works
            print(f"replication {r['name']}: no credentials, applied disabled")
        ensure_replication(r, registry_ids)
    for r in state.get("robots", []):
        ensure_robot(r)
    print("harbor desired state applied")


if __name__ == "__main__":
    try:
        main()
    except HarborError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
