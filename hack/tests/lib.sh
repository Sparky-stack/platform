# hack/tests/lib.sh: sourced by every hack/tests/*.sh. Assertions with a pass/fail count (finish prints it and sets the
# exit code hack/test.sh reads), a fake-tool harness, kubeconform, and renders reused from hack/test.sh.
# shellcheck shell=bash disable=SC2034
set -euo pipefail
echo "== $(basename "$0" .sh) =="

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

# --- fake-tool harness: run a script against fakes in $BIN with a minimal environment --------------------------------

# fake_bin_yq <bin dir>: put the real yq (REAL_YQ) behind a wrapper in <bin dir>. Scenarios run with PATH=<bin>:/usr/bin:/bin,
# where a mise shim finds no config, and on Windows `mise which` returns a C:\ path that would break PATH.
fake_bin_yq() {
  REAL_YQ=$(mise which yq 2>/dev/null || command -v yq)
  [[ -x "$REAL_YQ" ]] || { echo "  yq not found" >&2; exit 1; }
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_YQ" > "$1/yq"
  chmod +x "$1/yq"
}

# run_isolated <name> <script> [VAR=val ...]: bash <script> with only HOME, PATH=$BIN:/usr/bin:/bin, SYSTEMROOT (Winsock
# on Windows), TMPDIR, HLOG and the given variables. Fakes log their argv to $HLOG/calls. Sets HLOG, RC and OUT
# (stdout+stderr, colours stripped).
run_isolated() {
  local name=$1 script=$2; shift 2
  HLOG="$TMP/out/$name"; mkdir -p "$HLOG"; : > "$HLOG/calls"
  if env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" SYSTEMROOT="${SYSTEMROOT:-}" TMPDIR="$TMP" HLOG="$HLOG" \
      "$@" "$BASH" "$script" > "$HLOG/out" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$HLOG/out")
}

# bootstrap_harness: R=$TMP/root holds bootstrap/bs.sh = bootstrap/bootstrap.sh minus its command dispatcher plus a hook
# that evals $HARNESS_CALL after load_inst, so a test calls single bootstrap functions; BIN=$TMP/bin starts with yq.
# Run a function with: run_isolated <name> "$R/bootstrap/bs.sh" KUBE_CTX=fake INST=local HARNESS_CALL=<call> [VAR=val ...]
bootstrap_harness() {
  R="$TMP/root"; BIN="$TMP/bin"
  mkdir -p "$R/bootstrap" "$R/hack"
  cp -R "$ROOT/hack/lib" "$R/hack/"
  cp -R "$ROOT/installations" "$R/"
  sed '/^case "\$CMD" in$/,$d' "$ROOT/bootstrap/bootstrap.sh" > "$R/bootstrap/bs.sh"
  # shellcheck disable=SC2016  # literal code for the generated script
  printf '%s\n' 'load_inst; eval "$HARNESS_CALL"' >> "$R/bootstrap/bs.sh"
  fake_bin_yq "$BIN"
}

# kc_valid <file|dir>... -> yes|no (kubeconform's report on stderr when no): kubeconform -strict as hack/test.sh runs
# it, CRD schemas from $SCHEMAS_DIR (hack/schemas.sh) looked up first so an offline run never asks upstream for them.
kc_valid() {
  local out
  mkdir -p "$SCHEMAS_DIR/.kubeconform-cache"
  if out=$(kubeconform -cache "$SCHEMAS_DIR/.kubeconform-cache" -strict -summary -kubernetes-version 1.35.0 \
      -skip CustomResourceDefinition -schema-location "$SCHEMAS_DIR/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
      -schema-location default "$@" 2>&1); then
    echo yes
  else
    echo "$out" >&2
    echo no
  fi
}

# --- renders: reuse hack/test.sh's (RENDERED_DIR) when present ------------------------------------------------------

# render_platform <inst> <out>: reuse RENDERED_DIR/platform-<inst>.yaml if present, else helm template charts/platform.
render_platform() {
  local inst="$1" out="$2"
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/platform-$inst.yaml" ]]; then
    cp "$RENDERED_DIR/platform-$inst.yaml" "$out"
  else
    helm template platform "$ROOT/charts/platform" --namespace argocd \
      --values "$ROOT/installations/$inst/installation.yaml" --set secrets.githubGateApp.enabled=true > "$out"   # = hack/test.sh
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
