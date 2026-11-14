#!/usr/bin/env bash
# Cross-chart contract tests: label agreement, catalog contracts, AppProjects, and bootstrap/GitOps alignment.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_gitops_contracts =="

helm template platform "$ROOT/charts/platform" --namespace argocd \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/platform.yaml"

# 1. mgmt cluster secret carries all selection labels + addons-revision annotation
for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation; do
  mgmt_v=$(yq "select(.kind == \"Secret\" and .metadata.name == \"in-cluster\") | .metadata.labels[\"$key\"]" "$TMP/platform.yaml")
  assert_nonempty "$mgmt_v" "in-cluster carries $key"
done
mgmt_rev=$(yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.annotations["platform.koorikla.io/addons-revision"]' "$TMP/platform.yaml")
assert_eq "$mgmt_rev" "HEAD" "in-cluster addons-revision defaults to HEAD"

# 2. If capi-cluster.yaml is present, verify cluster secret labels match CAPI Cluster labels
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  helm template cluster-dev1 "$ROOT/charts/cluster" --namespace fleet \
    --values "$ROOT/installations/local/installation.yaml" \
    --values "$ROOT/installations/local/clusters/dev1.yaml" > "$TMP/dev1.yaml"
  for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation platform.koorikla.io/cni addons.platform.koorikla.io/cilium; do
    capi_v=$(yq "select(.kind == \"Cluster\" and .metadata.name == \"dev1\") | .metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    wl_v=$(yq "select(.kind == \"ExternalSecret\" and .metadata.name == \"dev1-argocd-cluster\") | .spec.target.template.metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    assert_eq "$wl_v" "$capi_v" "dev1 argocd cluster label $key matches CAPI Cluster"
  done
fi

# 2b. networking: the cilium addon follows the cluster's cni and reaches the API server via the cluster secret's server
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  dev1_cni=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["platform.koorikla.io/cni"]' "$TMP/dev1.yaml")
  dev1_cil=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["addons.platform.koorikla.io/cilium"]' "$TMP/dev1.yaml")
  assert_eq "$dev1_cil" "$([[ "$dev1_cni" == cilium ]] && echo true || echo false)" "dev1 cilium addon label follows cni ($dev1_cni)"
fi
cil_params=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cilium") | .spec.template.spec.source.helm.parameters[] | .name + "=" + .value' "$TMP/platform.yaml")
assert_match "$cil_params" 'cilium.k8sServiceHost=\{\{ \(urlParse \.server\)\.hostname \}\}' "addon-cilium sets k8sServiceHost from the cluster server"
assert_match "$cil_params" 'cilium.k8sServicePort=.*urlParse \.server' "addon-cilium sets k8sServicePort from the cluster server"
cil_sel=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cilium") | .spec.generators[0].clusters.selector.matchExpressions[] | select(.key == "addons.platform.koorikla.io/cilium") | .operator' "$TMP/platform.yaml")
assert_eq "$cil_sel" "In" "addon-cilium is opt-in by label"
mgmt_cni=$(yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels["platform.koorikla.io/cni"]' "$TMP/platform.yaml")
assert_eq "$mgmt_cni" "flannel" "in-cluster (k3d mgmt) carries platform.koorikla.io/cni=flannel"

# 2c. Kyverno: the platform namespaces outside Kyverno's webhooks are exactly the ones the policies exclude
kyv_ns=$(yq -o=json -I=0 '.kyverno.config.webhooks.namespaceSelector.matchExpressions[0].values' "$ROOT/addons/kyverno/values.yaml")
kp_ns=$(yq -o=json -I=0 '.platformNamespaces' "$ROOT/addons/kyverno-policies/values.yaml")
assert_eq "$kp_ns" "$kyv_ns" "kyverno webhook exclusions == kyverno-policies platformNamespaces"
for ns in $(yq '.addons[].namespace' "$ROOT/charts/platform/values.yaml" | sort -u); do
  [[ "$ns" == default ]] && continue   # OpenChoreo org namespace on mgmt (CRs only), deliberately in scope
  assert_match "$kp_ns" "\"$ns\"" "catalog namespace $ns is a Kyverno-excluded platform namespace"
done

# 3. argo-cd ApplicationSet uses releaseName argo-cd and fullnameOverride argocd (matching bootstrap/bootstrap.sh)
argo_rel=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-argo-cd") | .spec.template.spec.source.helm.releaseName' "$TMP/platform.yaml")
assert_eq "$argo_rel" "argocd" "addon-argo-cd releaseName is argocd (= bootstrap helm release)"
argo_fn=$(yq '.argo-cd.fullnameOverride' "$ROOT/addons/argo-cd/values.yaml")
assert_eq "$argo_fn" "argocd" "addons/argo-cd fullnameOverride is argocd (matches bootstrap release)"

# 4. fleet ApplicationSet targets project fleet, charts/cluster, and uses ServerSideDiff=true
fleet_proj=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.project' "$TMP/platform.yaml")
fleet_path=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.source.path' "$TMP/platform.yaml")
fleet_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$fleet_proj" "fleet" "fleet appset uses project fleet"
assert_eq "$fleet_path" "charts/cluster" "fleet appset uses charts/cluster"
assert_eq "$fleet_ssd" "ServerSideDiff=true" "fleet appset enables ServerSideDiff"

# 5. Catalog alignment checks
odp_param=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-openchoreo-data-plane") | .spec.template.spec.source.helm.parameters[0].name' "$TMP/platform.yaml")
assert_eq "$odp_param" "openchoreo-data-plane.clusterAgent.planeID" "openchoreo-data-plane sets planeID parameter"
cc_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-clusterclasses") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$cc_ssd" "ServerSideDiff=true" "clusterclasses enables ServerSideDiff"
kgw_ns=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-kgateway") | .spec.template.spec.destination.namespace' "$TMP/platform.yaml")
assert_eq "$kgw_ns" "kgateway-system" "kgateway deploys into kgateway-system"
coredns_roles=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-coredns-local") | .spec.generators[0].clusters.selector.matchExpressions[] | select(.key == "platform.koorikla.io/role") | .values | join(",")' "$TMP/platform.yaml")
assert_eq "$coredns_roles" "mgmt,workload" "coredns-local targets mgmt and workload"

# 6. argo-cd PVC health Lua treats Pending as Healthy and server stays ClusterIP
helm template argo-cd "$ROOT/addons/argo-cd" --namespace argocd > "$TMP/argocd.yaml"
pvc_lua=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm") | .data["resource.customizations.health.PersistentVolumeClaim"]' "$TMP/argocd.yaml")
assert_match "$pvc_lua" 'Pending' "argocd-cm PVC health customization handles Pending"
svc_type=$(yq 'select(.kind == "Service" and .metadata.name == "argocd-server") | .spec.type' "$TMP/argocd.yaml")
assert_eq "$svc_type" "ClusterIP" "argocd-server Service stays ClusterIP"

# 7. secret-stores creates platform, mgmt-fleet, mgmt-openchoreo on mgmt and default on workload
helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets \
  --values "$ROOT/addons/secret-stores/values/role-mgmt.yaml" > "$TMP/ss-mgmt.yaml"
for s in platform mgmt-fleet mgmt-openchoreo; do
  found=$(yq "select(.kind == \"ClusterSecretStore\" and .metadata.name == \"$s\") | .metadata.name" "$TMP/ss-mgmt.yaml")
  assert_eq "$found" "$s" "mgmt secret-stores creates ClusterSecretStore $s"
done
helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets \
  --values "$ROOT/addons/secret-stores/values/role-workload.yaml" > "$TMP/ss-wl.yaml"
wl_store=$(yq 'select(.kind == "ClusterSecretStore" and .metadata.name == "default") | .metadata.name' "$TMP/ss-wl.yaml")
assert_eq "$wl_store" "default" "workload secret-stores creates ClusterSecretStore default"

# ClusterClass patches: CAPI's webhook rejects replace/remove ops on array elements (".../files/0/content"); the
# offline simulator does not, so guard it here for every installation's classes.
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  idx_paths=$(helm template cc "$ROOT/addons/clusterclasses" --values "$inst_file" 2>/dev/null \
    | yq 'select(.kind == "ClusterClass") | .spec.patches[].definitions[].jsonPatches[] | select(.op == "replace" or .op == "remove") | .path' \
    | grep -E '/[0-9]+(/|$)' || true)
  assert_eq "$idx_paths" "" "ClusterClass replace/remove patches avoid array indices ($(basename "$(dirname "$inst_file")"))"
done

finish
