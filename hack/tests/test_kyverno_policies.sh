#!/usr/bin/env bash
# Kyverno CLI tests of rendered admission policies:
#   addons/openchoreo-platform ValidatingAdmissionPolicy openchoreo-gated-bindings-from-git (offline): production
#                              bindings from the component's gated Argo CD Application pass; from openchoreo-api, from
#                              the app's main Application, another tenant's Application, another app's gated
#                              Application (either direction) or without tracking-id are denied; staging is out of scope;
#                              production ResourceReleaseBindings only from a gated Application of their project (#70)
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
#                              CloudNativePG (#327): exactly the pinned operator + imageCatalog images of
#                              addons/cloudnative-pg pass in production (fixtures generated from its values); another
#                              digest, an unlisted or tag-only image, or an untrusted sidecar next to them are denied
#   tests/kyverno/platform-key offline: with a platform key only <registry.host>/<appsProject>/ is trusted
#   tests/kyverno/workflow-digests
#                              offline (#36, templates/workflow-image-digests.yaml): in workflows-* every container,
#                              initContainer and ephemeral container image is image@sha256:<64 hex>; tag-only, implicit
#                              latest and malformed digests are denied, other namespaces are not matched
#   tests/kyverno/workload-resilience
#                              offline (#251, templates/workload-resilience.yaml): production Deployments need >= 2
#                              replicas (or an autoscaler floor label >= 2), readiness probes, cpu+memory requests; HPAs
#                              >= 2; Deny in production, Audit (skip vs fail) elsewhere
#   tests/kyverno/data-plane-capabilities
#                              offline (#70, templates/data-plane-capabilities.yaml, mgmt): a ResourceReleaseBinding of a
#                              type with platform.koorikla.io/requires-addons passes only to a data plane annotated with
#                              that addon (absent or "false" is denied, with the addon named); types without a requirement
#                              pass anywhere; a binding of a missing Resource is denied
#   tests/kyverno/cell-mesh    offline (#53, templates/cell-mesh.yaml): ambient cells get the HBONE NetworkPolicy (with the
#                              kubelet probe source 169.254.7.127) and a STRICT PeerAuthentication (PERMISSIVE when opted out); cells with dataplane-mode none,
#                              non-cells and platform namespaces get neither
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

# Keyless identity (#41): the trusted app-container.yaml workflow is a commit SHA, and Renovate's custom manager
# (renovate.json) really matches that line - otherwise the pin would silently never be bumped.
wf_ref=$(yq -r '.imageVerification.github.workflowRef' "$ROOT/addons/kyverno-policies/values.yaml" | tr -d '\r')
assert_match "$wf_ref" '^[0-9a-f]{40}$' "kyverno-policies trusts the app-container.yaml workflow by commit SHA"
renovated=$(py - "$ROOT/renovate.json" "$ROOT/addons/kyverno-policies/values.yaml" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
for m in cfg.get("customManagers", []):
    if not any(re.search(p.strip("/"), "addons/kyverno-policies/values.yaml") for p in m.get("managerFilePatterns", [])):
        continue
    for ms in m.get("matchStrings", []):
        hit = re.search(ms.replace("(?<", "(?P<"), text)
        if hit and m.get("depNameTemplate") == "koorikla/platform":
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
assert_eq "$bad" "" "every trusted app-container.yaml workflow commit is a 40-hex SHA"
assert_eq "$([[ $n -ge 1 && $n -le 2 ]] && echo yes)" yes "at most 2 trusted app-container.yaml workflow commits during a pin move ($n)"
assert_eq "$(printf '%s\n' "$wf_refs" | sort -u | grep -c .)" "$n" "trusted app-container.yaml workflow commits are unique"

KYVERNO=${KYVERNO:-kyverno}
if ! command -v "$KYVERNO" >/dev/null 2>&1; then
  echo "  SKIP kyverno CLI not found (set KYVERNO=/path/to/kyverno)"
  finish
  exit 0
fi

addon="$ROOT/addons/kyverno-policies"
[[ -d "$addon/charts" ]] || helm dependency build "$addon" >/dev/null
cp -R "$addon/tests/kyverno" "$TMP/kyverno"
# Argo parity: the catalog's valuesFromAddons (charts/platform values.yaml) come before the chart's own values.yaml.
from=()
while IFS= read -r a; do
  if [[ -n "$a" ]]; then from+=(-f "$ROOT/addons/$a/values.yaml"); fi
done < <(yq -r '.addons["kyverno-policies"].valuesFromAddons // [] | .[]' "$ROOT/charts/platform/values.yaml" | tr -d '\r')
assert_eq "${from[*]:-}" "-f $ROOT/addons/cloudnative-pg/values.yaml" "kyverno-policies reads addons/cloudnative-pg values (catalog valuesFromAddons)"
# CloudNativePG fixtures (#327) from the pins in addons/cloudnative-pg/values.yaml, so a pin bump needs no test edit:
# operator (bootstrap-controller) + catalog image pass; another digest, an unlisted image, the tag only and an
# untrusted sidecar next to the pinned images are denied in production.
cnpg="$ROOT/addons/cloudnative-pg/values.yaml"
pg=$(yq -r '.imageCatalog.images["17"]' "$cnpg" | tr -d '\r')
op=$(yq -r '.["cloudnative-pg"].image | .repository + ":" + .tag' "$cnpg" | tr -d '\r')
z64=$(printf '%064d' 0)
cnpg_pod() {  # <name> <init image> <container image>...
  local n=$1 init=$2 i; shift 2
  printf -- '---\napiVersion: v1\nkind: Pod\nmetadata: { name: %s, namespace: dp-default-demo-production-1, labels: { cnpg.io/cluster: pg } }\nspec:\n' "$n"
  printf '  initContainers:\n    - { name: bootstrap-controller, image: "%s" }\n  containers:\n' "$init"
  for i in "$@"; do printf '    - { name: c%s, image: "%s" }\n' "${#i}" "$i"; done
}
{
  cnpg_pod prod-cnpg-catalog "$op" "$pg"
  cnpg_pod prod-cnpg-other-digest "$op" "${pg%@*}@sha256:$z64"
  cnpg_pod prod-cnpg-operator-other-digest "${op%@*}@sha256:$z64" "$pg"
  cnpg_pod prod-cnpg-unlisted "$op" "ghcr.io/cloudnative-pg/postgresql:15.14-standard-trixie@sha256:$z64"
  cnpg_pod prod-cnpg-tag-only "$op" "${pg%@*}"
  cnpg_pod prod-cnpg-untrusted-sidecar "$op" "$pg" "docker.io/library/busybox:1.37"
} > "$TMP/kyverno/registries/resources-cnpg.yaml"
suites=(registries platform-key workflow-digests workload-resilience)
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] && suites+=(signatures signatures-transition)
for s in "${suites[@]}"; do
  (
    hv=()
    [[ -f "$addon/tests/kyverno/$s/helm-values.yaml" ]] && hv=(-f "$addon/tests/kyverno/$s/helm-values.yaml")
    tpl=templates/image-verification.yaml
    [[ "$s" == workflow-digests ]] && tpl=templates/workflow-image-digests.yaml
    [[ "$s" == workload-resilience ]] && tpl=templates/workload-resilience.yaml
    helm template kyverno-policies "$addon" --namespace kyverno -s "$tpl" ${from[@]+"${from[@]}"} -f "$addon/values.yaml" \
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
  helm show crds "$cp_chart" | yq 'select(.metadata.name == "releasebindings.openchoreo.dev" or .metadata.name == "resourcereleasebindings.openchoreo.dev")' > "$TMP/rb-crd.yaml"
  helm template openchoreo-platform "$ocp" --namespace default -s templates/promotion-git-only.yaml > "$TMP/vap.yaml"
  for c in argocd:resources api:resources argocd:smuggled argocd:resource-bindings api:resource-bindings \
    argocd:resource-bindings-smuggled; do
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
    --set openchoreo.workflowPlane.autoBuild=webhook --set secrets.githubGateApp.enabled=true -s templates/auto-build-webhook.yaml \
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

# Kyverno GeneratingPolicy of addon openbao (#267): a tenant descriptor per preview ProjectReleaseBinding
ob="$ROOT/addons/openbao"
(
  helm show crds "$cp_chart" | yq 'select(.metadata.name == "projectreleasebindings.openchoreo.dev")' > "$TMP/prb-crd.yaml"
  helm template openbao "$ob" --namespace openbao --values "$ROOT/installations/local/installation.yaml" \
    --set secrets.tenantStores.enabled=true --set previews.enabled=true -s templates/tenant-previews.yaml \
    | yq 'select(.kind == "GeneratingPolicy")' > "$TMP/ob-previews.yaml"
  "$KYVERNO" apply "$TMP/ob-previews.yaml" --resource "$ob/tests/kyverno/preview-tenant-secrets/bindings.yaml" \
    --crd-paths "$TMP/prb-crd.yaml" > "$TMP/ob-previews.out" 2>&1 || true
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
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/previews.yaml --set previews.enabled=true \
    --set cluster.cni=cilium | yq 'select(.kind == "GeneratingPolicy")' > "$TMP/pv-GeneratingPolicy-cilium.yaml"
  "$KYVERNO" apply "$TMP/pv-GeneratingPolicy-cilium.yaml" --resource "$pvt/namespaces.yaml" > "$TMP/pv-guardrails-cilium.out" 2>&1 || true
) &
# Data-plane capabilities of resource types (templates/data-plane-capabilities.yaml, #70): resource.List context.
dpct="$addon/tests/kyverno/data-plane-capabilities"
(
  helm show crds "$cp_chart" | yq 'select(.metadata.name | test("^(resourcereleasebindings|resources|clusterresourcetypes|environments|clusterdataplanes)\\.openchoreo\\.dev$"))' > "$TMP/rrb-crd.yaml"
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/data-plane-capabilities.yaml \
    -f "$addon/values/role-mgmt.yaml" | yq 'select(.kind == "ValidatingPolicy")' > "$TMP/dpc.yaml"
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/data-plane-capabilities.yaml \
    > "$TMP/dpc-workload.yaml" 2>&1 || true
  for c in capable incapable opted-out; do
    for b in bindings binding-cache binding-orphan; do
      "$KYVERNO" apply "$TMP/dpc.yaml" --resource "$dpct/$b.yaml" --context-file "$dpct/context-$c.yaml" \
        --crd-paths "$TMP/rrb-crd.yaml" > "$TMP/dpc-$c-$b.out" 2>&1 || true
    done
  done
) &
# Mesh policy of ambient cells (templates/cell-mesh.yaml, #53): HBONE NetworkPolicy and STRICT PeerAuthentication.
cmt="$addon/tests/kyverno/cell-mesh"
(
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/cell-mesh.yaml > "$TMP/cm.yaml"
  for p in openchoreo-cell-hbone openchoreo-cell-mtls; do
    yq "select(.kind == \"GeneratingPolicy\" and .metadata.name == \"$p\")" "$TMP/cm.yaml" > "$TMP/cm-$p.yaml"
    "$KYVERNO" apply "$TMP/cm-$p.yaml" --resource "$cmt/namespaces.yaml" > "$TMP/cm-$p.out" 2>&1 || true
  done
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
  argocd:smuggled:'pass: 0, fail: 5, warn: 0, error: 0' argocd:resource-bindings:'pass: 1, fail: 0, warn: 0, error: 0' \
  api:resource-bindings:'pass: 0, fail: 1, warn: 0, error: 0' argocd:resource-bindings-smuggled:'pass: 0, fail: 4, warn: 0, error: 0'; do
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
assert_eq "$(grep -c 'kind: CiliumNetworkPolicy' <<<"$out" || true)" 0 "previews: no CiliumNetworkPolicy without cni cilium"
# #331: the preview's own database. Quota: the smallest postgresql volume the ClusterResourceType allows must fit next
# to the app (the type's minimum is the one source; a smaller quota denies the CNPG PVC).
crt_min=$(yq -r '.spec.environmentConfigs.openAPIV3Schema.properties.storageGiB.minimum' \
  "$ROOT/addons/openchoreo-platform/files/platform/cluster-resource-types/postgresql.yaml" | tr -d '\r')
quota=$(yq -r '.previewGuards.quota["requests.storage"]' "$addon/values.yaml" | tr -d '\r')
assert_match "$crt_min" '^[0-9]+$' "previews: ClusterResourceType postgresql declares a storageGiB minimum ($crt_min)"
assert_match "$quota" '^[0-9]+Gi$' "previews: the storage quota is in Gi ($quota)"
assert_eq "$([[ ${quota%Gi} -ge $((crt_min + 5)) ]] && echo fits)" fits \
  "previews: storage quota $quota >= postgresql minimum ${crt_min}Gi + 5Gi app volumes"
# API egress (Cilium never matches ipBlocks against the API server): generated only with cni cilium, and its selectors
# match exactly CNPG instance / job pods - never an app pod, even one that copies CNPG labels.
out=$(cat "$TMP/pv-guardrails-cilium.out")
assert_match "$out" 'pass: 1, fail: 0, warn: 0, error: 0' "previews (cilium): guardrails match only the preview cell namespace"
assert_match "$out" 'name: platform-preview-database-apiserver' "previews (cilium): the preview cell gets the database API egress policy"
cnp=$(yq 'select(.kind == "GeneratingPolicy") | .spec.generate[0].template.value' "$TMP/pv-GeneratingPolicy-cilium.yaml" \
  | yq -o=json 'select(.kind == "CiliumNetworkPolicy")')
sel=$(py - "$cnp" <<'PY'
import json, sys
cnp = json.loads(sys.argv[1])
def matches(sel, labels):
    for e in sel["matchExpressions"]:
        k, op = e["key"], e["operator"]
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
        if op == "In" and labels.get(k) not in e["values"]: return False
    return True
pods = {
    "instance": {"cnpg.io/cluster": "orders-db", "cnpg.io/podRole": "instance", "cnpg.io/instanceName": "orders-db-1"},
    "initdb": {"cnpg.io/cluster": "orders-db", "cnpg.io/jobRole": "initdb", "batch.kubernetes.io/job-name": "x"},
    "app": {"openchoreo.dev/component": "hello-world", "openchoreo.dev/project": "demo"},
    "app-forging-cnpg": {"openchoreo.dev/component": "hello-world", "cnpg.io/cluster": "x", "cnpg.io/podRole": "instance"},
    "pooler": {"cnpg.io/cluster": "orders-db", "cnpg.io/podRole": "pooler"},
    "cluster-label-only": {"cnpg.io/cluster": "orders-db"},
    "role-without-cluster": {"cnpg.io/podRole": "instance"},
}
specs = cnp["spec"]["specs"]
for s in specs:
    assert s["egress"] == [{"toEntities": ["kube-apiserver"], "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}, {"port": "6443", "protocol": "TCP"}]}]}], s
print(" ".join(n for n, l in pods.items() if any(matches(s["endpointSelector"], l) for s in specs)))
PY
)
assert_eq "$sel" "instance initdb" "previews (cilium): kube-apiserver egress only for CNPG instance and job pods"

# openbao preview descriptors: exactly the preview binding in the org namespace, tenant = its project (not a label)
out=$(cat "$TMP/ob-previews.out")
assert_match "$out" 'pass: 1, fail: 0, warn: 0, error: 0' "openbao previews: only the pr-<n> preview binding in the org namespace"
assert_match "$out" 'name: demo-openbao-tenant-pr-33-hello-world' "openbao previews: descriptor <project>-openbao-tenant-<environment>"
assert_match "$out" 'namespace: openbao-tenants' "openbao previews: descriptor in the inputs namespace"
assert_match "$out" "tenant: $(printf demo | base64)" "openbao previews: tenant = spec.owner.projectName (demo), never the tenant label"
assert_match "$out" "environment: $(printf pr-33-hello-world | base64)" "openbao previews: environment = spec.environment"
assert_match "$out" 'openbao.platform.koorikla.io/tenant: "true"' "openbao previews: descriptor label (found by tenant-clients)"

# data-plane capabilities: context:binding:expected
pass='pass: 1, fail: 0, warn: 0, error: 0'; fail='pass: 0, fail: 1, warn: 0, error: 0'
for c in capable:bindings:"$pass" incapable:bindings:"$fail" opted-out:bindings:"$fail" \
  capable:binding-cache:"$pass" incapable:binding-cache:"$pass" capable:binding-orphan:"$fail"; do
  ctx=${c%%:*}; rest=${c#*:}; b=${rest%%:*}; want=${rest#*:}
  assert_match "$(cat "$TMP/dpc-$ctx-$b.out")" "$want" "data-plane capabilities: $b.yaml with data plane $ctx -> $want"
done
assert_match "$(cat "$TMP/dpc-incapable-bindings.out")" \
  'ClusterResourceType postgresql needs addon\(s\) crossplane on the data plane of environment development, but ClusterDataPlane dev1 does not run crossplane' \
  "data-plane capabilities: the denial names type, addon, environment and data plane"
assert_match "$(cat "$TMP/dpc-capable-binding-orphan.out")" 'Resource ghost does not exist in namespace default' \
  "data-plane capabilities: a binding of a missing Resource is denied"
assert_eq "$(grep -c 'kind:' "$TMP/dpc-workload.yaml" || true)" 0 "data-plane capabilities: not rendered on workload clusters"

# cell mesh: policy:expected count:namespaces that must match (tests/kyverno/cell-mesh/namespaces.yaml lists why)
for c in openchoreo-cell-hbone:3:'development production legacy' openchoreo-cell-mtls:3:'development production legacy'; do
  p=${c%%:*}; rest=${c#*:}; n=${rest%%:*}; want=${rest#*:}
  out=$(cat "$TMP/cm-$p.out")
  assert_match "$out" "pass: $n, fail: 0, warn: 0, error: 0" "cell mesh: $p generates into $n of 6 namespaces"
  got=$(printf '%s\n' "$out" | sed -n "s|^policy $p applied to /Namespace/dp-default-demo-\([a-z]*\)-1234abcd:.*|\1|p" | tr '\n' ' ')
  assert_eq "${got% }" "$want" "cell mesh: $p matches exactly the cells: $want"
done
assert_match "$(cat "$TMP/cm-openchoreo-cell-hbone.out")" 'port: 15008' "cell mesh: HBONE NetworkPolicy opens tcp 15008"
# Kubelet probes (ambient SNATs them to a link-local source that Cilium treats as world): every generated policy has
# one rule admitting exactly the probe sources (any port), and no ipBlock rule opens 15008. Shape per policy:
#   <probe source CIDRs>|<ports of that rule>|<rules that combine 15008 with an ipBlock>
sed -n '/^apiVersion: networking.k8s.io/,/^---$/p' "$TMP/cm-openchoreo-cell-hbone.out" |
  yq -o=json -I=0 'select(.kind == "NetworkPolicy")' > "$TMP/cm-np.json"
probes=$(python3 -c '
import json, sys
for line in sys.stdin:
    rules = json.loads(line)["spec"]["ingress"]
    blocks = [r for r in rules if any("ipBlock" in f for f in r["from"])]
    cidrs = ",".join(f.get("ipBlock", {}).get("cidr", "peer") for r in blocks for f in r["from"])
    ports = ",".join(str(p["port"]) for r in blocks for p in r.get("ports", [])) or "any"
    hbone = sum(1 for r in blocks if any(p["port"] == 15008 for p in r.get("ports", [])))
    print(f"{cidrs}|{ports}|{hbone}")
' < "$TMP/cm-np.json" | tr -d '\r' | tr '\n' ' ')
want='169.254.7.127/32,fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128|any|0'
assert_eq "${probes% }" "$want $want $want" "cell mesh: every HBONE NetworkPolicy admits kubelet probes from ambient's SNAT source only"
# PeerAuthentication mode per cell, in output order: STRICT unless opted out with platform.koorikla.io/mtls=permissive
modes=$(sed -n 's/^ *mode: \([A-Z]*\)$/\1/p' "$TMP/cm-openchoreo-cell-mtls.out" | tr '\n' ' ')
assert_eq "${modes% }" "STRICT STRICT PERMISSIVE" "cell mesh: PeerAuthentication STRICT in development/production, PERMISSIVE in the opted-out cell"

finish
