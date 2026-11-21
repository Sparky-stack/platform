#!/usr/bin/env bash
# Full offline test suite: deps (cached), helm lint, template across all installations/clusters,
# kubeconform -strict with CRD schemas, helm unittest, and contract tests.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=lib/addons.sh
source hack/lib/addons.sh

for bin in helm yq kubeconform; do
  command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
done
pick_python || { echo "missing required tool: python3 (>= 3.8)" >&2; exit 1; }
# Warn about tool drift up front (global yq/helm instead of mise.toml's): an old yq fails deep in a test otherwise.
./hack/tools.sh check helm yq kubeconform 2>&1 | grep -E '^ *(DRIFT|MISSING)' >&2 || true

# CHARTS="addons/x charts/y": lint/render/unittest only these chart dirs (git pre-commit hook: hack/hooks.sh charts).
# charts/platform and charts/cluster still render (addons read their output); contract tests run in the full suite only,
# unless TESTS="hack/tests/test_x.sh ..." names the related ones (hack/test-changed.sh picks them).
CHARTS=${CHARTS:-}
TESTS=${TESTS:-}
selected() { [[ -z "$CHARTS" || " $CHARTS " == *" $1 "* ]]; }

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
export SCHEMAS_DIR

# 1. Build deps (cached) before linting, templating, schemas, or helm unittest
./hack/deps.sh

# A filtered run reuses cached schemas (regenerating them takes seconds); `task schemas` / the full suite refresh them.
if [[ -z "$CHARTS" || -z "$(ls -A "$SCHEMAS_DIR" 2>/dev/null)" ]]; then ./hack/schemas.sh; fi

# Offline after the first run: CRD schemas are looked up locally first (the upstream location would be asked, and fail
# without network, for every custom resource), and downloaded upstream Kubernetes schemas are cached.
mkdir -p "$SCHEMAS_DIR/.kubeconform-cache"
KUBECONFORM_ARGS=(
  -cache "$SCHEMAS_DIR/.kubeconform-cache"
  -strict
  -summary
  -kubernetes-version 1.35.0
  -skip CustomResourceDefinition
  -schema-location "$SCHEMAS_DIR/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json"
  -schema-location default
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Catalog clusterServerParameters (<helm param>: url|host|port of the Argo cluster secret's server), mirrored from
# charts/platform/templates/appset-addons.yaml. Prints helm args for the given addon and server URL.
server_param_args() {
  local addon="$1" server="$2" p part v
  while IFS=$'\t' read -r p part; do
    [[ -n "$p" ]] || continue
    v=$(addon_server_part "$server" "$part")
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
# Opt-in mgmt addons (catalog default false) rendered with every installation's values even where not switched on, so
# a values change cannot break them unnoticed. external-dns has its own suite (hack/tests/test_external_dns.sh: it
# must fail where dns.provider is none).
FORCED_OPT_IN=(agentgateway finops-opencost)
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

# sample_param_args <addon>: catalog server and label parameters for a render outside any cluster.
sample_param_args() {
  server_param_args "$1" "$SAMPLE_SERVER"
  label_param_args "$1" "$NO_LABELS"
}

# tally <command...>: run one suite and count it as passed or failed.
passed=0
failed=0
tally() {
  if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); fi
}

# 2. Lint every chart in charts/ and addons/ (charts/cluster linted per cluster below)
for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" && "$dir" != charts/cluster ]] || continue
  selected "$dir" || continue
  echo "==> helm lint $dir"
  lint_sets=()
  read_lines lint_sets sample_param_args "$(basename "$dir")"
  helm lint "$dir" ${lint_sets[@]+"${lint_sets[@]}"} >/dev/null
done

# 3. Render + kubeconform charts/platform for standalone + every installation
echo "==> Testing charts/platform"
helm template platform charts/platform --namespace argocd > "$TMP/platform-standalone.yaml"
check_kubeconform "charts/platform (standalone)" "$TMP/platform-standalone.yaml"
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  helm lint charts/platform --values "$inst_dir/installation.yaml" >/dev/null
  # Full feature set, as with the platform GitHub App seeded (bootstrap.sh sets this on the root app; default false):
  # the addon renders below then include auto-build and the preview token for kubeconform and the contract tests.
  helm template platform charts/platform --namespace argocd --values "$inst_dir/installation.yaml" \
    --set secrets.githubGateApp.enabled=true > "$TMP/platform-$inst.yaml"
  check_kubeconform "charts/platform ($inst)" "$TMP/platform-$inst.yaml"
done

# 4. Render + kubeconform charts/cluster (scope cluster) for every installation x cluster file; scope fleet renders in 5.
echo "==> Testing charts/cluster"
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

# 5. Render + kubeconform every addon in addons/* (standalone + layered per installation/role/cluster)
echo "==> Testing addons/*"
# Catalog entries with their own chart `path` (cluster-fleet: charts/cluster in scope fleet) render here like addons.
for dir in addons/* $(yq '.addons[] | select(.path) | .path' charts/platform/values.yaml); do
  [[ -f "$dir/Chart.yaml" ]] || continue
  selected "$dir" || continue
  addon=$(D="$dir" yq '.addons | to_entries | .[] | select(.value.path == strenv(D)) | .key' charts/platform/values.yaml)
  [[ -n "$addon" ]] || addon=$(basename "$dir")
  ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" charts/platform/values.yaml)

  cn_params=()
  read_lines cn_params yq ".addons[\"$addon\"] | ((.clusterNameParameters // []) + (.clusterIdParameters // [])) | .[]" charts/platform/values.yaml
  standalone_sets=()
  for p in ${cn_params[@]+"${cn_params[@]}"}; do
    [[ -n "$p" ]] && standalone_sets+=(--set-string "${p}=sample" --set-string cluster.name=sample)
  done
  param_args=()
  read_lines param_args sample_param_args "$addon"
  standalone_sets+=(${param_args[@]+"${param_args[@]}"})

  if [[ "$dir" == addons/* ]]; then   # a `path` chart has its own standalone render (charts/cluster: step 4 + unittest)
    helm template "$(yq ".addons[\"$addon\"].releaseName // \"$addon\"" charts/platform/values.yaml)" "$dir" --namespace "$ns" \
      ${standalone_sets[@]+"${standalone_sets[@]}"} > "$TMP/addon-$addon-standalone.yaml"
    check_kubeconform "addons/$addon (standalone)" "$TMP/addon-$addon-standalone.yaml"
  fi

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
      forced=""
      if [[ "$m_toggle" != "false" && "$addon_default" == "false" && "$m_toggle" != "true" ]] \
        && printf '%s\n' "${FORCED_OPT_IN[@]}" | grep -qx "$addon"; then
        forced=" (forced opt-in)"
      fi
      if [[ -z "$forced" ]] && { [[ "$m_toggle" == "false" ]] || { [[ "$addon_default" == "false" ]] && [[ "$m_toggle" != "true" ]]; }; }; then
        echo "  SKIP addons/$addon ($inst/mgmt): disabled by label"
      elif [[ -z "$providers_filter" ]] || echo "$providers_filter" | grep -qx "$m_prov"; then
        # Same layering and precedence as the ApplicationSet (hack/lib/addons.sh), parameters from its render above.
        vargs=()
        yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels' "$TMP/platform-$inst.yaml" \
          > "$TMP/labels-$inst-mgmt.yaml"   # mgmt's cluster labels (catalog clusterLabelParameters, label-selected files)
        read_lines vargs addon_helm_args "$addon" "$inst_dir" "$TMP/platform-$inst.yaml" mgmt "$m_name" "$m_prov" \
          "$m_env" "$(yq '.mgmt.region // "local"' "$inst_dir/installation.yaml")" "$m_cni" "$MGMT_SERVER" \
          "$TMP/labels-$inst-mgmt.yaml"
        helm template "$(addon_release_name "$TMP/platform-$inst.yaml" "$addon")" "$dir" --namespace "$ns" "${vargs[@]}" \
          > "$TMP/addon-$addon-$inst-mgmt.yaml"
        check_kubeconform "addons/$addon ($inst/mgmt)$forced" "$TMP/addon-$addon-$inst-mgmt.yaml"
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
        # the cluster's labels as charts/cluster renders them (step 4): mesh group/network, derived addon toggles such
        # as addons.platform.koorikla.io/cilium from cni
        addon_cluster_labels "$TMP/cluster-$inst-$c_name.yaml" "$TMP/labels-$inst-$c_name.yaml"
        c_toggle=$(yq ".[\"addons.platform.koorikla.io/$addon\"]" "$TMP/labels-$inst-$c_name.yaml" 2>/dev/null || true)
        [[ -n "$c_toggle" && "$c_toggle" != "null" ]] || c_toggle=$(yq ".addons[\"$addon\"]" "$cf")
        if [[ "$c_toggle" == "false" ]] || { [[ "$addon_default" == "false" ]] && [[ "$c_toggle" != "true" ]]; }; then
          echo "  SKIP addons/$addon ($inst/$c_name): disabled by label"
          continue
        fi
        vargs=()
        read_lines vargs addon_helm_args "$addon" "$inst_dir" "$TMP/platform-$inst.yaml" workload "$c_name" "$c_prov" \
          "$c_env" "$(yq '.region // "local"' "$cf")" "$c_cni" "$SAMPLE_SERVER" "$TMP/labels-$inst-$c_name.yaml"
        helm template "$(addon_release_name "$TMP/platform-$inst.yaml" "$addon")" "$dir" --namespace "$ns" "${vargs[@]}" \
          > "$TMP/addon-$addon-$inst-$c_name.yaml"
        check_kubeconform "addons/$addon ($inst/$c_name)" "$TMP/addon-$addon-$inst-$c_name.yaml"
      done
    fi
  done
done

# 6. Static manifests
echo "==> Validating bootstrap/root-app.yaml"
check_kubeconform "bootstrap/root-app.yaml" bootstrap/root-app.yaml

# 7. helm unittest where tests/ exists (after helm dependency build above)
for dir in charts/* addons/*; do
  [[ -d "$dir/tests" ]] || continue
  selected "$dir" || continue
  echo "==> helm unittest $dir"
  tally helm unittest "$dir"
done

# 8. Contract & invariant tests in hack/tests/test_*.sh (RENDERED_DIR: the manifests rendered above, e.g. for
#    test_secret_store_scope.sh)
export RENDERED_DIR="$TMP"
for t in hack/tests/test_*.sh; do
  [[ -f "$t" ]] || continue
  [[ -z "$CHARTS" || " $TESTS " == *" $t "* ]] || continue
  tally bash "$t"
done

echo
echo "$passed suite(s) passed, $failed failed"
(( failed == 0 ))
