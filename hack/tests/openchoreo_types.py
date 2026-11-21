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
  - platform.koorikla.io/uses-addons names DEFAULT-ON workload addons whose kinds a ClusterTrait renders (#252, metrics ->
    PodMonitor of addon telemetry); a fleet file can still opt out, so each such create is skipped (includeWhen) where
    dataplane.annotations["addons.platform.koorikla.io/<addon>"] == "false"
  - capability gate: every non-built-in kind a ClusterTrait / ClusterResourceType renders is waited for under one of its
    required or used addons (a type naming no addon for such a kind is reported)
"""
import json
import re
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

def addon_list(obj, key):
    raw = (obj["metadata"].get("annotations") or {}).get(key) or ""
    return [a.strip() for a in raw.split(",") if a.strip()]


def builtin(api):
    group = api.split("/")[0] if "/" in api else ""
    return "." not in group or group.endswith(".k8s.io") or group == "openchoreo.dev"


# --- uses: default-on workload addons (#252); the trait skips their kinds where a data plane opts out ---------------
for obj in types:
    name = f'{obj["kind"]} {obj["metadata"]["name"]}'
    for a in addon_list(obj, "platform.koorikla.io/uses-addons"):
        entry = catalog.get(a)
        if entry is None or "workload" not in (entry.get("roles") or []):
            out.append(f"VIOLATION: {name} uses addon {a}, which is not a workload addon of the catalog")
            continue
        if entry.get("default") is False:
            out.append(f"VIOLATION: {name} uses addon {a}, which is opt-in: name it in platform.koorikla.io/requires-addons")
        want = f'dataplane.annotations["addons.platform.koorikla.io/{a}"] == "false"'
        for c in (obj["spec"].get("creates") or []) if obj["kind"] == "ClusterTrait" else []:
            t = c.get("template") or {}
            if builtin(t.get("apiVersion", "")):
                continue
            if want in (c.get("includeWhen") or ""):
                out.append(f"OK {name} skips its {t.get('kind')} where a data plane opts out of {a}")
            else:
                out.append(f"VIOLATION: {name} renders {t.get('kind')} of default-on addon {a} without includeWhen {want}")

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

# --- capability gate (#246, #255): the agent starts only after the CRDs of every kind a trait or resource type's -----
# required addon brings. argv[5]: the data-plane render with every capabilityGate addon enabled. Without the gate
# OpenChoreo applies the kind before the addon exists and 1.3.3 retries only on its capped exponential backoff (~17 min
# for KEDA, ~30 min for the PostgreSQL XRD on a fresh bootstrap). Per addon: init container wait-for-<addon>-crds waits
# for the CRD, the main container waits for Established, and charts/platform turns the wait on from the cluster label
# addons.platform.koorikla.io/<addon> (the same fact the trait/resource type checks).
if len(sys.argv) > 5:
    gated = load(sys.argv[5])
    jobs = [d for d in gated if d.get("kind") == "Job" and d["metadata"]["name"] == "capability-gate"]
    created, established, wave = {}, set(), None
    for j in jobs:
        ann = j["metadata"].get("annotations") or {}
        wave = int(ann.get("argocd.argoproj.io/sync-wave", "0")) if ann.get("argocd.argoproj.io/hook") == "Sync" else None
        pod = j["spec"]["template"]["spec"]
        for c in pod.get("initContainers") or []:
            m = re.fullmatch(r"wait-for-(.+)-crds", c.get("name", ""))
            if m:
                created.setdefault(m.group(1), set()).update(
                    a[len("crd/"):] for a in c.get("command") or [] if a.startswith("crd/"))
        for c in pod.get("containers") or []:
            if "--for=condition=Established" in (c.get("command") or []):
                established.update(a[len("crd/"):] for a in c["command"] if a.startswith("crd/"))
    if wave is None or wave >= 0:
        out.append("VIOLATION: no capability-gate Sync hook before the agent Deployment (sync wave < 0)")
    labels = (catalog.get("openchoreo-data-plane") or {}).get("clusterLabelParameters") or {}
    for obj in types:
        name = f'{obj["kind"]} {obj["metadata"]["name"]}'
        uses = addon_list(obj, "platform.koorikla.io/uses-addons")
        req = addon_list(obj, "platform.koorikla.io/requires-addons") + uses
        if obj["kind"] == "ClusterComponentType":
            continue
        for plane, api, kind in templates(obj):
            if plane != "dataplane" or builtin(api):
                continue  # built-in kinds exist on every cluster
            group = api.split("/")[0]
            crd = f"{plural(kind)}.{group}"
            if not req:
                out.append(f"VIOLATION: {name} renders {kind} ({api}) but names no addon (requires-addons or "
                           f"uses-addons) whose capability gate waits for crd/{crd}")
                continue
            by = [a for a in req if crd in created.get(a, set())]
            if not by or crd not in established:
                out.append(f"VIOLATION: {name} renders {kind} ({api}) but the capability gate does not wait for "
                           f"crd/{crd} under a required addon ({', '.join(req)})")
                continue
            for a in by:
                lp = labels.get(f"capabilityGate.addons.{a}.enabled") or {}
                if lp.get("label") != f"addons.platform.koorikla.io/{a}":
                    out.append(f"VIOLATION: {name} needs the {a} gate but charts/platform does not enable "
                               f"capabilityGate.addons.{a}.enabled from label addons.platform.koorikla.io/{a}")
                elif a in uses and lp.get("default") != "true":
                    out.append(f"VIOLATION: {name} uses default-on addon {a} but its gate label parameter does not "
                               f"default to \"true\" (clusters without the label run {a})")
                else:
                    out.append(f"OK agent waits for crd/{crd} of {name} (addon {a})")

print("\n".join(out))
