#!/usr/bin/env python3
"""OpenChoreo types of addon openchoreo-platform vs the data planes (#70, hack/tests/test_openchoreo_types.sh).

Usage: openchoreo_types.py <platform-render.jsonl> <data-plane-render.jsonl> <agent ns/sa> <catalog.json>
Inputs are JSON documents, one per line (yq -o=json -I=0). Prints one `VIOLATION: ...` line per broken invariant and
`OK <what>` lines for the checks that passed; exit code 0 either way.

Invariants:
  - every kind a ClusterComponentType / ClusterTrait / ClusterResourceType renders onto the DATA plane is granted to the
    data-plane cluster agent (get, list, create, patch: server-side apply + RenderedRelease status) by a ClusterRole bound
    to its ServiceAccount
  - platform.koorikla.io/requires-addons names catalog addons that run on workload clusters and are opt-in (default
    false): only then can a data plane lack them
  - a ClusterTrait with requirements checks each one (dataplane.annotations["addons.platform.koorikla.io/<addon>"] ==
    "true") in a preRenderValidation
  - no type renders a raw CloudNativePG object (tenants get PostgreSQL only through the platform XR)
"""
import json
import sys

plat_path, dp_path, agent, catalog_path = sys.argv[1:5]
ns, sa = agent.split("/", 1)


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip() and line.strip() != "null"]


plat, dp = load(plat_path), load(dp_path)
catalog = json.load(open(catalog_path))
out = []

# --- what the agent may do on the data plane ----------------------------------------------------------------------
roles = {d["metadata"]["name"]: d for d in dp if d.get("kind") == "ClusterRole"}
grants = {}  # (group, resource) -> verbs
for b in dp:
    if b.get("kind") != "ClusterRoleBinding":
        continue
    if not any(s.get("kind") == "ServiceAccount" and s.get("name") == sa and s.get("namespace") == ns
               for s in b.get("subjects") or []):
        continue
    role = roles.get(b["roleRef"]["name"])
    if role is None:
        continue
    for r in role.get("rules") or []:
        for g in r.get("apiGroups") or []:
            for res in r.get("resources") or []:
                grants.setdefault((g, res), set()).update(r.get("verbs") or [])

NEEDED = {"get", "list", "create", "patch"}


def plural(kind):
    k = kind.lower()
    if k.endswith("y"):
        return k[:-1] + "ies"
    if k.endswith("s"):
        return k + "es"
    return k + "s"


def templates(obj):
    """(id, plane, apiVersion, kind) of every manifest template a type renders."""
    spec = obj.get("spec") or {}
    if obj["kind"] == "ClusterTrait":
        for c in spec.get("creates") or []:
            t = c.get("template") or {}
            yield c.get("targetPlane", "dataplane"), t.get("apiVersion", ""), t.get("kind", "")
    else:
        for r in spec.get("resources") or []:
            t = r.get("template") or {}
            yield "dataplane", t.get("apiVersion", ""), t.get("kind", "")


types = [d for d in plat if d.get("kind") in ("ClusterComponentType", "ClusterTrait", "ClusterResourceType")]
for obj in types:
    name = f'{obj["kind"]} {obj["metadata"]["name"]}'
    for plane, api, kind in templates(obj):
        group = api.split("/")[0] if "/" in api else ""
        if group in ("postgresql.cnpg.io", "barmancloud.cnpg.io"):
            out.append(f"VIOLATION: {name} renders raw {kind} ({api}); use the platform.koorikla.io PostgreSQL XR")
        if plane != "dataplane":
            continue
        verbs = grants.get((group, plural(kind)), set()) | grants.get((group, "*"), set())
        if "*" not in verbs and not NEEDED <= verbs:
            out.append(f"VIOLATION: {name} renders {kind} ({api}) but the data-plane agent {ns}/{sa} lacks "
                       f"{sorted(NEEDED - verbs)} on {group or 'core'}/{plural(kind)}")
        else:
            out.append(f"OK agent may apply {group or 'core'}/{plural(kind)} for {name}")

# --- requirements: real opt-in workload addons, checked by traits ----------------------------------------------------
for obj in types:
    name = f'{obj["kind"]} {obj["metadata"]["name"]}'
    raw = ((obj["metadata"].get("annotations") or {}).get("platform.koorikla.io/requires-addons") or "")
    req = [a.strip() for a in raw.split(",") if a.strip()]
    for a in req:
        entry = catalog.get(a)
        if entry is None:
            out.append(f"VIOLATION: {name} requires addon {a}, which is not in the catalog")
            continue
        if "workload" not in (entry.get("roles") or []):
            out.append(f"VIOLATION: {name} requires addon {a}, which never runs on workload clusters")
        if entry.get("default") is not False:
            out.append(f"VIOLATION: {name} requires addon {a}, which is on by default (no annotation to check)")
        out.append(f"OK {name} requires opt-in workload addon {a}")
        if obj["kind"] == "ClusterTrait":
            key = f"addons.platform.koorikla.io/{a}"
            rules = [v.get("rule", "") for v in (obj["spec"].get("preRenderValidations") or [])]
            want = f'dataplane.annotations["{key}"] == "true"'
            if not any(want in r and f'"{key}" in dataplane.annotations' in r for r in rules):
                out.append(f"VIOLATION: {name} requires {a} but no preRenderValidation checks {want}")
            else:
                out.append(f"OK {name} checks {key}")

# --- capability gate (#246): the agent starts only after the CRDs of every kind a trait's required addon brings -------
# argv[5]: the data-plane render with every capabilityGate addon enabled. Without the gate OpenChoreo applies the kind
# before the addon exists and 1.3.3 retries only on its capped exponential backoff (~17 min on a fresh bootstrap).
if len(sys.argv) > 5:
    gated = load(sys.argv[5])
    jobs = [d for d in gated if d.get("kind") == "Job" and d["metadata"]["name"] == "capability-gate"]
    gate, wave = set(), None
    for j in jobs:
        ann = j["metadata"].get("annotations") or {}
        wave = int(ann.get("argocd.argoproj.io/sync-wave", "0")) if ann.get("argocd.argoproj.io/hook") == "Sync" else None
        pod = j["spec"]["template"]["spec"]
        for c in (pod.get("initContainers") or []) + (pod.get("containers") or []):
            gate.update(a[len("crd/"):] for a in c.get("command") or [] if a.startswith("crd/"))
    if wave is None or wave >= 0:
        out.append("VIOLATION: no capability-gate Sync hook before the agent Deployment (sync wave < 0)")
    for obj in types:
        if obj["kind"] != "ClusterTrait":
            continue
        name = f'ClusterTrait {obj["metadata"]["name"]}'
        if not (obj["metadata"].get("annotations") or {}).get("platform.koorikla.io/requires-addons"):
            continue
        for plane, api, kind in templates(obj):
            group = api.split("/")[0] if "/" in api else ""
            if plane != "dataplane" or "." not in group or group.endswith(".k8s.io"):
                continue  # built-in kinds exist on every cluster
            crd = f"{plural(kind)}.{group}"
            if crd in gate:
                out.append(f"OK agent waits for crd/{crd} of {name}")
            else:
                out.append(f"VIOLATION: {name} renders {kind} ({api}) but the capability gate does not wait for crd/{crd}")

print("\n".join(out))
