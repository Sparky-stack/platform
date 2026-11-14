#!/usr/bin/env bash
# Full offline test suite: deps (cached), helm lint, template across all installations/clusters,
# kubeconform -strict with CRD schemas, helm unittest, and contract tests.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in helm yq kubeconform; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done

# 1. Build deps (cached) before linting, templating, schemas, or helm unittest
for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if grep -q '^dependencies:' "$dir/Chart.yaml" && [[ ! -d "$dir/charts" || -z "$(ls -A "$dir/charts" 2>/dev/null)" ]]; then
    echo "==> helm dependency build $dir"
    helm dependency build "$dir" >/dev/null
  fi
done

./hack/schemas.sh

SCHEMAS="hack/schemas"
KUBECONFORM_ARGS=(
  -strict
  -summary
  -schema-location default
  -schema-location "$SCHEMAS/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

check_kubeconform() {
  local label="$1" file="$2" out
  if [[ ! -s "$file" ]]; then
    echo "  PASS $label (0 documents)"
    return 0
  fi
  if ! out=$(kubeconform "${KUBECONFORM_ARGS[@]}" "$file" 2>&1); then
    echo "  FAIL $label: kubeconform failed:" >&2
    echo "$out" >&2
    return 1
  fi
  echo "  PASS $label ($out)"
}

# 2. Lint every chart in charts/ and addons/ (charts/cluster linted per cluster below)
for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if [[ "$dir" != "charts/cluster" ]]; then
    echo "==> helm lint $dir"
    helm lint "$dir" >/dev/null
  fi
done

# 3. Render + kubeconform charts/platform for standalone + every installation
echo "==> Testing charts/platform"
helm template platform charts/platform --namespace argocd > "$TMP/platform-standalone.yaml"
check_kubeconform "charts/platform (standalone)" "$TMP/platform-standalone.yaml"
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  helm lint charts/platform --values "$inst_dir/installation.yaml" >/dev/null
  helm template platform charts/platform --namespace argocd --values "$inst_dir/installation.yaml" > "$TMP/platform-$inst.yaml"
  check_kubeconform "charts/platform ($inst)" "$TMP/platform-$inst.yaml"
done

# 4. Render + kubeconform charts/cluster for every installation x cluster file
echo "==> Testing charts/cluster"
if [[ -f charts/cluster/templates/capi-cluster.yaml ]]; then
  for inst_dir in installations/*; do
    [[ -f "$inst_dir/installation.yaml" ]] || continue
    inst=$(basename "$inst_dir")
    for cf in "$inst_dir"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      cname=$(yq '.name' "$cf")
      helm lint charts/cluster --values "$inst_dir/installation.yaml" --values "$cf" >/dev/null
      helm template "cluster-$cname" charts/cluster --namespace fleet \
        --values "$inst_dir/installation.yaml" --values "$cf" > "$TMP/cluster-$inst-$cname.yaml"
      check_kubeconform "charts/cluster ($inst/$cname)" "$TMP/cluster-$inst-$cname.yaml"
    done
  done
else
  echo "  SKIP charts/cluster (capi-cluster.yaml not present on this branch)"
fi

# 5. Render + kubeconform every addon in addons/* (standalone + layered per installation/role/cluster)
echo "==> Testing addons/*"
for dir in addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  addon=$(basename "$dir")
  ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" charts/platform/values.yaml)

  mapfile -t cn_params < <(yq ".addons[\"$addon\"].clusterNameParameters[]?" charts/platform/values.yaml || true)
  standalone_sets=()
  for p in "${cn_params[@]}"; do
    [[ -n "$p" ]] && standalone_sets+=(--set-string "${p}=sample")
  done

  helm template "$addon" "$dir" --namespace "$ns" "${standalone_sets[@]}" > "$TMP/addon-$addon-standalone.yaml"
  check_kubeconform "addons/$addon (standalone)" "$TMP/addon-$addon-standalone.yaml"

  roles_raw=$(yq ".addons[\"$addon\"].roles[]?" charts/platform/values.yaml || true)
  [[ -n "$roles_raw" ]] || roles_raw=$'mgmt\nworkload'
  providers_filter=$(yq ".addons[\"$addon\"].providers[]?" charts/platform/values.yaml || true)

  for inst_dir in installations/*; do
    [[ -f "$inst_dir/installation.yaml" ]] || continue
    inst=$(basename "$inst_dir")
    if echo "$roles_raw" | grep -qx 'mgmt'; then
      m_name=$(yq '.mgmt.name // "mgmt"' "$inst_dir/installation.yaml")
      m_prov=$(yq '.mgmt.provider // "docker"' "$inst_dir/installation.yaml")
      m_reg=$(yq '.mgmt.region // "local"' "$inst_dir/installation.yaml")
      m_env=$(yq '.mgmt.environment // "mgmt"' "$inst_dir/installation.yaml")
      if [[ -z "$providers_filter" ]] || echo "$providers_filter" | grep -qx "$m_prov"; then
        vargs=(--values "$inst_dir/installation.yaml")
        for vf in \
          "$dir/values/role-mgmt.yaml" \
          "$dir/values/provider-$m_prov.yaml" \
          "$inst_dir/addons/$addon/values.yaml" \
          "$inst_dir/addons/$addon/env-$m_env.yaml" \
          "$inst_dir/addons/$addon/cluster-$m_name.yaml"; do
          [[ -f "$vf" ]] && vargs+=(--values "$vf")
        done
        for p in "${cn_params[@]}"; do
          [[ -n "$p" ]] && vargs+=(--set-string "${p}=$m_name")
        done
        helm template "$addon-$m_name" "$dir" --namespace "$ns" "${vargs[@]}" \
          --set-string "cluster.name=$m_name" \
          --set-string "cluster.role=mgmt" \
          --set-string "cluster.provider=$m_prov" \
          --set-string "cluster.region=$m_reg" \
          --set-string "cluster.environment=$m_env" > "$TMP/addon-$addon-$inst-mgmt.yaml"
        check_kubeconform "addons/$addon ($inst/mgmt)" "$TMP/addon-$addon-$inst-mgmt.yaml"
      fi
    fi

    if echo "$roles_raw" | grep -qx 'workload'; then
      for cf in "$inst_dir"/clusters/*.yaml; do
        [[ -f "$cf" ]] || continue
        c_name=$(yq '.name' "$cf")
        c_prov=$(yq '.provider // "docker"' "$cf")
        c_reg=$(yq '.region // "local"' "$cf")
        c_env=$(yq '.environment // "development"' "$cf")
        if [[ -n "$providers_filter" ]] && ! echo "$providers_filter" | grep -qx "$c_prov"; then
          continue
        fi
        vargs=(--values "$inst_dir/installation.yaml")
        for vf in \
          "$dir/values/role-workload.yaml" \
          "$dir/values/provider-$c_prov.yaml" \
          "$inst_dir/addons/$addon/values.yaml" \
          "$inst_dir/addons/$addon/env-$c_env.yaml" \
          "$inst_dir/addons/$addon/cluster-$c_name.yaml"; do
          [[ -f "$vf" ]] && vargs+=(--values "$vf")
        done
        for p in "${cn_params[@]}"; do
          [[ -n "$p" ]] && vargs+=(--set-string "${p}=$c_name")
        done
        helm template "$addon-$c_name" "$dir" --namespace "$ns" "${vargs[@]}" \
          --set-string "cluster.name=$c_name" \
          --set-string "cluster.role=workload" \
          --set-string "cluster.provider=$c_prov" \
          --set-string "cluster.region=$c_reg" \
          --set-string "cluster.environment=$c_env" > "$TMP/addon-$addon-$inst-$c_name.yaml"
        check_kubeconform "addons/$addon ($inst/$c_name)" "$TMP/addon-$addon-$inst-$c_name.yaml"
      done
    fi
  done
done

# 6. Static manifests
echo "==> Validating bootstrap/root-app.yaml"
check_kubeconform "bootstrap/root-app.yaml" bootstrap/root-app.yaml

# 7. helm unittest where tests/ exists (after helm dependency build above)
passed=0
failed=0
for dir in charts/* addons/*; do
  [[ -d "$dir/tests" ]] || continue
  if [[ "$dir" == "charts/cluster" && ! -f "$dir/templates/capi-cluster.yaml" ]]; then
    echo "==> SKIP helm unittest $dir (capi-cluster.yaml not present on this branch)"
    continue
  fi
  echo "==> helm unittest $dir"
  if helm unittest "$dir"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

# 8. Contract & invariant tests in hack/tests/test_*.sh
for t in hack/tests/test_*.sh; do
  [[ -f "$t" ]] || continue
  if bash "$t"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo
echo "$passed suite(s) passed, $failed failed"
(( failed == 0 ))
