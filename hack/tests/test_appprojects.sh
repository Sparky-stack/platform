#!/usr/bin/env bash
# Verify AppProjects (platform & fleet) admit every resource deployed by charts/cluster and addons/*.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_appprojects =="

helm template platform "$ROOT/charts/platform" --namespace argocd \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/platform.yaml"

check_fleet_allows() {
  local group="$1" kind="$2" ns="$3"
  local match
  if [[ -z "$ns" ]]; then
    match=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"fleet\") | .spec.clusterResourceWhitelist[] | select(.group == \"$group\" and .kind == \"$kind\") | .kind" "$TMP/platform.yaml")
    assert_eq "$match" "$kind" "fleet AppProject admits cluster-scoped $group/$kind"
  else
    local dest_ok
    dest_ok=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"fleet\") | .spec.destinations[] | select(.namespace == \"$ns\" or .namespace == \"*\") | .namespace" "$TMP/platform.yaml" | sed -n '1p')
    assert_nonempty "$dest_ok" "fleet AppProject allows destination namespace $ns"
    match=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"fleet\") | .spec.namespaceResourceWhitelist[] | select(.group == \"$group\" and .kind == \"$kind\") | .kind" "$TMP/platform.yaml")
    assert_eq "$match" "$kind" "fleet AppProject admits namespaced $group/$kind in $ns"
  fi
}

# Required resources for charts/cluster
check_fleet_allows "" "Namespace" ""
check_fleet_allows "openchoreo.dev" "ClusterDataPlane" ""
check_fleet_allows "cluster.x-k8s.io" "Cluster" "fleet"
check_fleet_allows "addons.cluster.x-k8s.io" "ClusterResourceSet" "fleet"
check_fleet_allows "cert-manager.io" "Issuer" "fleet"
check_fleet_allows "cert-manager.io" "Certificate" "fleet"
check_fleet_allows "external-secrets.io" "ExternalSecret" "fleet"
check_fleet_allows "external-secrets.io" "ExternalSecret" "argocd"
check_fleet_allows "openchoreo.dev" "Environment" "default"

# Platform AppProject admits all namespaces and cluster-scoped kinds
plat_dest=$(yq 'select(.kind == "AppProject" and .metadata.name == "platform") | .spec.destinations[] | select(.server == "*" and .namespace == "*") | .namespace' "$TMP/platform.yaml")
plat_crw=$(yq 'select(.kind == "AppProject" and .metadata.name == "platform") | .spec.clusterResourceWhitelist[] | select(.group == "*" and .kind == "*") | .kind' "$TMP/platform.yaml")
assert_eq "$plat_dest" "*" "platform AppProject allows all destination namespaces"
assert_eq "$plat_crw" "*" "platform AppProject allows all cluster-scoped kinds"

# examples AppProject admits every resource the enabled example charts render, and nothing cluster-wide but Namespace
for ex_dir in "$ROOT"/examples/*; do
  [[ -f "$ex_dir/Chart.yaml" ]] || continue
  ex=$(basename "$ex_dir")
  [[ "$(yq ".examples[\"$ex\"].enabled // false" "$ROOT/installations/local/installation.yaml")" == "true" ]] || continue
  helm template "$ex" "$ex_dir" > "$TMP/example-$ex.yaml"
  while IFS=$'\t' read -r api kind ns; do
    [[ -n "$kind" ]] || continue
    group=${api%/*}; [[ "$api" == */* ]] || group=""
    if [[ "$kind" == Namespace ]]; then
      m=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"examples\") | .spec.clusterResourceWhitelist[] | select(.group == \"\" and .kind == \"Namespace\") | .kind" "$TMP/platform.yaml")
      assert_eq "$m" "Namespace" "examples AppProject admits the $ex Namespace"
      continue
    fi
    m=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"examples\") | .spec.namespaceResourceWhitelist[] | select(.group == \"$group\" and .kind == \"$kind\") | .kind" "$TMP/platform.yaml")
    assert_eq "$m" "$kind" "examples AppProject admits $ex $group/$kind"
    d=$(yq "select(.kind == \"AppProject\" and .metadata.name == \"examples\") | .spec.destinations[] | select(.namespace == \"$ns\") | .namespace" "$TMP/platform.yaml")
    assert_eq "$d" "$ns" "examples AppProject allows destination namespace $ns"
  done < <(yq -N '[.apiVersion, .kind, (.metadata.namespace // "")] | @tsv' "$TMP/example-$ex.yaml")
done
ex_crw=$(yq -o=json -I=0 'select(.kind == "AppProject" and .metadata.name == "examples") | .spec.clusterResourceWhitelist' "$TMP/platform.yaml")
assert_eq "$ex_crw" '[{"group":"","kind":"Namespace"}]' "examples AppProject: Namespace is the only cluster-scoped kind"
ex_wild=$(yq 'select(.kind == "AppProject" and .metadata.name == "examples") | .spec.destinations[] | select(.namespace | test("^[*]$")) | .namespace' "$TMP/platform.yaml")
assert_eq "$ex_wild" "" "examples AppProject has no wildcard destination namespace"
ex_proj=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "example-eastwest") | .spec.template.spec.project' "$TMP/platform.yaml")
assert_eq "$ex_proj" "examples" "example ApplicationSets use AppProject examples, not platform"

finish
