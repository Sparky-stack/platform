#!/usr/bin/env bash
# Values contract (#116): every deployable chart (charts/*, addons/*; not library charts, not the *-test helm-unittest
# harness charts) ships a values.schema.json for its own platform keys, and `helm lint` - which validates values
# against the schema - passes with each installation's values (layered the way Argo CD layers them). No exemptions: a
# thin wrapper needs only `cluster` plus `"type": "object"` for its upstream subchart keys (e.g. addons/obi).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/hack/lib/portable.sh"
cd "$ROOT"
source hack/lib/addons.sh

MGMT_SERVER=https://kubernetes.default.svc   # = hack/test.sh
SAMPLE_SERVER=https://192.0.2.10:6443        # = hack/test.sh (TEST-NET-1)

# deployable_charts <root> -> chart dirs relative to <root>
deployable_charts() {
  local root=$1 d
  for d in "$root"/charts/* "$root"/addons/*; do
    [[ -f "$d/Chart.yaml" ]] || continue
    [[ "$(yq '.type // "application"' "$d/Chart.yaml" | tr -d '\r')" != library ]] || continue
    [[ "$d" != *-test ]] || continue
    printf '%s\n' "${d#"$root"/}"
  done
}

# schema_violations <root> -> one line per violation; empty when the contract holds.
schema_violations() {
  local root=$1 d
  while IFS= read -r d; do
    if [[ ! -f "$root/$d/values.schema.json" ]]; then
      echo "MISSING $d: no values.schema.json"
    else
      # shellcheck disable=SC2016 # $schema is a JSON key, not a shell variable
      yq -p json -e '.["$schema"] != null and .type == "object"' "$root/$d/values.schema.json" >/dev/null 2>&1 \
        || echo "INVALID $d: values.schema.json needs \$schema and top-level type object"
    fi
  done < <(deployable_charts "$root")
}

v=$(schema_violations "$ROOT")
assert_eq "$v" "" "every deployable chart has a valid values.schema.json"
[[ -z "$v" ]] || printf '    %s\n' "$v" >&2

# Negative fixture: each violation kind is reported; library and *-test charts are exempt, a valid schema passes.
F="$TMP/tree"
mk() { mkdir -p "$F/$1"; printf 'apiVersion: v2\nname: %s\nversion: 0.1.0\n%s' "$(basename "$1")" "${2:-}" > "$F/$1/Chart.yaml"; }
mk charts/noschema; mk charts/lib 'type: library'; mk charts/lib-test; mk addons/good; mk addons/bad
# shellcheck disable=SC2016
echo '{"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object"}' > "$F/addons/good/values.schema.json"
echo '{"type": "object"}' > "$F/addons/bad/values.schema.json"
v=$(schema_violations "$F")
assert_eq "$(printf '%s\n' "$v" | cut -d: -f1 | sort | tr '\n' ' ')" "INVALID addons/bad MISSING charts/noschema " \
  "fixture: a missing and an invalid schema are reported; library, *-test and valid charts are not"

# helm lint per installation: <label> <helm lint args...>
lint() {
  local label=$1 out rc; shift
  capture helm lint "$@"
  assert_eq "$RC" 0 "helm lint $label"
  [[ -z "${VALUES_SCHEMA_VERBOSE:-}" ]] || echo "  linted $label"
  linted+=" ${label%% *} "
  [[ $RC == 0 ]] || grep -E 'ERROR|Error|at ' <<<"$OUT" | sed -n 1,5p >&2
}
on() { [[ "$1" == true ]] || { [[ "$1" != false ]] && [[ "$2" != false ]]; }; }   # on <label toggle> <catalog default>
# lint_addon <chart dir> <inst dir> <platform render>: addon_helm_args (the ApplicationSet's layering) for mgmt when the
# addon runs there, else for the first workload cluster it runs on (labels as charts/cluster renders them).
lint_addon() {
  local d=$1 inst_dir=$2 pr=$3 inst a roles def provs y cf c t labels
  local -a args=()
  inst=$(basename "$inst_dir") y="$inst_dir/installation.yaml"
  a=$(D="$d" yq -r '.addons | to_entries | .[] | select(.value.path == strenv(D)) | .key' "$ADDONS_CATALOG" | tr -d '\r')
  [[ -n "$a" ]] || a=$(basename "$d")
  roles=$(yq -r ".addons[\"$a\"].roles[]?" "$ADDONS_CATALOG" | tr -d '\r')
  def=$(yq -r ".addons[\"$a\"].default" "$ADDONS_CATALOG" | tr -d '\r')
  provs=$(yq -r ".addons[\"$a\"].providers[]?" "$ADDONS_CATALOG" | tr -d '\r')
  if grep -qx mgmt <<< "$roles" && on "$(yq -r ".mgmt.addons[\"$a\"]" "$y")" "$def" \
    && { [[ -z "$provs" ]] || grep -qx "$(yq -r '.mgmt.provider // "docker"' "$y")" <<< "$provs"; }; then
    labels="$TMP/labels-$inst-mgmt.yaml"
    yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels' "$pr" > "$labels"
    read_lines args addon_helm_args "$a" "$inst_dir" "$pr" mgmt "$(yq -r '.mgmt.name // "mgmt"' "$y")" \
      "$(yq -r '.mgmt.provider // "docker"' "$y")" "$(yq -r '.mgmt.environment // "mgmt"' "$y")" \
      "$(yq -r '.mgmt.region // "local"' "$y")" "$(yq -r '.mgmt.cni // "flannel"' "$y")" "$MGMT_SERVER" "$labels"
    lint "$d ($inst/mgmt)" "$d" "${args[@]}"
    return
  fi
  if grep -qx workload <<< "$roles"; then
    for cf in "$inst_dir"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      c=$(yq -r '.name' "$cf" | tr -d '\r')
      [[ -z "$provs" ]] || grep -qx "$(yq -r '.provider // "docker"' "$cf")" <<< "$provs" || continue
      labels="$TMP/labels-$inst-$c.yaml"
      if [[ ! -f "$labels" ]]; then
        render_cluster "$inst" "$c" "$TMP/cluster-$inst-$c.yaml"
        yq 'select(.kind == "ExternalSecret" and .metadata.namespace == "argocd") | .spec.target.template.metadata.labels' \
          "$TMP/cluster-$inst-$c.yaml" > "$labels" 2>/dev/null || : > "$labels"
      fi
      t=$(addon_label "addons.platform.koorikla.io/$a" "$labels")
      [[ -n "$t" ]] || t=$(yq -r ".addons[\"$a\"]" "$cf" | tr -d '\r')
      on "$t" "$def" || continue
      read_lines args addon_helm_args "$a" "$inst_dir" "$pr" workload "$c" "$(yq -r '.provider // "docker"' "$cf")" \
        "$(yq -r '.environment // "development"' "$cf")" "$(yq -r '.region // "local"' "$cf")" \
        "$(yq -r '.cni // "cilium"' "$cf")" "$SAMPLE_SERVER" "$labels"
      lint "$d ($inst/$c)" "$d" "${args[@]}"
      return
    done
  fi
  skipped=$((skipped + 1))
}

PREVIEW=(--set 'project=demo,component=hello-world,pullRequest=7,commit=0123456789abcdef0123456789abcdef01234567')
schema_charts=()
skipped=0 linted=" "
read_lines schema_charts deployable_charts "$ROOT"
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir") iv=(--values "$inst_dir/installation.yaml") pr="$TMP/platform-$inst.yaml"
  render_platform "$inst" "$pr"
  for d in "${schema_charts[@]}"; do
    [[ -f "$d/values.schema.json" ]] || continue
    case "$d" in
      charts/platform) lint "$d ($inst)" "$d" "${iv[@]}" ;;
      charts/preview) lint "$d ($inst)" "$d" "${iv[@]}" "${PREVIEW[@]}" ;;
      charts/tenant)
        for tf in "$inst_dir"/tenants/*.yaml; do
          if [[ -f "$tf" ]]; then lint "$d ($inst/$(basename "$tf"))" "$d" "${iv[@]}" --values "$tf"; fi
        done ;;
      charts/cluster)
        lint "$d ($inst, scope fleet)" "$d" "${iv[@]}" --set scope=fleet
        for cf in "$inst_dir"/clusters/*.yaml; do
          if [[ -f "$cf" ]]; then lint "$d ($inst/$(basename "$cf" .yaml))" "$d" "${iv[@]}" --values "$cf"; fi
        done ;;
      *) lint_addon "$d" "$inst_dir" "$pr" ;;
    esac
  done
done
echo "  addon lints skipped (addon off in that installation): $skipped"
# Opt-in addons no installation switches on: at least lint them with the chart defaults.
for d in "${schema_charts[@]}"; do
  if [[ -f "$d/values.schema.json" && "$linted" != *" $d "* ]]; then lint "$d (chart defaults: off in every installation)" "$d"; fi
done
finish
