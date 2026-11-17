#!/usr/bin/env bash
# Kyverno CLI tests of rendered admission policies:
#   addons/openchoreo-platform ValidatingAdmissionPolicy openchoreo-gated-bindings-from-git (offline): production
#                              bindings from the component's gated Argo CD Application pass; from openchoreo-api, from
#                              the app's main Application, another tenant's Application, another app's gated
#                              Application (either direction) or without tracking-id are denied; staging is out of scope
#   addons/argo-events          ValidatingAdmissionPolicy argo-events-workflows-falco-response-only (offline): the
#                              Workflow Sensor falco-escalation renders passes; inline templates, other templates,
#                              cluster scope (even clusterScope: false), spec overrides (serviceAccountName, executor,
#                              workflowMetadata, podSpecPatch), extra or non-string parameters, parameters[].valueFrom
#                              and artifacts are denied
#   addons/crossplane           ValidatingPolicies (offline): tenants are denied raw CNPG / RDS / Cloud SQL objects in
#                              their namespaces while Crossplane and platform namespaces pass; production PostgreSQL XRs
#                              need highAvailability + backup, other environments are not matched
#   addons/secret-stores        ValidatingAdmissionPolicies of the per-tenant stores (offline, #96): in a tenant namespace
#                              only SecretStore openbao-tenant may be referenced (ClusterSecretStore default, another
#                              store, a data[] sourceRef to a ClusterSecretStore and a ClusterGenerator are denied);
#                              SecretStores there only from Kyverno's background controller
# and of the kyverno-policies addon (supply-chain gate per environment):
#   tests/kyverno/registries   offline: trusted-registry policy per environment (Audit vs Deny, default action for
#                              unlisted environments, init/ephemeral containers, platform registry untrusted w/o key)
#   tests/kyverno/platform-key offline: with a platform key only <registry.host>/<appsProject>/ is trusted
#   tests/kyverno/signatures   online (registry + Sigstore): cosign keyless verification of a real signed image (built
#                              through koorikla/ci@v1, so rejected by the commit-SHA identity pin); KYVERNO_ONLINE=1 only
#   tests/kyverno/signatures-transition
#                              online: during a pin move (transitionWorkflowRefs) images at either commit pass every
#                              check through the ||-chained attestors (#136); KYVERNO_ONLINE=1 only
# A suite's helm-values.yaml (optional) is passed to helm template. The kyverno CLI comes from mise.toml; skips only
# when it is missing (KYVERNO=/path/to/kyverno overrides).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_kyverno_policies =="

# Keyless identity (#41): the trusted koorikla/ci workflow is a commit SHA, and Renovate's custom manager
# (renovate.json) really matches that line - otherwise the pin would silently never be bumped.
wf_ref=$(yq -r '.imageVerification.github.workflowRef' "$ROOT/addons/kyverno-policies/values.yaml" | tr -d '\r')
assert_match "$wf_ref" '^[0-9a-f]{40}$' "kyverno-policies trusts koorikla/ci by commit SHA"
renovated=$(py - "$ROOT/renovate.json" "$ROOT/addons/kyverno-policies/values.yaml" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
for m in cfg.get("customManagers", []):
    if not any(re.search(p.strip("/"), "addons/kyverno-policies/values.yaml") for p in m.get("managerFilePatterns", [])):
        continue
    for ms in m.get("matchStrings", []):
        hit = re.search(ms.replace("(?<", "(?P<"), text)
        if hit and m.get("depNameTemplate") == "koorikla/ci":
            print(hit.group("currentDigest"), hit.group("currentValue"))
PY
)
assert_eq "${renovated%% *}" "$wf_ref" "renovate.json custom manager tracks workflowRef (datasource github-tags koorikla/ci)"
# Pin moves (#128): the allowlist (workflowRef + transitionWorkflowRefs) is the current commit and at most the previous
# one, every entry a full commit SHA, no repeats.
wf_refs=$(yq -r '[.imageVerification.github.workflowRef] + (.imageVerification.github.transitionWorkflowRefs // []) | .[]' \
  "$ROOT/addons/kyverno-policies/values.yaml" | tr -d '\r')
bad=""; n=0
for r in $wf_refs; do n=$((n + 1)); [[ "$r" =~ ^[0-9a-f]{40}$ ]] || bad="$bad $r"; done
assert_eq "$bad" "" "every trusted koorikla/ci workflow commit is a 40-hex SHA"
assert_eq "$([[ $n -ge 1 && $n -le 2 ]] && echo yes)" yes "at most 2 trusted koorikla/ci workflow commits during a pin move ($n)"
assert_eq "$(printf '%s\n' "$wf_refs" | sort -u | grep -c .)" "$n" "trusted koorikla/ci workflow commits are unique"

KYVERNO=${KYVERNO:-kyverno}
if ! command -v "$KYVERNO" >/dev/null 2>&1; then
  echo "  SKIP kyverno CLI not found (set KYVERNO=/path/to/kyverno)"
  finish
  exit 0
fi

addon="$ROOT/addons/kyverno-policies"
[[ -d "$addon/charts" ]] || helm dependency build "$addon" >/dev/null
cp -R "$addon/tests/kyverno" "$TMP/kyverno"
suites=(registries platform-key)
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] && suites+=(signatures signatures-transition)
for s in "${suites[@]}"; do
  (
    hv=()
    [[ -f "$addon/tests/kyverno/$s/helm-values.yaml" ]] && hv=(-f "$addon/tests/kyverno/$s/helm-values.yaml")
    helm template kyverno-policies "$addon" --namespace kyverno -s templates/image-verification.yaml \
      ${hv[@]+"${hv[@]}"} > "$TMP/kyverno/$s/policies.yaml"
    rc=0
    "$KYVERNO" test "$TMP/kyverno/$s" > "$TMP/kyverno-$s.out" 2>&1 || rc=$?
    echo "$rc" > "$TMP/kyverno-$s.rc"
  ) &
done

# Native VAP: promotion to gated environments only through git (Argo CD)
ocp="$ROOT/addons/openchoreo-platform"
cp_chart="$ROOT/addons/openchoreo-control-plane"
[[ -d "$cp_chart/charts" ]] || helm dependency build "$cp_chart" >/dev/null
(
  helm show crds "$cp_chart" | yq 'select(.metadata.name == "releasebindings.openchoreo.dev")' > "$TMP/rb-crd.yaml"
  helm template openchoreo-platform "$ocp" --namespace default -s templates/promotion-git-only.yaml > "$TMP/vap.yaml"
  for c in argocd:resources api:resources argocd:smuggled; do
    who=${c%%:*}; res=${c#*:}
    "$KYVERNO" apply "$TMP/vap.yaml" --resource "$ocp/tests/vap/$res.yaml" --userinfo "$ocp/tests/vap/$who.yaml" \
      --values-file "$ocp/tests/vap/values.yaml" --crd-paths "$TMP/rb-crd.yaml" > "$TMP/ocp-$who-$res.out" 2>&1 || true
  done
) &

# Native VAP: Workflows in argo-events run only WorkflowTemplate falco-response (the Sensor's pin)
# (The kyverno CLI evaluates native VAPs as CREATE only, oldObject unset: the UPDATE rule - spec kept, except
# shutdown/suspend - is pinned by the addon's helm-unittest and was checked against a real API server in #77.)
ae="$ROOT/addons/argo-events"
wp_chart="$ROOT/addons/openchoreo-workflow-plane"
[[ -d "$wp_chart/charts" ]] || helm dependency build "$wp_chart" >/dev/null
(
  render_standalone_addon openchoreo-workflow-plane "$TMP/wp.yaml"
  yq 'select(.kind == "CustomResourceDefinition" and .metadata.name == "workflows.argoproj.io")' "$TMP/wp.yaml" > "$TMP/wf-crd.yaml"
  helm template argo-events "$ae" --namespace argo-events --set workflowPlane=true -s templates/workflow-admission.yaml \
    > "$TMP/ae-vap.yaml"
  for res in allowed denied; do
    "$KYVERNO" apply "$TMP/ae-vap.yaml" --resource "$ae/tests/vap/$res.yaml" --userinfo "$ae/tests/vap/sensor.yaml" \
      --values-file "$ae/tests/vap/values.yaml" --crd-paths "$TMP/wf-crd.yaml" > "$TMP/ae-$res.out" 2>&1 || true
  done
  # auto-build webhook (#164): the Sensor's Workflows in the run namespace run only WorkflowTemplate auto-build;
  # other creators there (OpenChoreo's agent: builds, gates) are not matched.
  helm template argo-events "$ae" --namespace argo-events --set workflowPlane=true \
    --set openchoreo.workflowPlane.autoBuild=webhook -s templates/auto-build-webhook.yaml \
    | yq 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' > "$TMP/ab-vap.yaml"
  for c in sensor:allowed sensor:denied agent:denied; do
    who=${c%%:*}; res=${c#*:}
    "$KYVERNO" apply "$TMP/ab-vap.yaml" --resource "$ae/tests/vap-auto-build/$res.yaml" \
      --userinfo "$ae/tests/vap-auto-build/$who.yaml" --values-file "$ae/tests/vap-auto-build/values.yaml" \
      --crd-paths "$TMP/wf-crd.yaml" > "$TMP/ab-$who-$res.out" 2>&1 || true
  done
) &

# Native VAPs of addon secret-stores: tenant namespaces use only their own SecretStore (per-tenant OpenBao stores)
ss="$ROOT/addons/secret-stores"
eso="$ROOT/addons/external-secrets"
[[ -d "$eso/charts" ]] || helm dependency build "$eso" >/dev/null
(
  helm template eso "$eso" --namespace external-secrets | yq 'select(.kind == "CustomResourceDefinition" and
    (.metadata.name == "externalsecrets.external-secrets.io" or .metadata.name == "secretstores.external-secrets.io"))' \
    > "$TMP/eso-crds.yaml"
  helm template secret-stores "$ss" --namespace external-secrets -f "$ss/values/role-workload.yaml" \
    --set secrets.tenantStores.enabled=true --set cluster.name=dev1 --set mesh.ca.host=openbao.example.test \
    -s templates/tenant-stores.yaml > "$TMP/ss-tenant.yaml"
  # one policy per run (the CLI applies every given VAP to every given resource; namespaceSelector and resource rules
  # are pinned by the addon's helm-unittest)
  for p in externalsecrets:platform-tenant-externalsecret-store secretstores:platform-tenant-secretstores-platform-owned; do
    yq "select(.metadata.name == \"${p#*:}\")" "$TMP/ss-tenant.yaml" > "$TMP/ss-vap-${p%%:*}.yaml"
  done
  for c in tenant:externalsecrets tenant:secretstores kyverno:secretstores; do
    who=${c%%:*}; res=${c#*:}
    "$KYVERNO" apply "$TMP/ss-vap-$res.yaml" --resource "$ss/tests/vap/$res.yaml" --userinfo "$ss/tests/vap/$who.yaml" \
      --values-file "$ss/tests/vap/values.yaml" --crd-paths "$TMP/eso-crds.yaml" > "$TMP/ss-$who-$res.out" 2>&1 || true
  done
) &

# Kyverno ValidatingPolicies of addon crossplane: PostgreSQL only through the platform API
xp="$ROOT/addons/crossplane"
[[ -d "$xp/charts" ]] || helm dependency build "$xp" >/dev/null
(
  helm template crossplane "$xp" --namespace crossplane-system -s templates/policies.yaml > "$TMP/xp-policies.yaml"
  for c in raw-objects:tenant raw-objects:crossplane platform-namespace:tenant xrs:tenant; do
    res=${c%%:*}; who=${c#*:}
    "$KYVERNO" apply "$TMP/xp-policies.yaml" --resource "$xp/tests/kyverno/$res.yaml" \
      --userinfo "$xp/tests/kyverno/$who.yaml" --values-file "$xp/tests/kyverno/values.yaml" > "$TMP/xp-$res-$who.out" 2>&1 || true
  done
) &
# PR previews (templates/previews.yaml, #168): on mgmt the expiry stamp, the per-tenant cap (resource.List context) and
# the TTL DeletingPolicy on Environments; on data planes the guardrails generated into preview cell namespaces.
pvt="$addon/tests/kyverno/previews"
(
  helm show crds "$cp_chart" | yq 'select(.metadata.name == "environments.openchoreo.dev")' > "$TMP/env-crd.yaml"
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/previews.yaml --set previews.enabled=true \
    -f "$addon/values/role-mgmt.yaml" > "$TMP/pv-mgmt.yaml"
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/previews.yaml --set previews.enabled=true \
    > "$TMP/pv-workload.yaml"
  for k in MutatingPolicy ValidatingPolicy DeletingPolicy; do
    yq "select(.kind == \"$k\")" "$TMP/pv-mgmt.yaml" > "$TMP/pv-$k.yaml"
  done
  yq 'select(.kind == "GeneratingPolicy")' "$TMP/pv-workload.yaml" > "$TMP/pv-GeneratingPolicy.yaml"
  sed "s/@IN_GRACE@/$(( $(date +%s) - 600 ))/" "$pvt/environments-ttl.yaml" > "$TMP/pv-environments-ttl.yaml"
  crd=(--crd-paths "$TMP/env-crd.yaml")
  "$KYVERNO" apply "$TMP/pv-MutatingPolicy.yaml" --resource "$pvt/environment-new.yaml" "${crd[@]}" > "$TMP/pv-stamp.out" 2>&1 || true
  date +%s > "$TMP/pv-stamp.time"
  for c in at-cap below-cap; do
    "$KYVERNO" apply "$TMP/pv-ValidatingPolicy.yaml" --resource "$pvt/environment-new.yaml" \
      --context-file "$pvt/context-$c.yaml" "${crd[@]}" > "$TMP/pv-cap-$c.out" 2>&1 || true
  done
  "$KYVERNO" apply "$TMP/pv-DeletingPolicy.yaml" --resource "$TMP/pv-environments-ttl.yaml" "${crd[@]}" > "$TMP/pv-ttl.out" 2>&1 || true
  "$KYVERNO" apply "$TMP/pv-GeneratingPolicy.yaml" --resource "$pvt/namespaces.yaml" > "$TMP/pv-guardrails.out" 2>&1 || true
) &
wait

for s in "${suites[@]}"; do
  out=$(cat "$TMP/kyverno-$s.out")
  if [[ "$(cat "$TMP/kyverno-$s.rc")" == 0 && "$out" =~ "0 tests failed" ]]; then
    assert_eq ok ok "kyverno test $s"
  else
    echo "$out" >&2
    assert_eq failed ok "kyverno test $s"
  fi
done
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] || echo "  SKIP signatures, signatures-transition (needs network: KYVERNO_ONLINE=1)"

# who:resources:expected  (staging bindings are out of scope and not counted)
for c in argocd:resources:'pass: 1, fail: 0, warn: 0, error: 0' api:resources:'pass: 0, fail: 1, warn: 0, error: 0' \
  argocd:smuggled:'pass: 0, fail: 5, warn: 0, error: 0'; do
  who=${c%%:*}; rest=${c#*:}; res=${rest%%:*}; want=${rest#*:}
  out=$(cat "$TMP/ocp-$who-$res.out")
  assert_match "$out" "$want" "VAP openchoreo-gated-bindings-from-git: $who applying tests/vap/$res.yaml -> $want"
done

assert_nonempty "$(yq '.metadata.name' "$TMP/wf-crd.yaml")" "Argo Workflow CRD rendered from addon openchoreo-workflow-plane"
for c in allowed:'pass: 1, fail: 0' denied:'pass: 0, fail: 13'; do
  res=${c%%:*}; want=${c#*:}
  out=$(cat "$TMP/ae-$res.out")
  assert_match "$out" "$want, warn: 0, error: 0" "VAP argo-events-workflows-falco-response-only: tests/vap/$res.yaml -> $want"
done
for c in sensor:allowed:'pass: 1, fail: 0, warn: 0, error: 0' sensor:denied:'pass: 0, fail: 7, warn: 0, error: 0' \
  agent:denied:'pass: 0, fail: 0, warn: 0, error: 0'; do
  who=${c%%:*}; rest=${c#*:}; res=${rest%%:*}; want=${rest#*:}
  out=$(cat "$TMP/ab-$who-$res.out")
  assert_match "$out" "$want" "VAP argo-events-auto-build-workflows: $who applying tests/vap-auto-build/$res.yaml -> $want"
done

# who:resources:expected
for c in tenant:externalsecrets:'pass: 2, fail: 4' tenant:secretstores:'pass: 0, fail: 1' kyverno:secretstores:'pass: 1, fail: 0'; do
  who=${c%%:*}; rest=${c#*:}; res=${rest%%:*}; want=${rest#*:}
  out=$(cat "$TMP/ss-$who-$res.out")
  assert_match "$out" "$want, warn: 0, error: 0" "secret-stores tenant VAPs: $who applying tests/vap/$res.yaml -> $want"
done

# resources:userinfo:expected
for c in raw-objects:tenant:'pass: 0, fail: 4, warn: 0, error: 0, skip: 0' \
  raw-objects:crossplane:'pass: 0, fail: 0, warn: 0, error: 0, skip: 4' \
  platform-namespace:tenant:'pass: 0, fail: 0, warn: 0, error: 0, skip: 1' \
  xrs:tenant:'pass: 1, fail: 2, warn: 0, error: 0, skip: 0'; do
  res=${c%%:*}; rest=${c#*:}; who=${rest%%:*}; want=${rest#*:}
  out=$(cat "$TMP/xp-$res-$who.out")
  assert_match "$out" "$want" "crossplane policies: $who applying tests/kyverno/$res.yaml -> $want"
done

# previews: stamp = now + 48h (unix seconds, within the test's clock window)
out=$(cat "$TMP/pv-stamp.out")
assert_match "$out" 'pass: 1, fail: 0, warn: 0, error: 0' "previews: platform-preview-expiry mutates a new preview Environment"
stamp=$(printf '%s\n' "$out" | sed -n 's/.*platform.koorikla.io\/expires-at: "\([0-9]*\)".*/\1/p' | head -1)
now=$(cat "$TMP/pv-stamp.time")
assert_eq "$([[ -n "$stamp" ]] && (( stamp > now + 172800 - 120 && stamp <= now + 172800 )) && echo yes || echo "no ($stamp vs $now)")" yes \
  "previews: expires-at = creation + 48h"
assert_match "$(cat "$TMP/pv-cap-at-cap.out")" 'pass: 0, fail: 1, warn: 0, error: 0' "previews: a 3rd preview of tenant demo is denied (cap 2)"
assert_match "$(cat "$TMP/pv-cap-at-cap.out")" 'tenant demo already runs 2 preview environment\(s\), the cap is 2' "previews: the cap denial names tenant and cap"
assert_match "$(cat "$TMP/pv-cap-below-cap.out")" 'pass: 1, fail: 0, warn: 0, error: 0' "previews: the 2nd preview passes; other tenants' previews and development do not count"
out=$(cat "$TMP/pv-ttl.out")
assert_match "$out" 'pass: 2, fail: 3, warn: 0, error: 0' "previews: platform-preview-ttl deletes 2 of 5 Environments"
for keep in pr-2-fresh pr-4-in-grace development; do
  assert_match "$out" "resource default/Environment/$keep failed" "previews: TTL keeps $keep"
done
out=$(cat "$TMP/pv-guardrails.out")
assert_match "$out" 'pass: 1, fail: 0, warn: 0, error: 0' "previews: guardrails match only the preview cell namespace"
for k in 'kind: ResourceQuota' 'kind: LimitRange' 'name: platform-preview-isolation'; do
  assert_match "$out" "$k" "previews: preview cell namespace gets $k"
done

finish
