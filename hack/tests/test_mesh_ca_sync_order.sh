#!/usr/bin/env bash
# Sync order of the mesh CA addons (openbao on mgmt, addon mesh istio-csr part on members) under Argo CD's rules (gitops-engine sync_context.go): resources run in steps ordered by
# (phase PreSync < Sync < PostSync, sync-wave). Between steps Argo waits for every resource of the step to be Healthy and
# FAILS the sync if one is Degraded; a step holding a hook waits for the hook; only the final step, when it holds no
# hook, succeeds even if its resources degrade later. PostSync therefore needs every resource Healthy.
# The group roots (pki-mesh-<g>-root) exist only after the mesh-reconcile Job (bootstrap identity) ran, so every
# resource that reads them must come in a later step, or a clean bootstrap deadlocks. That happened live after #4: the
# Job was a PostSync hook, ExternalSecret openbao-ca-bundle (wave 0) stayed Degraded, PostSync never ran.
# The model replays a fresh install and a re-sync of the rendered chart; negative cases replay the #4 layout.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"
echo "== test_mesh_ca_sync_order =="
pick_python || { echo "  SKIP: python3 not found"; exit 0; }
cd "$ROOT"

helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  > "$TMP/openbao.yaml"
to_json() { yq -o=json -I=0 'select(. != null)' "$1" > "$2"; }
to_json "$TMP/openbao.yaml" "$TMP/openbao.json"

cat > "$TMP/model.py" <<'EOF'
import json, sys
PHASES = {"PreSync": 0, "Sync": 1, "PostSync": 2}
docs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
def ann(d): return (d.get("metadata") or {}).get("annotations") or {}
def hook(d):
    h = ann(d).get("argocd.argoproj.io/hook")
    return h.split(",")[0].strip() if h else None
def step(d):
    return (PHASES.get(hook(d) or "Sync", 1), int(ann(d).get("argocd.argoproj.io/sync-wave", "0")))
def name(d): return d["kind"] + "/" + d["metadata"]["name"]
def env(d):
    spec = d.get("spec", {})
    pod = spec.get("template", {}).get("spec") or spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
    return {e["name"] for c in pod.get("containers", []) for e in c.get("env", [])}
def is_creator(d): return d["kind"] == "Job" and "BOOTSTRAP_LOGIN_ROLE" in env(d)
# Healthy only once the group roots exist: whatever reads pki-mesh-*-root (ESO store + ExternalSecret) and the
# CronJob (its runs fail without an intermediate CA; it may also degrade later, e.g. every member down).
def needs_roots(d):
    s = json.dumps(d.get("spec", {}))
    if d["kind"] in ("ExternalSecret", "SecretStore") and ("pki-mesh-" in s or "openbao-pki-public" in s
                                                          or "mesh-ca-read" in s):
        return True
    return d["kind"] == "CronJob" and "LOGIN_ROLE" in env(d)
def degrades_later(d): return d["kind"] == "CronJob"
out = []
creators = [d for d in docs if is_creator(d)]
if len(creators) != 1:
    print("FAIL exactly one group-CA bootstrap Job (found %d)" % len(creators)); sys.exit(0)
c = creators[0]
if hook(c) is None:
    out.append("FAIL bootstrap Job is not an Argo hook (a plain Job is immutable: re-syncs fail)")
elif hook(c) != "Sync":
    out.append("FAIL bootstrap Job is a %s hook, must be a Sync hook" % hook(c))
steps = sorted({step(d) for d in docs})
final = steps[-1]
for resync in (False, True):     # fresh install: no roots yet; re-sync: roots from an earlier run
    roots, label = resync, "re-sync" if resync else "fresh install"
    for st in steps:
        here = [d for d in docs if step(d) == st]
        if any(is_creator(d) for d in here):
            roots = True         # the Job runs, and is awaited, within its step
        has_hook = any(hook(d) for d in here)
        blocked = [name(d) for d in here if not hook(d) and needs_roots(d) and not roots]
        if blocked and (st != final or has_hook):
            out.append("FAIL %s: deadlock in step phase=%d wave=%d: %s Degraded until the bootstrap Job (phase=%d wave=%d) ran"
                       % (label, st[0], st[1], ",".join(blocked), *step(c)))
            break
    else:
        out.append("ok %s converges" % label)
for d in docs:
    if needs_roots(d) and step(d) <= step(c):
        out.append("FAIL %s (phase=%d wave=%d) is not after the bootstrap Job" % (name(d), *step(d)))
    if degrades_later(d) and (step(d) != final or any(hook(x) for x in docs if step(x) == final)):
        out.append("FAIL %s may degrade at runtime: must be in the final step, which holds no hook" % name(d))
print("\n".join(out))
EOF
model() { py "$TMP/model.py" "$1"; }

res=$(model "$TMP/openbao.json")
assert_eq "$(printf '%s\n' "$res" | grep '^FAIL' || true)" "" "openbao sync order: no deadlock, consumers after the bootstrap Job"
assert_match "$res" 'ok fresh install converges' "fresh install (no group roots yet) converges"
assert_match "$res" 'ok re-sync converges' "re-sync converges"
assert_eq "$(yq 'select(.kind == "Job") | .metadata.annotations["argocd.argoproj.io/hook-delete-policy"]' "$TMP/openbao.yaml")" \
  BeforeHookCreation "bootstrap Job is recreated on every sync"

# Negative: the layout merged in #4 (Job PostSync, no waves) deadlocks on a fresh install.
yq 'del(.metadata.annotations["argocd.argoproj.io/sync-wave"]) | (select(.kind == "Job") | .metadata.annotations["argocd.argoproj.io/hook"]) = "PostSync"' \
  "$TMP/openbao.yaml" > "$TMP/pr4.yaml"
to_json "$TMP/pr4.yaml" "$TMP/pr4.json"
res=$(model "$TMP/pr4.json")
assert_match "$res" 'FAIL bootstrap Job is a PostSync hook' "negative: a PostSync bootstrap Job is caught"
assert_match "$res" 'FAIL fresh install: deadlock .*ExternalSecret/openbao-ca-bundle' "negative: #4 layout deadlocks on openbao-ca-bundle"
# Negative: the bundle in the Job's wave (it is Degraded while the Job runs and fails the sync).
yq '(select(.kind == "ExternalSecret" and .metadata.name == "openbao-ca-bundle") | .metadata.annotations["argocd.argoproj.io/sync-wave"]) = "1"' \
  "$TMP/openbao.yaml" > "$TMP/same-wave.yaml"
to_json "$TMP/same-wave.yaml" "$TMP/same-wave.json"
assert_match "$(model "$TMP/same-wave.json")" 'ExternalSecret/openbao-ca-bundle .* is not after the bootstrap Job' \
  "negative: openbao-ca-bundle in the Job's wave is caught"
# Negative: the CronJob in an earlier wave than the final one blocks every later sync while it is Degraded.
yq '(select(.kind == "CronJob") | .metadata.annotations["argocd.argoproj.io/sync-wave"]) = "0"' \
  "$TMP/openbao.yaml" > "$TMP/cron0.yaml"
to_json "$TMP/cron0.yaml" "$TMP/cron0.json"
assert_match "$(model "$TMP/cron0.json")" 'FAIL fresh install: deadlock .*CronJob/mesh-reconcile' \
  "negative: CronJob before the bootstrap Job is caught"

# --- addon mesh, istio-csr part (members) -----------------------------------------------------------------------------------
# Issuer openbao-mesh: cert-manager's Ready check builds the Vault client, i.e. mints a token for ServiceAccount
# istio-csr-openbao (TokenRequest, allowed by Role/RoleBinding <sa>-tokenrequest) and logs in. Live after #4 the Issuer
# was in wave -1 and those in wave 0: the Issuer could never turn Ready, the sync failed, wave 0 was never applied.
helm template mesh addons/mesh --namespace istio-system --values addons/mesh/values/mesh-member.yaml \
  --values installations/local/installation.yaml --set cluster.name=dev1 --set mesh.group=local > "$TMP/istio-csr.yaml"
cat > "$TMP/issuer.py" <<'EOF'
import json, sys
docs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
wave = lambda d: int(((d.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))
iss = [d for d in docs if d["kind"] == "Issuer" and "vault" in d.get("spec", {})]
if len(iss) != 1:
    print("FAIL exactly one Vault Issuer (found %d)" % len(iss)); sys.exit(0)
i = iss[0]; sa = i["spec"]["vault"]["auth"]["kubernetes"]["serviceAccountRef"]["name"]
roles = [d["metadata"]["name"] for d in docs if d["kind"] == "Role" and any(sa in r.get("resourceNames", []) for r in d.get("rules", []))]
need = [d for d in docs if (d["kind"] == "ServiceAccount" and d["metadata"]["name"] == sa)
        or (d["kind"] == "Role" and d["metadata"]["name"] in roles)
        or (d["kind"] == "RoleBinding" and d["roleRef"]["name"] in roles)
        or d["kind"].startswith("ValidatingAdmissionPolicy")]
kinds = sorted({d["kind"] for d in need})
if kinds != ["Role", "RoleBinding", "ServiceAccount", "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"]:
    print("FAIL prerequisites not found: %s" % kinds)
for d in need:
    if wave(d) >= wave(i):
        print("FAIL %s/%s (wave %d) is not before Issuer %s (wave %d)" % (d["kind"], d["metadata"]["name"], wave(d), i["metadata"]["name"], wave(i)))
print("ok")
EOF
to_json "$TMP/istio-csr.yaml" "$TMP/istio-csr.json"
res=$(py "$TMP/issuer.py" "$TMP/istio-csr.json")
assert_eq "$res" ok "istio-csr: token ServiceAccount, its RBAC and the admission policies sync before the Vault Issuer"
yq 'del(.metadata.annotations["argocd.argoproj.io/sync-wave"]) | (select(.kind == "Issuer") | .metadata.annotations["argocd.argoproj.io/sync-wave"]) = "-1"' \
  "$TMP/istio-csr.yaml" > "$TMP/istio-csr-pr4.yaml"
to_json "$TMP/istio-csr-pr4.yaml" "$TMP/istio-csr-pr4.json"
assert_match "$(py "$TMP/issuer.py" "$TMP/istio-csr-pr4.json")" 'FAIL ServiceAccount/istio-csr-openbao \(wave 0\) is not before Issuer' \
  "negative: the #4 layout (Issuer -1, its ServiceAccount 0) is caught"


# One app now holds istio-csr and the ambient mesh: Issuer (-1) < istio-csr + istiod (0) < ztunnel (1, after istiod).
w() { yq "select(.kind == \"$1\" and .metadata.name == \"$2\") | .metadata.annotations[\"argocd.argoproj.io/sync-wave\"] // \"0\"" "$TMP/istio-csr.yaml"; }
assert_eq "$(w Issuer openbao-mesh) $(w Deployment cert-manager-istio-csr) $(w Deployment istiod) $(w DaemonSet ztunnel)" "-1 0 0 1" \
  "mesh: Vault Issuer, then istio-csr + istiod, then ztunnel"
finish
