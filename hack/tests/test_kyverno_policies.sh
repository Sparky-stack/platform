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
#   tests/kyverno/previews     offline (#168, templates/previews.yaml, mgmt): the per-tenant preview cap (at-cap, below-cap)
#   tests/kyverno/previews-guardrails, previews-guardrails-cilium
#                              offline (#168, #331, data planes): only preview cell namespaces get quota, limits, isolation
#                              (and the database API egress policy with cni cilium)
#   tests/kyverno/cell-mesh    offline (#53, templates/cell-mesh.yaml): ambient cells get the HBONE NetworkPolicy (with the
#                              kubelet probe source 169.254.7.127) and a STRICT PeerAuthentication (PERMISSIVE when opted out); cells with dataplane-mode none,
#                              non-cells and platform namespaces get neither. #324: AuthorizationPolicy platform-cell-peers,
#                              replayed with Istio's ALLOW semantics: another cell's workload and plaintext are refused
#   tests/kyverno/signatures   online (registry + Sigstore): cosign keyless verification of a real signed image (built
#                              through koorikla/ci@v1, so rejected by the commit-SHA identity pin); KYVERNO_ONLINE=1 only
#   tests/kyverno/signatures-transition
#                              online: during a pin move (transitionWorkflowRefs) images at either commit pass every
#                              check through the ||-chained attestors (#136); KYVERNO_ONLINE=1 only
# A suite's helm-values.yaml (optional) is passed to helm template; its ClusterResource fixtures (cluster.yaml) name the
# OpenChoreo CRDs they need as crds/<CRD name>.yaml. Shell checks below only what kyverno test cannot express (each says
# why). The kyverno CLI comes from mise.toml; skips only when it is missing (KYVERNO=/path/to/kyverno overrides).
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
        if hit and m.get("depNameTemplate") == "Sparky-stack/platform":
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
assert_eq "${from[*]:-}" "-f $ROOT/addons/cloudnative-pg/values.yaml -f $ROOT/addons/moco/values.yaml" "kyverno-policies reads addons/cloudnative-pg + addons/moco values (catalog valuesFromAddons)"
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
# MOCO fixtures (#256) from the pins in addons/moco/values.yaml: a MySQL pod (mysqld + moco-init = catalog image, agent +
# copy-moco-init = moco-agent) passes; another digest, the tag only and the slow-log sidecar (fluent-bit, not trusted:
# the Composition turns it off) are denied in production.
moco="$ROOT/addons/moco/values.yaml"
my=$(yq -r '.mysqlImageCatalog["8.4"]' "$moco" | tr -d '\r')
ag=$(yq -r '.moco.agent.image | .repository + ":" + .tag' "$moco" | tr -d '\r')
fb=$(yq -r '.moco.fluentbit.image | .repository + ":" + .tag' "$moco" | tr -d '\r')
{
  cnpg_pod prod-moco-mysql "$ag" "$my" "$ag"
  cnpg_pod prod-moco-other-digest "$ag" "${my%@*}@sha256:$z64" "$ag"
  cnpg_pod prod-moco-agent-tag-only "${ag%@*}" "$my"
  cnpg_pod prod-moco-slow-log "$ag" "$my" "$ag" "$fb"
} > "$TMP/kyverno/registries/resources-moco.yaml"
cp_chart="$ROOT/addons/openchoreo-control-plane"
[[ -d "$cp_chart/charts" ]] || helm dependency build "$cp_chart" >/dev/null
helm show crds "$cp_chart" > "$TMP/oc-crds.yaml"
suites=(registries platform-key workflow-digests workload-resilience previews previews-guardrails previews-guardrails-cilium
  data-plane-capabilities cell-mesh)
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] && suites+=(signatures signatures-transition)
for s in "${suites[@]}"; do
  (
    d="$TMP/kyverno/$s"
    hv=()
    [[ -f "$d/helm-values.yaml" ]] && hv=(-f "$d/helm-values.yaml")
    # The template a suite tests; policies that live on mgmt also take values/role-mgmt.yaml.
    case $s in
      workflow-digests) tpl=(-s templates/workflow-image-digests.yaml) ;;
      workload-resilience) tpl=(-s templates/workload-resilience.yaml) ;;
      previews) tpl=(-s templates/previews.yaml -f "$addon/values/role-mgmt.yaml") ;;
      previews-guardrails*) tpl=(-s templates/previews.yaml) ;;
      data-plane-capabilities) tpl=(-s templates/data-plane-capabilities.yaml -f "$addon/values/role-mgmt.yaml") ;;
      cell-mesh) tpl=(-s templates/cell-mesh.yaml) ;;
      *) tpl=(-s templates/image-verification.yaml) ;;
    esac
    helm template kyverno-policies "$addon" --namespace kyverno ${from[@]+"${from[@]}"} -f "$addon/values.yaml" "${tpl[@]}" \
      ${hv[@]+"${hv[@]}"} | yq 'select(.apiVersion == "policies.kyverno.io/v1")' > "$d/policies.yaml"
    mkdir -p "$d/crds"
    while IFS= read -r crd; do
      yq "select(.metadata.name == \"$crd\")" "$TMP/oc-crds.yaml" > "$d/crds/$crd.yaml"
    done < <(find "$d" -name cluster.yaml -exec yq -r '.spec.crds[]' {} + | sed 's|.*/||; s|\.yaml$||' | tr -d '\r' | sort -u)
    rc=0
    "$KYVERNO" test "$TMP/kyverno/$s" > "$TMP/kyverno-$s.out" 2>&1 || rc=$?
    echo "$rc" > "$TMP/kyverno-$s.rc"
  ) &
done

apply_cases() {   # apply_cases <policy(@RES@)> <dir> <crd|-> <prefix> <who|res|want>...
  local pol=$1 dir=$2 crd=$3 prefix=$4 c who res want uargs=() cargs=()
  shift 4
  [[ "$crd" == - ]] || cargs=(--crd-paths "$crd")
  for c in "$@"; do
    IFS='|' read -r who res want <<<"$c"
    uargs=(); [[ "$who" == - ]] || uargs=(--userinfo "$dir/$who.yaml")
    "$KYVERNO" apply "${pol//@RES@/$res}" --resource "$dir/$res.yaml" ${uargs[@]+"${uargs[@]}"} \
      --values-file "$dir/values.yaml" ${cargs[@]+"${cargs[@]}"} > "$TMP/$prefix-$who-$res.out" 2>&1 || true
  done
}
assert_apply_cases() {
  local label=$1 dir=$2 prefix=$3 c who res want
  shift 3
  for c in "$@"; do
    IFS='|' read -r who res want <<<"$c"
    assert_match "$(cat "$TMP/$prefix-$who-$res.out")" "$want" "$label: $who applying $dir/$res.yaml -> $want"
  done
}

OCP_CASES=(
  'argocd|resources|pass: 1, fail: 0, warn: 0, error: 0'
  'api|resources|pass: 0, fail: 1, warn: 0, error: 0'
  'argocd|smuggled|pass: 0, fail: 5, warn: 0, error: 0'
  'argocd|resource-bindings|pass: 1, fail: 0, warn: 0, error: 0'
  'api|resource-bindings|pass: 0, fail: 1, warn: 0, error: 0'
  'argocd|resource-bindings-smuggled|pass: 0, fail: 4, warn: 0, error: 0'
)
AE_CASES=(
  'sensor|allowed|pass: 1, fail: 0, warn: 0, error: 0'
  'sensor|denied|pass: 0, fail: 13, warn: 0, error: 0'
)
AB_CASES=(
  'sensor|allowed|pass: 1, fail: 0, warn: 0, error: 0'
  'sensor|denied|pass: 0, fail: 7, warn: 0, error: 0'
  'agent|denied|pass: 0, fail: 0, warn: 0, error: 0'
)
SS_CASES=(
  'tenant|externalsecrets|pass: 2, fail: 4, warn: 0, error: 0'
  'tenant|secretstores|pass: 0, fail: 1, warn: 0, error: 0'
  'kyverno|secretstores|pass: 1, fail: 0, warn: 0, error: 0'
)
XP_CASES=(
  'tenant|raw-objects|pass: 0, fail: 4, warn: 0, error: 0, skip: 0'
  'crossplane|raw-objects|pass: 0, fail: 0, warn: 0, error: 0, skip: 4'
  'tenant|platform-namespace|pass: 0, fail: 0, warn: 0, error: 0, skip: 1'
  'tenant|xrs|pass: 1, fail: 2, warn: 0, error: 0, skip: 0'
)

# Native VAP: promotion to gated environments only through git (Argo CD)
ocp="$ROOT/addons/openchoreo-platform"
(
  helm show crds "$cp_chart" | yq 'select(.metadata.name == "releasebindings.openchoreo.dev" or .metadata.name == "resourcereleasebindings.openchoreo.dev")' > "$TMP/rb-crd.yaml"
  helm template openchoreo-platform "$ocp" --namespace default -s templates/promotion-git-only.yaml > "$TMP/vap.yaml"
  apply_cases "$TMP/vap.yaml" "$ocp/tests/vap" "$TMP/rb-crd.yaml" ocp "${OCP_CASES[@]}"
) &

# Native VAP: Workflows in argo-events run only WorkflowTemplate falco-response (the Sensor's pin)
# (The kyverno CLI evaluates native VAPs as CREATE only, oldObject unset: the UPDATE rule is pinned by helm-unittest.)
ae="$ROOT/addons/argo-events"
wp_chart="$ROOT/addons/openchoreo-workflow-plane"
[[ -d "$wp_chart/charts" ]] || helm dependency build "$wp_chart" >/dev/null
(
  render_standalone_addon openchoreo-workflow-plane "$TMP/wp.yaml"
  yq 'select(.kind == "CustomResourceDefinition" and .metadata.name == "workflows.argoproj.io")' "$TMP/wp.yaml" > "$TMP/wf-crd.yaml"
  helm template argo-events "$ae" --namespace argo-events --set workflowPlane=true -s templates/workflow-admission.yaml \
    > "$TMP/ae-vap.yaml"
  apply_cases "$TMP/ae-vap.yaml" "$ae/tests/vap" "$TMP/wf-crd.yaml" ae "${AE_CASES[@]}"
  # auto-build webhook (#164): the Sensor's Workflows in the run namespace run only WorkflowTemplate auto-build;
  # other creators there (OpenChoreo's agent: builds, gates) are not matched.
  helm template argo-events "$ae" --namespace argo-events --set workflowPlane=true \
    --set openchoreo.workflowPlane.autoBuild=webhook --set secrets.githubGateApp.enabled=true -s templates/auto-build-webhook.yaml \
    | yq 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' > "$TMP/ab-vap.yaml"
  apply_cases "$TMP/ab-vap.yaml" "$ae/tests/vap-auto-build" "$TMP/wf-crd.yaml" ab "${AB_CASES[@]}"
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
  for p in externalsecrets:platform-tenant-externalsecret-store secretstores:platform-tenant-secretstores-platform-owned; do
    yq "select(.metadata.name == \"${p#*:}\")" "$TMP/ss-tenant.yaml" > "$TMP/ss-vap-${p%%:*}.yaml"
  done
  apply_cases "$TMP/ss-vap-@RES@.yaml" "$ss/tests/vap" "$TMP/eso-crds.yaml" ss "${SS_CASES[@]}"
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
  apply_cases "$TMP/xp-policies.yaml" "$xp/tests/kyverno" - xp "${XP_CASES[@]}"
) &
# PR previews on mgmt (templates/previews.yaml, #168): the expiry stamp and the TTL DeletingPolicy stay here because
# both are relative to the current time (kyverno test fixtures are static); the cap is suite tests/kyverno/previews.
pvt="$addon/tests/kyverno/previews"
(
  yq 'select(.metadata.name == "environments.openchoreo.dev")' "$TMP/oc-crds.yaml" > "$TMP/env-crd.yaml"
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/previews.yaml --set previews.enabled=true \
    -f "$addon/values/role-mgmt.yaml" > "$TMP/pv-mgmt.yaml"
  for k in MutatingPolicy DeletingPolicy; do
    yq "select(.kind == \"$k\")" "$TMP/pv-mgmt.yaml" > "$TMP/pv-$k.yaml"
  done
  sed "s/@IN_GRACE@/$(( $(date +%s) - 600 ))/" "$pvt/environments-ttl.yaml" > "$TMP/pv-environments-ttl.yaml"
  crd=(--crd-paths "$TMP/env-crd.yaml")
  "$KYVERNO" apply "$TMP/pv-MutatingPolicy.yaml" --resource "$pvt/environment-new.yaml" "${crd[@]}" > "$TMP/pv-stamp.out" 2>&1 || true
  date +%s > "$TMP/pv-stamp.time"
  "$KYVERNO" apply "$TMP/pv-DeletingPolicy.yaml" --resource "$TMP/pv-environments-ttl.yaml" "${crd[@]}" > "$TMP/pv-ttl.out" 2>&1 || true
) &
# A render check, not a policy verdict: data-plane capabilities are not rendered on workload clusters.
helm template kyverno-policies "$addon" --namespace kyverno -s templates/data-plane-capabilities.yaml \
  > "$TMP/dpc-workload.yaml" 2>&1 || true
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

assert_apply_cases "VAP openchoreo-gated-bindings-from-git" tests/vap ocp "${OCP_CASES[@]}"
assert_nonempty "$(yq '.metadata.name' "$TMP/wf-crd.yaml")" "Argo Workflow CRD rendered from addon openchoreo-workflow-plane"
assert_apply_cases "VAP argo-events-workflows-falco-response-only" tests/vap ae "${AE_CASES[@]}"
assert_apply_cases "VAP argo-events-auto-build-workflows" tests/vap-auto-build ab "${AB_CASES[@]}"
assert_apply_cases "secret-stores tenant VAPs" tests/vap ss "${SS_CASES[@]}"
assert_apply_cases "crossplane policies" tests/kyverno xp "${XP_CASES[@]}"

# previews: stamp = now + 48h (unix seconds, within the test's clock window)
out=$(cat "$TMP/pv-stamp.out")
assert_match "$out" 'pass: 1, fail: 0, warn: 0, error: 0' "previews: platform-preview-expiry mutates a new preview Environment"
stamp=$(sed -n 's/.*platform.koorikla.io\/expires-at: "\([0-9]*\)".*/\1/p' <<<"$out" | sed -n 1p)
now=$(cat "$TMP/pv-stamp.time")
assert_eq "$([[ -n "$stamp" ]] && (( stamp > now + 172800 - 120 && stamp <= now + 172800 )) && echo yes || echo "no ($stamp vs $now)")" yes \
  "previews: expires-at = creation + 48h"
out=$(cat "$TMP/pv-ttl.out")
assert_match "$out" 'pass: 2, fail: 3, warn: 0, error: 0' "previews: platform-preview-ttl deletes 2 of 5 Environments"
for keep in pr-2-fresh pr-4-in-grace development; do
  assert_match "$out" "resource default/Environment/$keep failed" "previews: TTL keeps $keep"
done
# #331: the preview's own database. Quota: the smallest postgresql volume the ClusterResourceType allows must fit next
# to the app (the type's minimum is the one source; a smaller quota denies the CNPG PVC).
crt_min=$(yq -r '.spec.environmentConfigs.openAPIV3Schema.properties.storageGiB.minimum' \
  "$ROOT/addons/openchoreo-platform/files/platform/cluster-resource-types/postgresql.yaml" | tr -d '\r')
quota=$(yq -r '.previewGuards.quota["requests.storage"]' "$addon/values.yaml" | tr -d '\r')
assert_match "$crt_min" '^[0-9]+$' "previews: ClusterResourceType postgresql declares a storageGiB minimum ($crt_min)"
assert_match "$quota" '^[0-9]+Gi$' "previews: the storage quota is in Gi ($quota)"
assert_eq "$([[ ${quota%Gi} -ge $((crt_min + 5)) ]] && echo fits)" fits \
  "previews: storage quota $quota >= postgresql minimum ${crt_min}Gi + 5Gi app volumes"
# API egress (Cilium never matches ipBlocks against the API server): generated only with cni cilium (suite
# previews-guardrails-cilium proves the generated objects equal its generated.yaml). Label selectors are semantics
# kyverno test does not evaluate: they match exactly CNPG instance / job pods - never an app pod, even one that copies
# CNPG labels.
cnp=$(yq -o=json 'select(.kind == "CiliumNetworkPolicy")' "$addon/tests/kyverno/previews-guardrails-cilium/generated.yaml")
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
specs = cnp["specs"]   # top-level, sibling of spec (CiliumNetworkPolicy schema)
for s in specs:
    assert s["egress"] == [{"toEntities": ["kube-apiserver"], "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}, {"port": "6443", "protocol": "TCP"}]}]}], s
print(" ".join(n for n, l in pods.items() if any(matches(s["endpointSelector"], l) for s in specs)))
PY
)
assert_eq "$sel" "instance initdb" "previews (cilium): kube-apiserver egress only for CNPG instance and job pods"
# The generated object must be a valid CiliumNetworkPolicy: Kyverno fails the WHOLE generate (quota, isolation, this)
# when the API server rejects it, and kubeconform never sees objects embedded in a policy (#331 live: spec.specs).
SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
[[ -s "$SCHEMAS_DIR/cilium.io/ciliumnetworkpolicy_v2.json" ]] || SCHEMAS_DIR="$SCHEMAS_DIR" "$ROOT/hack/schemas.sh" >/dev/null
yq -P '.' <<<"$cnp" > "$TMP/pv-cnp.yaml"
assert_eq "$(kc_valid "$TMP/pv-cnp.yaml")" yes "previews (cilium): the generated CiliumNetworkPolicy validates against the Cilium CRD schema"

# openbao preview descriptors: exactly the preview binding in the org namespace, tenant = its project (not a label)
out=$(cat "$TMP/ob-previews.out")
assert_matches "$out" <<'CASES'
openbao previews: only the pr-<n> preview binding in the org namespace | pass: 1, fail: 0, warn: 0, error: 0
openbao previews: descriptor <project>-openbao-tenant-<environment> | name: demo-openbao-tenant-pr-33-hello-world
openbao previews: descriptor in the inputs namespace | namespace: openbao-tenants
CASES
assert_match "$out" "tenant: $(printf demo | base64)" "openbao previews: tenant = spec.owner.projectName (demo), never the tenant label"
assert_match "$out" "environment: $(printf pr-33-hello-world | base64)" "openbao previews: environment = spec.environment"
assert_match "$out" 'openbao.platform.koorikla.io/tenant: "true"' "openbao previews: descriptor label (found by tenant-clients)"

assert_eq "$(grep -c 'kind:' "$TMP/dpc-workload.yaml" || true)" 0 "data-plane capabilities: not rendered on workload clusters"

# cell mesh: suite tests/kyverno/cell-mesh proves which namespaces get what and that the generated objects equal its
# generated.yaml. The checks below interpret those objects, which kyverno test does not do.
cmg="$addon/tests/kyverno/cell-mesh/generated.yaml"
# Kubelet probes (ambient SNATs them to a link-local source that Cilium treats as world): every generated policy has
# one rule admitting exactly the probe sources (any port), and no ipBlock rule opens 15008. Shape per policy:
#   <probe source CIDRs>|<ports of that rule>|<rules that combine 15008 with an ipBlock>
yq -o=json -I=0 'select(.kind == "NetworkPolicy" and .metadata.name == "platform-mesh-hbone")' "$cmg" > "$TMP/cm-np.json"
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
# #210: the Strimzi NetworkPolicy generated into cells is a valid NetworkPolicy (Kyverno fails the generate otherwise;
# kyverno test does not validate generated objects against their schema)
yq 'select(.kind == "NetworkPolicy" and .metadata.name == "platform-strimzi" and
  .metadata.namespace == "dp-default-demo-development-1234abcd")' "$cmg" > "$TMP/cm-strimzi-np.yaml"
assert_eq "$(kc_valid "$TMP/cm-strimzi-np.yaml")" yes "cell mesh: the generated platform-strimzi validates as a NetworkPolicy"
# #324: who gets into a cell. The generated AuthorizationPolicies replayed with Istio's L4 ALLOW semantics (ztunnel: a
# request passes when any rule matches; namespaces/principals need a peer identity, so plaintext never matches). No
# policy at all (before #324) admits every case below, so the "refused" lines are the negative security test.
yq -o=json -I=0 'select(.kind == "AuthorizationPolicy")' "$cmg" > "$TMP/cm-ap.json"
dev=dp-default-demo-development-1234abcd; prod=dp-default-demo-production-1234abcd; legacy=dp-default-demo-legacy-1234abcd
authz=$(python3 - "$TMP/cm-ap.json" "$dev:$dev/sa/default" "$dev:$dev/sa/r-orders-db" \
  "$dev:openchoreo-data-plane/sa/gateway-default" "$dev:telemetry/sa/openchoreo-prometheus-agent" "$dev:cnpg-system/sa/cnpg" \
  "$dev:moco-system/sa/moco-controller-manager" \
  "$dev:$prod/sa/default" "$dev:dp-default-other-development-1234abcd/sa/default" "$dev:telemetry/sa/fluent-bit" \
  "$dev:openchoreo-data-plane/sa/cluster-agent-dataplane" "$dev:plaintext" "$prod:$dev/sa/default" "$legacy:plaintext" <<'PY'
import fnmatch, json, sys
pols = {}
for line in open(sys.argv[1]):
    ap = json.loads(line)
    pols.setdefault(ap["metadata"]["namespace"], []).append(ap)
def source_ok(src, peer):  # peer: "<ns>/sa/<sa>" or None (plaintext)
    if not src:
        return True
    if peer is None:
        return False
    ns, principal = peer.split("/")[0], "cluster.local/ns/" + peer
    ok = True  # every field given must match (Istio "*" prefix/suffix wildcards ~ fnmatch)
    if "namespaces" in src:
        ok = any(fnmatch.fnmatchcase(ns, n) for n in src["namespaces"])
    if "principals" in src:
        ok = ok and any(fnmatch.fnmatchcase(principal, p) for p in src["principals"])
    return ok
def allowed(cell, peer):
    allow = [ap for ap in pols.get(cell, []) if ap["spec"].get("action", "ALLOW") == "ALLOW"]
    if not allow:  # no ALLOW policy: Istio admits everything
        return True
    return any(not r.get("from") or any(source_ok(f.get("source"), peer) for f in r["from"])
               for ap in allow for r in ap["spec"].get("rules", []))
for case in sys.argv[2:]:
    cell, peer = case.split(":", 1)
    print("admit" if allowed(cell, None if peer == "plaintext" else peer) else "refuse", end=" ")
PY
)
assert_eq "${authz% }" "admit admit admit admit admit admit refuse refuse refuse refuse refuse refuse admit" \
  "cell mesh: development admits its own workloads, gateway, telemetry agent, CNPG, MOCO; refuses production's and another project's workloads, other platform identities, plaintext; production refuses development; the permissive cell admits plaintext"
yq -P '.' <<<"$(head -1 "$TMP/cm-ap.json")" > "$TMP/cm-ap.yaml"
[[ -s "$SCHEMAS_DIR/security.istio.io/authorizationpolicy_v1.json" ]] || SCHEMAS_DIR="$SCHEMAS_DIR" "$ROOT/hack/schemas.sh" >/dev/null
assert_eq "$(kc_valid "$TMP/cm-ap.yaml")" yes "cell mesh: the generated AuthorizationPolicy validates against the Istio CRD schema"

finish
