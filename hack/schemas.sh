#!/usr/bin/env bash
# Extract/fetch CRD manifests and generate kubeconform JSON schemas into SCHEMAS_DIR.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEMAS_DIR="${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}"
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
    helm template schema-extract "$dir" "${set_args[@]}" 2>/dev/null | \
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
fetch_crd "prometheus-servicemonitor" "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"

crd_files=()
for f in "$TMP"/*.yaml "$CACHE_DIR"/*.yaml; do
  [[ -s "$f" ]] && crd_files+=("$f")
done

if (( ${#crd_files[@]} > 0 )); then
  python3 hack/crd2schema.py "$SCHEMAS_DIR" "${crd_files[@]}"
fi
