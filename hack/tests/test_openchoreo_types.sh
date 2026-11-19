#!/usr/bin/env bash
# OpenChoreo types of addon openchoreo-platform vs what data planes can do (#70, docs/data-services.md
# "Consuming them from OpenChoreo"; checks in hack/tests/openchoreo_types.py):
#   - every kind a ClusterComponentType / ClusterTrait / ClusterResourceType renders onto the data plane is granted to the
#     data-plane cluster agent (addon openchoreo-data-plane: upstream ClusterRole + templates/cluster-agent-data-services.yaml),
#     e.g. keda-scaler's ScaledObject and postgresql's PostgreSQL XR (missing before #70: the agent's apply was forbidden)
#   - platform.koorikla.io/requires-addons names opt-in workload addons of the catalog; ClusterTraits check each in a
#     preRenderValidation on dataplane.annotations; ClusterResourceTypes are checked on mgmt by the Kyverno policy
#     platform-data-plane-capabilities (rendered for the mgmt role); no type renders a raw CNPG object
#   - the ClusterDataPlane of local/dev1 announces the addons the types need (fleet file -> annotations)
#   - the agent's capability gate (#246) waits for the CRD of every kind a ClusterTrait's required addon brings
# Negatives: without the data-services RBAC the ScaledObject and XR are reported; a trait that drops its check and a type
# requiring a default-on addon are reported.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_openchoreo_types =="
cd "$ROOT"
ocp=addons/openchoreo-platform
dpa=addons/openchoreo-data-plane
agent_ns=openchoreo-data-plane
[[ -d "$dpa/charts" ]] || helm dependency build "$dpa" >/dev/null

helm template openchoreo-platform "$ocp" --namespace openchoreo-control-plane | yq -o=json -I=0 '.' > "$TMP/plat.jsonl"
helm template openchoreo-data-plane "$dpa" --namespace "$agent_ns" > "$TMP/dp.yaml"
yq -o=json -I=0 '.' "$TMP/dp.yaml" > "$TMP/dp.jsonl"
agent_sa=$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cluster-agent-dataplane") | .spec.template.spec.serviceAccountName' "$TMP/dp.yaml")
assert_eq "$agent_sa" "$(yq -r '.clusterAgentDataServices.serviceAccount' "$dpa/values.yaml" | tr -d '\r')" \
  "clusterAgentDataServices.serviceAccount is the agent Deployment's ServiceAccount"
yq -o=json '.addons' charts/platform/values.yaml > "$TMP/catalog.json"

# Capability gate (#246): render the data plane with every capabilityGate addon on (as on a cluster opting into all).
gate_on=$(yq -r '.capabilityGate.addons | keys | map("capabilityGate.addons." + . + ".enabled=true") | join(",")' "$dpa/values.yaml" | tr -d '\r')
helm template openchoreo-data-plane "$dpa" --namespace "$agent_ns" --set "$gate_on" | yq -o=json -I=0 '.' > "$TMP/dp-gated.jsonl"

check() { py hack/tests/openchoreo_types.py "$1" "$2" "$agent_ns/$agent_sa" "$TMP/catalog.json" "${3:-$TMP/dp-gated.jsonl}"; }
out=$(check "$TMP/plat.jsonl" "$TMP/dp.jsonl")
assert_eq "$(printf '%s\n' "$out" | grep '^VIOLATION' || true)" "" "platform types vs data-plane agent: no violation"
for ok in 'agent may apply keda.sh/scaledobjects for ClusterTrait keda-scaler' \
  'agent may apply platform.koorikla.io/postgresqls for ClusterResourceType postgresql' \
  'agent may apply apps/deployments for ClusterComponentType service' \
  'ClusterTrait keda-scaler requires opt-in workload addon keda' 'ClusterTrait keda-scaler checks addons.platform.koorikla.io/keda' \
  'ClusterResourceType postgresql requires opt-in workload addon crossplane' \
  'agent waits for crd/scaledobjects.keda.sh of ClusterTrait keda-scaler'; do
  assert_match "$out" "OK $ok" "$ok"
done

# ResourceTypes cannot check dataplane.annotations in OpenChoreo 1.3.3: mgmt's admission policy does.
helm template kyverno-policies addons/kyverno-policies --namespace kyverno -f addons/kyverno-policies/values/role-mgmt.yaml \
  -s templates/data-plane-capabilities.yaml > "$TMP/dpc.yaml"
assert_eq "$(yq -N 'select(.kind == "ValidatingPolicy") | .metadata.name' "$TMP/dpc.yaml")" platform-data-plane-capabilities \
  "mgmt renders ValidatingPolicy platform-data-plane-capabilities (ResourceType requirements)"
assert_match "$(yq -N 'select(.kind == "ValidatingPolicy") | .spec.variables[] | select(.name == "required") | .expression' "$TMP/dpc.yaml")" \
  "platform.koorikla.io/requires-addons" "the policy reads platform.koorikla.io/requires-addons"

# The local data plane announces what the types need.
render_cluster local dev1 "$TMP/dev1.yaml"
for a in keda crossplane; do
  assert_eq "$(yq -N "select(.kind == \"ClusterDataPlane\") | .metadata.annotations[\"addons.platform.koorikla.io/$a\"]" "$TMP/dev1.yaml")" \
    true "ClusterDataPlane dev1 announces addon $a"
done

# Negatives
helm template openchoreo-data-plane "$dpa" --namespace "$agent_ns" --set clusterAgentDataServices.enabled=false \
  | yq -o=json -I=0 '.' > "$TMP/dp-upstream.jsonl"
out=$(check "$TMP/plat.jsonl" "$TMP/dp-upstream.jsonl")
assert_match "$out" "VIOLATION: ClusterTrait keda-scaler renders ScaledObject \(keda.sh/v1alpha1\) but the data-plane agent $agent_ns/$agent_sa lacks" \
  "upstream agent RBAC alone: keda-scaler's ScaledObject is reported"
assert_match "$out" "VIOLATION: ClusterResourceType postgresql renders PostgreSQL \(platform.koorikla.io/v1alpha1\) but the data-plane agent" \
  "upstream agent RBAC alone: postgresql's XR is reported"
# Without the gate the first apply of a ScaledObject can beat addon keda to the cluster (#246).
helm template openchoreo-data-plane "$dpa" --namespace "$agent_ns" | yq -o=json -I=0 '.' > "$TMP/dp-ungated.jsonl"
out=$(check "$TMP/plat.jsonl" "$TMP/dp.jsonl" "$TMP/dp-ungated.jsonl")
assert_match "$out" 'VIOLATION: no capability-gate Sync hook before the agent Deployment' "no gate rendered: reported"
assert_match "$out" 'VIOLATION: ClusterTrait keda-scaler renders ScaledObject \(keda.sh/v1alpha1\) but the capability gate does not wait for crd/scaledobjects.keda.sh' \
  "a trait kind the gate does not wait for is reported"
cat > "$TMP/bad.jsonl" <<'EOF'
{"apiVersion":"openchoreo.dev/v1alpha1","kind":"ClusterTrait","metadata":{"name":"unchecked","annotations":{"platform.koorikla.io/requires-addons":"keda"}},"spec":{"preRenderValidations":[{"rule":"${true}","message":"x"}]}}
{"apiVersion":"openchoreo.dev/v1alpha1","kind":"ClusterResourceType","metadata":{"name":"rawpg","annotations":{"platform.koorikla.io/requires-addons":"cert-manager, nosuch"}},"spec":{"resources":[{"id":"c","template":{"apiVersion":"postgresql.cnpg.io/v1","kind":"Cluster"}}]}}
EOF
out=$(check "$TMP/bad.jsonl" "$TMP/dp.jsonl")
assert_match "$out" 'VIOLATION: ClusterTrait unchecked requires keda but no preRenderValidation checks' "a trait without its annotation check is reported"
assert_match "$out" 'VIOLATION: ClusterResourceType rawpg renders raw Cluster \(postgresql.cnpg.io/v1\)' "a raw CNPG Cluster is reported"
assert_match "$out" 'VIOLATION: ClusterResourceType rawpg requires addon cert-manager, which is on by default' "a default-on requirement is reported"
assert_match "$out" 'VIOLATION: ClusterResourceType rawpg requires addon nosuch, which is not in the catalog' "an unknown addon is reported"
assert_match "$out" 'VIOLATION: ClusterResourceType rawpg renders Cluster \(postgresql.cnpg.io/v1\) but the data-plane agent' \
  "a kind the agent may not apply is reported"

finish
