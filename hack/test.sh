#!/usr/bin/env bash
# Full offline test suite: deps (cached), helm lint, template across all installations/clusters,
# kubeconform -strict with CRD schemas, helm unittest, and contract tests.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

for bin in helm yq kubeconform; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done
pick_python || { echo "missing required tool: python3 (>= 3.8)" >&2; exit 1; }

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
export SCHEMAS_DIR

# 1. Build deps (cached) before linting, templating, schemas, or helm unittest
./hack/deps.sh

./hack/schemas.sh

KUBECONFORM_ARGS=(
  -strict
  -summary
  -kubernetes-version 1.35.0
  -skip CustomResourceDefinition
  -schema-location default
  -schema-location "$SCHEMAS_DIR/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Catalog clusterServerParameters (<helm param>: url|host|port of the Argo cluster secret's server), mirrored from
# charts/platform/templates/appset-addons.yaml. Prints helm args for the given addon and server URL.
server_param_args() {
  local addon="$1" server="$2" p part v
  while IFS=$'\t' read -r p part; do
    [[ -n "$p" ]] || continue
    v=$(py -c 'import sys,urllib.parse as u;s=sys.argv[1];x=u.urlsplit(s);print({"url":s,"host":x.hostname,"port":x.port or 443}[sys.argv[2]])' "$server" "$part")
    if [[ "$part" == "port" ]]; then printf '%s\n' --set "${p}=${v}"; else printf '%s\n' --set-string "${p}=${v}"; fi
  done < <(yq -r ".addons[\"$addon\"].clusterServerParameters // {} | to_entries[] | [.key, .value] | @tsv" charts/platform/values.yaml)
}
# Catalog clusterLabelParameters (<helm param>: {label, default}), mirrored from appset-addons.yaml. Prints helm args
# for the given addon from a file holding the cluster's labels as a YAML map (missing/empty file -> the defaults).
label_param_args() {
  local addon="$1" labels="$2" p key def v
  while IFS=$'\t' read -r p key def; do
    [[ -n "$p" ]] || continue
    v=""
    if [[ -s "$labels" ]]; then v=$(yq -r ".[\"$key\"] // \"\"" "$labels"); fi
    [[ -n "$v" ]] || v="$def"
    printf '%s\n' --set-string "${p}=${v}"
  done < <(yq -r ".addons[\"$addon\"].clusterLabelParameters // {} | to_entries[] | [.key, .value.label, (.value.default // \"\")] | @tsv" charts/platform/values.yaml | tr -d '\r')
}
NO_LABELS=/dev/null                          # standalone renders: no cluster labels -> catalog defaults
SAMPLE_SERVER=https://192.0.2.10:6443        # stands in for a workload cluster's CAPI API endpoint (TEST-NET-1)
MGMT_SERVER=https://kubernetes.default.svc   # = charts/platform cluster-mgmt.yaml

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
    lint_sets=()
    read_lines lint_sets server_param_args "$(basename "$dir")" "$SAMPLE_SERVER"
    lp_args=()
    read_lines lp_args label_param_args "$(basename "$dir")" "$NO_LABELS"
    lint_sets+=(${lp_args[@]+"${lp_args[@]}"})
    helm lint "$dir" ${lint_sets[@]+"${lint_sets[@]}"} >/dev/null
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

  cn_params=()
  read_lines cn_params yq ".addons[\"$addon\"].clusterNameParameters[]?" charts/platform/values.yaml
  standalone_sets=()
  for p in ${cn_params[@]+"${cn_params[@]}"}; do
    [[ -n "$p" ]] && standalone_sets+=(--set-string "${p}=sample" --set-string cluster.name=sample)
  done
  sp_args=()
  read_lines sp_args server_param_args "$addon" "$SAMPLE_SERVER"
  standalone_sets+=(${sp_args[@]+"${sp_args[@]}"})
  lp_args=()
  read_lines lp_args label_param_args "$addon" "$NO_LABELS"
  standalone_sets+=(${lp_args[@]+"${lp_args[@]}"})

  helm template "$addon" "$dir" --namespace "$ns" ${standalone_sets[@]+"${standalone_sets[@]}"} > "$TMP/addon-$addon-standalone.yaml"
  check_kubeconform "addons/$addon (standalone)" "$TMP/addon-$addon-standalone.yaml"

  roles_raw=$(yq ".addons[\"$addon\"].roles[]?" charts/platform/values.yaml || true)
  [[ -n "$roles_raw" ]] || roles_raw=$'mgmt\nworkload'
  providers_filter=$(yq ".addons[\"$addon\"].providers[]?" charts/platform/values.yaml || true)
  addon_default=$(yq ".addons[\"$addon\"].default" charts/platform/values.yaml)   # no // : yq treats false as empty
  [[ "$addon_default" == "null" ]] && addon_default=true

  for inst_dir in installations/*; do
    [[ -f "$inst_dir/installation.yaml" ]] || continue
    inst=$(basename "$inst_dir")
    if echo "$roles_raw" | grep -qx 'mgmt'; then
      m_name=$(yq '.mgmt.name // "mgmt"' "$inst_dir/installation.yaml")
      m_prov=$(yq '.mgmt.provider // "docker"' "$inst_dir/installation.yaml")
      m_env=$(yq '.mgmt.environment // "mgmt"' "$inst_dir/installation.yaml")
      m_cni=$(yq '.mgmt.cni // "flannel"' "$inst_dir/installation.yaml")
      m_toggle=$(yq ".mgmt.addons[\"$addon\"]" "$inst_dir/installation.yaml")   # no // : yq treats false as empty
      if [[ "$m_toggle" == "false" ]] || { [[ "$addon_default" == "false" ]] && [[ "$m_toggle" != "true" ]]; }; then
        echo "  SKIP addons/$addon ($inst/mgmt): disabled by label"
      elif [[ -z "$providers_filter" ]] || echo "$providers_filter" | grep -qx "$m_prov"; then
        vargs=()
        for vf in \
          "$dir/values.yaml" \
          "$dir/values/role-mgmt.yaml" \
          "$dir/values/provider-$m_prov.yaml" \
          "$dir/values/cni-$m_cni.yaml" \
          "$inst_dir/addons/$addon/values.yaml" \
          "$inst_dir/addons/$addon/env-$m_env.yaml" \
          "$inst_dir/addons/$addon/cluster-$m_name.yaml"; do
          [[ -f "$vf" ]] && vargs+=(--values "$vf")
        done
        # Same precedence as the ApplicationSet: valueFiles < valuesObject (installation + cluster.*) < parameters
        vargs+=(--values "$inst_dir/installation.yaml" --set-string "cluster.name=$m_name,cluster.role=mgmt,cluster.provider=$m_prov,cluster.environment=$m_env,cluster.cni=$m_cni,cluster.region=$(yq '.mgmt.region // "local"' "$inst_dir/installation.yaml")")
        for p in ${cn_params[@]+"${cn_params[@]}"}; do
          [[ -n "$p" ]] && vargs+=(--set-string "${p}=$m_name")
        done
        while IFS=$'\t' read -r ip it; do
          [[ -n "$ip" ]] || continue
          iv=$(yq -o=json "$inst_dir/installation.yaml" | py -c 'import json,sys,re;d=json.load(sys.stdin);t=sys.argv[1];print(re.sub(r"\{\{\s*\.Values\.([\w.]+)\s*\}\}",lambda m:str(__import__("functools").reduce(lambda a,k:a[k],m.group(1).split("."),d)),t))' "$it")
          vargs+=(--set "${ip}=${iv}")   # Argo helm parameters are --set (typed), not --set-string
        done < <(yq -r ".addons[\"$addon\"].installationParameters // {} | to_entries[] | [.key, .value] | @tsv" charts/platform/values.yaml)
        sp_args=()
        read_lines sp_args server_param_args "$addon" "$MGMT_SERVER"
        vargs+=(${sp_args[@]+"${sp_args[@]}"})
        yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels' "$TMP/platform-$inst.yaml" > "$TMP/labels-$inst-mgmt.yaml"
        lp_args=()
        read_lines lp_args label_param_args "$addon" "$TMP/labels-$inst-mgmt.yaml"
        vargs+=(${lp_args[@]+"${lp_args[@]}"})
        helm template "$addon" "$dir" --namespace "$ns" "${vargs[@]}" > "$TMP/addon-$addon-$inst-mgmt.yaml"
        check_kubeconform "addons/$addon ($inst/mgmt)" "$TMP/addon-$addon-$inst-mgmt.yaml"
      fi
    fi

    if echo "$roles_raw" | grep -qx 'workload'; then
      for cf in "$inst_dir"/clusters/*.yaml; do
        [[ -f "$cf" ]] || continue
        c_name=$(yq '.name' "$cf")
        c_prov=$(yq '.provider // "docker"' "$cf")
        c_env=$(yq '.environment // "development"' "$cf")
        if [[ -n "$providers_filter" ]] && ! echo "$providers_filter" | grep -qx "$c_prov"; then
          continue
        fi
        c_cni=$(yq '.cni // "cilium"' "$cf")
        # addon labels as rendered by charts/cluster (step 4), e.g. addons.platform.koorikla.io/cilium derives from cni
        c_toggle=$(yq "select(.kind == \"Cluster\") | .metadata.labels[\"addons.platform.koorikla.io/$addon\"]" "$TMP/cluster-$inst-$c_name.yaml" 2>/dev/null || true)
        [[ -n "$c_toggle" && "$c_toggle" != "null" ]] || c_toggle=$(yq ".addons[\"$addon\"]" "$cf")
        if [[ "$c_toggle" == "false" ]] || { [[ "$addon_default" == "false" ]] && [[ "$c_toggle" != "true" ]]; }; then
          echo "  SKIP addons/$addon ($inst/$c_name): disabled by label"
          continue
        fi
        vargs=()
        for vf in \
          "$dir/values.yaml" \
          "$dir/values/role-workload.yaml" \
          "$dir/values/provider-$c_prov.yaml" \
          "$dir/values/cni-$c_cni.yaml" \
          "$inst_dir/addons/$addon/values.yaml" \
          "$inst_dir/addons/$addon/env-$c_env.yaml" \
          "$inst_dir/addons/$addon/cluster-$c_name.yaml"; do
          [[ -f "$vf" ]] && vargs+=(--values "$vf")
        done
        vargs+=(--values "$inst_dir/installation.yaml" --set-string "cluster.name=$c_name,cluster.role=workload,cluster.provider=$c_prov,cluster.environment=$c_env,cluster.cni=$c_cni,cluster.region=$(yq '.region // "local"' "$cf")")
        for p in ${cn_params[@]+"${cn_params[@]}"}; do
          [[ -n "$p" ]] && vargs+=(--set-string "${p}=$c_name")
        done
        while IFS=$'\t' read -r ip it; do
          [[ -n "$ip" ]] || continue
          iv=$(yq -o=json "$inst_dir/installation.yaml" | py -c 'import json,sys,re;d=json.load(sys.stdin);t=sys.argv[1];print(re.sub(r"\{\{\s*\.Values\.([\w.]+)\s*\}\}",lambda m:str(__import__("functools").reduce(lambda a,k:a[k],m.group(1).split("."),d)),t))' "$it")
          vargs+=(--set "${ip}=${iv}")   # Argo helm parameters are --set (typed), not --set-string
        done < <(yq -r ".addons[\"$addon\"].installationParameters // {} | to_entries[] | [.key, .value] | @tsv" charts/platform/values.yaml)
        sp_args=()
        read_lines sp_args server_param_args "$addon" "$SAMPLE_SERVER"
        vargs+=(${sp_args[@]+"${sp_args[@]}"})
        yq 'select(.kind == "Cluster") | .metadata.labels' "$TMP/cluster-$inst-$c_name.yaml" > "$TMP/labels-$inst-$c_name.yaml" 2>/dev/null || : > "$TMP/labels-$inst-$c_name.yaml"
        lp_args=()
        read_lines lp_args label_param_args "$addon" "$TMP/labels-$inst-$c_name.yaml"
        vargs+=(${lp_args[@]+"${lp_args[@]}"})
        helm template "$addon" "$dir" --namespace "$ns" "${vargs[@]}" > "$TMP/addon-$addon-$inst-$c_name.yaml"
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
