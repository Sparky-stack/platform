# hack/tests/lib.sh — shared assertion helpers for bash contract tests.
# shellcheck shell=bash disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (expected=%q actual=%q)\n' "$msg" "$expected" "$actual" >&2
  fi
}

assert_nonempty() {
  local val="$1" msg="$2"
  if [[ -n "$val" && "$val" != "null" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (empty)\n' "$msg" >&2
  fi
}

assert_match() {
  local val="$1" pat="$2" msg="$3"
  if [[ "$val" =~ $pat ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (value=%q did not match=%q)\n' "$msg" "$val" "$pat" >&2
  fi
}

finish() {
  echo "  $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}

# render_platform <inst> <out>: reuse RENDERED_DIR/platform-<inst>.yaml if present, else helm template charts/platform.
render_platform() {
  local inst="$1" out="$2"
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/platform-$inst.yaml" ]]; then
    cp "$RENDERED_DIR/platform-$inst.yaml" "$out"
  else
    helm template platform "$ROOT/charts/platform" --namespace argocd \
      --values "$ROOT/installations/$inst/installation.yaml" > "$out"
  fi
}

# render_cluster <inst> <cluster> <out>: reuse RENDERED_DIR/cluster-<inst>-<cluster>.yaml if present, else helm template charts/cluster.
render_cluster() {
  local inst="$1" cluster="$2" out="$3"
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/cluster-$inst-$cluster.yaml" ]]; then
    cp "$RENDERED_DIR/cluster-$inst-$cluster.yaml" "$out"
  else
    helm template "cluster-$cluster" "$ROOT/charts/cluster" --namespace fleet \
      --values "$ROOT/installations/$inst/installation.yaml" \
      --values "$ROOT/installations/$inst/clusters/$cluster.yaml" > "$out"
  fi
}

# render_standalone_addon <addon> <out>: reuse RENDERED_DIR/addon-<addon>-standalone.yaml if present, else helm template addons/<addon>.
render_standalone_addon() {
  local addon="$1" out="$2" ns
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/addon-$addon-standalone.yaml" ]]; then
    cp "$RENDERED_DIR/addon-$addon-standalone.yaml" "$out"
  else
    ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" "$ROOT/charts/platform/values.yaml")
    helm template "$addon" "$ROOT/addons/$addon" --namespace "$ns" > "$out"
  fi
}

# render_layered_addon <inst> <addon> <out> <platform-render> <role> <name> <provider> <env> <region> <cni> <server> [labels-file]
render_layered_addon() {
  local inst="$1" addon="$2" out="$3" prender="$4" role="$5" name="$6" target="$6" ns
  [[ "$role" == mgmt ]] && target=mgmt
  shift 6
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/addon-$addon-$inst-$target.yaml" ]]; then
    cp "$RENDERED_DIR/addon-$addon-$inst-$target.yaml" "$out"
  else
    local -a vargs=()
    ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" "$ROOT/charts/platform/values.yaml")
    read_lines vargs addon_helm_args "$addon" "$ROOT/installations/$inst" "$prender" "$role" "$name" "$@"
    helm template "$(addon_release_name "$prender" "$addon")" "$ROOT/addons/$addon" --namespace "$ns" "${vargs[@]}" > "$out"
  fi
}
