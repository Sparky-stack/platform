#!/usr/bin/env bash
# Extract/fetch CRD manifests and generate kubeconform JSON schemas into SCHEMAS_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
CACHE_DIR="${SCHEMAS_DIR}/.crd-cache"
mkdir -p "$SCHEMAS_DIR" "$CACHE_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. Extract CRDs from local charts/addons (both crds/ dir and CRD templates)
idx=0
for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if grep -q '^dependencies:' "$dir/Chart.yaml" && [[ ! -d "$dir/charts" || -z "$(ls -A "$dir/charts" 2>/dev/null)" ]]; then
    helm dependency build "$dir" >/dev/null
  fi
  helm show crds "$dir" > "$TMP/crds-$idx.yaml" 2>/dev/null || true
  idx=$((idx + 1))

  # Some wrapper charts (e.g. gateway-api-crds, cert-manager crds.enabled=true, external-secrets installCRDs=true)
  # emit CustomResourceDefinitions from templates/ instead of crds/.
  if [[ -f "$dir/templates" || -d "$dir/templates" || -d "$dir/charts" ]]; then
    set_args=()
    if [[ "$(basename "$dir")" == "openchoreo-data-plane" ]]; then
      set_args+=(--set-string openchoreo-data-plane.clusterAgent.planeID=sample)
    fi
    if [[ "$(basename "$dir")" == "cloudnative-pg" ]]; then
      set_args+=(--set plugin-barman-cloud.enabled=true)   # ObjectStore CRD (optional Barman Cloud plugin, templates/)
    fi
    helm template schema-extract "$dir" ${set_args[@]+"${set_args[@]}"} 2>/dev/null | \
      yq 'select(.kind == "CustomResourceDefinition")' > "$TMP/crds-tpl-$idx.yaml" 2>/dev/null || true
    idx=$((idx + 1))
  fi
done

# 2. Fetch CAPI & provider CRDs (versions read from addons/capi-providers/values.yaml if present)
read_ver() {
  local path="$1" fallback="$2" v=""
  if [[ -f addons/capi-providers/values.yaml ]]; then
    v=$(yq "$path // \"\"" addons/capi-providers/values.yaml 2>/dev/null || true)
  fi
  echo "${v:-$fallback}"
}

CAPI_VER=$(read_ver '.core.version' 'v1.13.8')
K3S_VER=$(read_ver '.k3s.version' 'v0.5.0')
AWS_VER=$(read_ver '.infrastructure.aws.version' 'v2.13.1')
HZ_VER=$(read_ver '.infrastructure.hetzner.version' 'v1.1.12')

fetch_crd() {
  local name="$1" url="$2"
  local dest="$CACHE_DIR/${name}.yaml"
  if [[ -s "$dest" ]]; then
    return 0
  fi
  if curl -fsSL "$url" -o "${dest}.tmp" 2>/dev/null; then
    mv "${dest}.tmp" "$dest"
  else
    rm -f "${dest}.tmp"
    echo "WARN: failed to fetch $name CRDs from $url" >&2
  fi
}

fetch_crd "capi-${CAPI_VER}" "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VER}/cluster-api-components.yaml"
fetch_crd "capd-${CAPI_VER}" "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CAPI_VER}/infrastructure-components-development.yaml"
fetch_crd "k3s-bootstrap-${K3S_VER}" "https://github.com/k3s-io/cluster-api-k3s/releases/download/${K3S_VER}/bootstrap-components.yaml"
fetch_crd "k3s-cp-${K3S_VER}" "https://github.com/k3s-io/cluster-api-k3s/releases/download/${K3S_VER}/control-plane-components.yaml"
fetch_crd "capa-${AWS_VER}" "https://github.com/kubernetes-sigs/cluster-api-provider-aws/releases/download/${AWS_VER}/infrastructure-components.yaml"
fetch_crd "caph-${HZ_VER}" "https://github.com/syself/cluster-api-provider-hetzner/releases/download/${HZ_VER}/infrastructure-components.yaml"
# Argo Workflows CRDs: the OpenChoreo workflow plane chart installs them from a hook Job (not extractable above).
# v4.0.8 = argo-workflows appVersion in openchoreo-workflow-plane 1.3.3 (chart dependency argo-workflows 1.0.23).
AWF_VER=v4.0.8
for crd in workflows workflowtemplates; do
  fetch_crd "argo-workflows-${AWF_VER}-${crd}" "https://raw.githubusercontent.com/argoproj/argo-workflows/${AWF_VER}/manifests/base/crds/full/argoproj.io_${crd}.yaml"
done
fetch_crd "prometheus-servicemonitor" "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"

# Crossplane v2 installs its CRDs from its init container (not in the chart), the upjet providers bring theirs with the
# package: fetch the ones addon crossplane and its PostgreSQL Compositions use, at the versions pinned there.
xp_tag() {   # xp_tag <yq path to a package ref in addons/crossplane/values.yaml> -> its tag (v1.2.3)
  local ref
  ref=$(yq -r "$1" addons/crossplane/values.yaml | tr -d '\r')
  ref=${ref%@*}
  echo "${ref##*:}"
}
if [[ -f addons/crossplane/values.yaml ]]; then
  XP_VER=$(yq -r '.crossplane.image.tag' addons/crossplane/values.yaml | tr -d '\r')
  XP_VER=${XP_VER%@*}
  for crd in apiextensions.crossplane.io_compositions apiextensions.crossplane.io_compositeresourcedefinitions \
    apiextensions.crossplane.io_managedresourceactivationpolicies pkg.crossplane.io_functions pkg.crossplane.io_providers \
    pkg.crossplane.io_deploymentruntimeconfigs; do
    fetch_crd "crossplane-${XP_VER}-${crd}" "https://raw.githubusercontent.com/crossplane/crossplane/${XP_VER}/cluster/crds/${crd}.yaml"
  done
  # <repo>|<tag>|<crd file>...  (only what the Compositions compose + the family's ClusterProviderConfig)
  for spec in \
    "provider-upjet-aws|$(xp_tag '.packages.providers["aws-rds"]["provider-aws-rds"]')|aws.m.upbound.io_clusterproviderconfigs rds.aws.m.upbound.io_instances rds.aws.m.upbound.io_clusters rds.aws.m.upbound.io_clusterinstances rds.aws.m.upbound.io_subnetgroups ec2.aws.m.upbound.io_securitygroups ec2.aws.m.upbound.io_securitygroupingressrules kms.aws.m.upbound.io_keys" \
    "provider-upjet-gcp|$(xp_tag '.packages.providers["gcp-cloudsql"]["provider-gcp-sql"]')|gcp.m.upbound.io_clusterproviderconfigs sql.gcp.m.upbound.io_databaseinstances sql.gcp.m.upbound.io_databases sql.gcp.m.upbound.io_users" \
    "provider-upjet-azure|$(xp_tag '.packages.providers["azure-flexible"]["provider-azure-dbforpostgresql"]')|azure.m.upbound.io_clusterproviderconfigs dbforpostgresql.azure.m.upbound.io_flexibleservers dbforpostgresql.azure.m.upbound.io_flexibleserverdatabases"; do
    IFS='|' read -r repo tag files <<<"$spec"
    for crd in $files; do
      fetch_crd "${repo}-${tag}-${crd}" "https://raw.githubusercontent.com/crossplane-contrib/${repo}/${tag}/package/crds/${crd}.yaml"
    done
  done
  # The CRD Crossplane derives from the PostgreSQL XRD (Crossplane adds spec.crossplane and status.conditions), so XRs
  # (docs examples, hack/tests/crossplane) validate like any custom resource.
  helm template schema-extract addons/crossplane -s templates/xrd-postgresql.yaml 2>/dev/null | yq '{
    "apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition", "metadata": {"name": .metadata.name},
    "spec": {"group": .spec.group, "names": .spec.names, "scope": .spec.scope, "versions": [.spec.versions[] | {
      "name": .name, "served": true, "storage": true, "schema": {"openAPIV3Schema": {"type": "object", "properties": {
        "apiVersion": {"type": "string"}, "kind": {"type": "string"}, "metadata": {"type": "object"},
        "spec": (.schema.openAPIV3Schema.properties.spec * {"properties": {"crossplane": {"type": "object",
          "x-kubernetes-preserve-unknown-fields": true}}}),
        "status": (.schema.openAPIV3Schema.properties.status * {"properties": {"conditions": {"type": "array",
          "items": {"type": "object", "x-kubernetes-preserve-unknown-fields": true}}}})}}}}]}}' > "$TMP/crds-xrd-postgresql.yaml" 2>/dev/null || true
fi

crd_files=()
for f in "$TMP"/*.yaml "$CACHE_DIR"/*.yaml; do
  [[ -s "$f" ]] && crd_files+=("$f")
done

if (( ${#crd_files[@]} > 0 )); then
  pick_python || { echo "missing required tool: python3 (>= 3.8)" >&2; exit 1; }
  "$PYTHON" hack/crd2schema.py "$SCHEMAS_DIR" "${crd_files[@]}"
fi
