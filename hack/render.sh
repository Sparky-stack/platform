#!/usr/bin/env bash
# Render every chart the way Argo CD would into <out dir> (read by hack/test.sh and hack/tests/ via RENDERED_DIR).
# Usage: hack/render.sh <out dir> [chart dir...]   (charts/platform and charts/cluster always render; JOBS=CPU count)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=lib/addons.sh
source hack/lib/addons.sh

# Opt-in mgmt addons (catalog default false) rendered with every installation's values so values changes cannot break them.
FORCED_OPT_IN="agentgateway finops-opencost"

# render_addon <chart dir>: the standalone render (addons/* only: a catalog `path` chart such as charts/cluster in
# scope fleet has its own) and one per installation x cluster the addon runs on. Reads $OUT, writes cluster labels and
# valuesObject files to $WORK.
render_addon() {
  local dir=$1 addon ns release roles providers addon_default inst_dir inst y cf
  local m_name m_prov m_toggle c_name c_prov c_toggle labels p
  local -a sets=() vargs=()
  addon=$(D="$dir" yq '.addons | to_entries | .[] | select(.value.path == strenv(D)) | .key' "$ADDONS_CATALOG")
  [[ -n "$addon" ]] || addon=$(basename "$dir")
  ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" "$ADDONS_CATALOG")

  if [[ "$dir" == addons/* ]]; then
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then sets+=(--set-string "${p}=sample" --set-string cluster.name=sample); fi
    done < <(yq ".addons[\"$addon\"] | ((.clusterNameParameters // []) + (.clusterIdParameters // [])) | .[]" "$ADDONS_CATALOG")
    read_lines vargs sample_param_args "$addon"
    sets+=(${vargs[@]+"${vargs[@]}"})
    helm template "$(yq ".addons[\"$addon\"].releaseName // \"$addon\"" "$ADDONS_CATALOG")" "$dir" --namespace "$ns" \
      ${sets[@]+"${sets[@]}"} > "$OUT/addon-$addon-standalone.yaml"
  fi

  roles=$(yq ".addons[\"$addon\"].roles[]?" "$ADDONS_CATALOG" || true)
  [[ -n "$roles" ]] || roles=$'mgmt\nworkload'
  providers=$(yq ".addons[\"$addon\"].providers[]?" "$ADDONS_CATALOG" || true)
  addon_default=$(yq ".addons[\"$addon\"].default" "$ADDONS_CATALOG")   # no // : yq treats false as empty
  [[ "$addon_default" == "null" ]] && addon_default=true

  for inst_dir in installations/*; do
    y=$inst_dir/installation.yaml
    [[ -f "$y" ]] || continue
    inst=$(basename "$inst_dir")
    release=$(addon_release_name "$WORK/platform-$inst.yaml" "$addon")
    if grep -qx mgmt <<<"$roles"; then
      m_name=$(yq '.mgmt.name // "mgmt"' "$y")
      m_prov=$(yq '.mgmt.provider // "docker"' "$y")
      m_toggle=$(yq ".mgmt.addons[\"$addon\"]" "$y")   # no // : yq treats false as empty
      if [[ "$m_toggle" == true ]] || { [[ "$m_toggle" != false && "$addon_default" != false ]]; } \
        || { [[ "$m_toggle" != false ]] && [[ " $FORCED_OPT_IN " == *" $addon "* ]]; }; then
        if addon_runs_on "$m_prov" "$providers"; then
          labels=$WORK/labels-$inst-mgmt.yaml   # mgmt's cluster labels (catalog clusterLabelParameters, label-selected files)
          read_lines vargs addon_helm_args "$addon" "$inst_dir" "$WORK/platform-$inst.yaml" mgmt "$m_name" "$m_prov" \
            "$(yq '.mgmt.environment // "mgmt"' "$y")" "$(yq '.mgmt.region // "local"' "$y")" \
            "$(yq '.mgmt.cni // "flannel"' "$y")" "$ADDONS_MGMT_SERVER" "$labels"
          helm template "$release" "$dir" --namespace "$ns" "${vargs[@]}" > "$OUT/addon-$addon-$inst-mgmt.yaml"
        fi
      else
        echo "  SKIP addons/$addon ($inst/mgmt): disabled by label"
      fi
    fi

    grep -qx workload <<<"$roles" || continue
    for cf in "$inst_dir"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      c_name=$(yq '.name' "$cf")
      c_prov=$(yq '.provider // "docker"' "$cf")
      addon_runs_on "$c_prov" "$providers" || continue
      labels=$WORK/labels-$inst-$c_name.yaml
      c_toggle=$(addon_cluster_toggle "$addon" "$cf" "$labels")
      if [[ "$c_toggle" == false ]] || { [[ "$addon_default" == false ]] && [[ "$c_toggle" != true ]]; }; then
        echo "  SKIP addons/$addon ($inst/$c_name): disabled by label"
        continue
      fi
      read_lines vargs addon_helm_args "$addon" "$inst_dir" "$WORK/platform-$inst.yaml" workload "$c_name" "$c_prov" \
        "$(yq '.environment // "development"' "$cf")" "$(yq '.region // "local"' "$cf")" "$(yq '.cni // "cilium"' "$cf")" \
        "$ADDONS_SAMPLE_SERVER" "$labels"
      helm template "$release" "$dir" --namespace "$ns" "${vargs[@]}" > "$OUT/addon-$addon-$inst-$c_name.yaml"
    done
  done
}

# Worker: `hack/render.sh --addon <chart dir>` (OUT, WORK from the parent), output buffered into $WORK/<addon>.log.
if [[ "${1:-}" == --addon ]]; then
  log="$WORK/$(basename "$2").log"
  trap 'rc=$?; [[ $rc == 0 ]] || echo "  FAIL render $2 (exit $rc)" >> "$log"' EXIT
  render_addon "$2" > "$log" 2>&1   # a plain statement: set -e ends the worker at the first error
  exit 0
fi

[[ $# -ge 1 ]] || { sed -n '2,3p' "$0" >&2; exit 2; }
OUT=$1; shift
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export OUT WORK
./hack/deps.sh

# charts/platform and charts/cluster first: every layered addon render reads them.
helm template platform charts/platform --namespace argocd > "$OUT/platform-standalone.yaml"
for inst_dir in installations/*; do
  y=$inst_dir/installation.yaml
  [[ -f "$y" ]] || continue
  inst=$(basename "$inst_dir")
  # Full feature set, as with the platform GitHub App seeded (bootstrap.sh sets this on the root app; default false):
  # the addon renders then include auto-build and the preview token.
  helm template platform charts/platform --namespace argocd --values "$y" \
    --set secrets.githubGateApp.enabled=true --set secrets.githubLogin.enabled=true > "$OUT/platform-$inst.yaml"
  cp "$OUT/platform-$inst.yaml" "$WORK/platform-$inst.yaml"   # addon_helm_args writes valuesObject files next to it
  yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels' "$OUT/platform-$inst.yaml" \
    > "$WORK/labels-$inst-mgmt.yaml"
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf")
    helm template "cluster-$c" charts/cluster --namespace fleet --values "$y" --values "$cf" > "$OUT/cluster-$inst-$c.yaml"
    addon_cluster_labels "$OUT/cluster-$inst-$c.yaml" "$WORK/labels-$inst-$c.yaml"
  done
done

# Addons (and catalog entries with their own chart `path`, e.g. cluster-fleet: charts/cluster in scope fleet).
dirs=()
for dir in addons/* $(yq '.addons[] | select(.path) | .path' "$ADDONS_CATALOG" | tr -d '\r'); do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if [[ $# -eq 0 || " $* " == *" $dir "* ]]; then dirs+=("$dir"); fi
done
rc=0
if (( ${#dirs[@]} > 0 )); then   # GNU xargs would run the worker once on empty input
  printf '%s\n' "${dirs[@]}" | xargs -P "${JOBS:-$(cpu_count)}" -n 1 bash hack/render.sh --addon || rc=$?
  for dir in "${dirs[@]}"; do cat "$WORK/$(basename "$dir").log"; done
fi
echo "  rendered $(find "$OUT" -name '*.yaml' | wc -l | tr -d ' ') manifests into $OUT"
exit "$rc"
