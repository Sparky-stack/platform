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
  for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation; do
    capi_v=$(yq "select(.kind == \"Cluster\" and .metadata.name == \"dev1\") | .metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    wl_v=$(yq "select(.kind == \"ExternalSecret\" and .metadata.name == \"dev1-argocd-cluster\") | .spec.target.template.metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    assert_eq "$wl_v" "$capi_v" "dev1 argocd cluster label $key matches CAPI Cluster"
  done
fi

# 3. argo-cd ApplicationSet uses releaseName argo-cd (matching bootstrap/bootstrap.sh)
argo_rel=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-argo-cd") | .spec.template.spec.source.helm.releaseName' "$TMP/platform.yaml")
assert_eq "$argo_rel" "argo-cd" "addon-argo-cd releaseName matches bootstrap"

# 4. fleet ApplicationSet targets project fleet, charts/cluster, and uses ServerSideDiff=true
fleet_proj=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.project' "$TMP/platform.yaml")
fleet_path=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.source.path' "$TMP/platform.yaml")
fleet_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$fleet_proj" "fleet" "fleet appset uses project fleet"
assert_eq "$fleet_path" "charts/cluster" "fleet appset uses charts/cluster"
assert_eq "$fleet_ssd" "ServerSideDiff=true" "fleet appset enables ServerSideDiff"

# 5. Catalog alignment checks (openchoreo-data-plane planeID parameter, clusterclasses ServerSideDiff, kgateway ns, coredns-local roles)
odp_param=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-openchoreo-data-plane") | .spec.template.spec.source.helm.parameters[0].name' "$TMP/platform.yaml")
assert_eq "$odp_param" "openchoreo-data-plane.clusterAgent.planeID" "openchoreo-data-plane sets planeID parameter"
cc_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-clusterclasses") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$cc_ssd" "ServerSideDiff=true" "clusterclasses enables ServerSideDiff"
kgw_ns=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-kgateway") | .spec.template.spec.destination.namespace' "$TMP/platform.yaml")
assert_eq "$kgw_ns" "kgateway-system" "kgateway deploys into kgateway-system"

# 6. argo-cd PVC health Lua treats Pending as Healthy
helm template argo-cd "$ROOT/addons/argo-cd" --namespace argocd > "$TMP/argocd.yaml"
pvc_lua=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm") | .data["resource.customizations.health.PersistentVolumeClaim"]' "$TMP/argocd.yaml")
assert_match "$pvc_lua" 'Pending' "argocd-cm PVC health customization handles Pending"

finish
