#!/usr/bin/env bash
# Full offline test suite: deps (cached), helm lint, every chart rendered once (hack/render.sh: all installations and
# clusters), kubeconform -strict with CRD schemas, then helm unittest + the contract tests in hack/tests/ side by side
# (JOBS at a time, default: CPU count), each reading the one render. Ends with a timing table, slowest first.
#   CHARTS="addons/x charts/y"  lint/render/unittest only these chart dirs (git pre-commit hook: hack/hooks.sh charts).
#                               charts/platform and charts/cluster still render (addons read their output); contract
#                               tests run in the full suite only, unless TESTS="hack/tests/test_x.sh ..." names the
#                               related ones (hack/test-changed.sh picks them). RENDER_ALL=1 renders every addon anyway.
#   TESTS="..." without CHARTS  only these contract tests (no lint/render: a suite that needs renders makes them).
#   TEST_FULL=1                 also the slow builds the per-area workflows already prove (crossplane project build of
#                               packages/*, hack/tests/test_crossplane_packages.sh); nightly portability workflow.
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

CHARTS=${CHARTS:-}
TESTS=${TESTS:-}
JOBS=${JOBS:-$(cpu_count)}
export JOBS
selected() { [[ -z "$CHARTS" || " $CHARTS " == *" $1 "* ]]; }
tests_only=""; if [[ -z "$CHARTS" && -n "$TESTS" ]]; then tests_only=1; fi

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
export SCHEMAS_DIR
TIMES_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/test-times.tsv   # last durations: slowest suites start first

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs"

# phase <name> <command...>: run one sequential step, timed for the table at the end.
phase() {
  local name=$1 start=$SECONDS; shift
  echo "==> $name"
  "$@"
  printf '%s\t%s\t0\n' "$((SECONDS - start))" "$name" >> "$TMP/logs/phases.tsv"
}

# 1. Chart dependencies (cached) and CRD schemas. A filtered run reuses cached schemas (`task schemas` refreshes them).
phase "chart dependencies (hack/deps.sh)" ./hack/deps.sh
export DEPS_READY=1   # hack/tests/lib.sh: do not run hack/deps.sh again in every suite
if [[ -z "$CHARTS$TESTS" || -z "$(ls -A "$SCHEMAS_DIR" 2>/dev/null)" ]]; then phase "CRD schemas (hack/schemas.sh)" ./hack/schemas.sh; fi

# 2. helm lint: every chart in charts/ and addons/, charts/platform per installation, charts/cluster per cluster file.
lint_all() {
  local dir inst_dir cf
  local -a sets=()
  for dir in charts/* addons/*; do
    [[ -f "$dir/Chart.yaml" && "$dir" != charts/cluster ]] || continue
    selected "$dir" || continue
    read_lines sets sample_param_args "$(basename "$dir")"
    helm lint "$dir" ${sets[@]+"${sets[@]}"} >/dev/null
  done
  for inst_dir in installations/*; do
    [[ -f "$inst_dir/installation.yaml" ]] || continue
    helm lint charts/platform --values "$inst_dir/installation.yaml" >/dev/null
    for cf in "$inst_dir"/clusters/*.yaml; do
      if [[ -f "$cf" ]]; then helm lint charts/cluster --values "$inst_dir/installation.yaml" --values "$cf" >/dev/null; fi
    done
  done
}
[[ -n "$tests_only" ]] || phase "helm lint" lint_all

# 3. Render every chart once (only the selected addons with CHARTS) and validate the renders with kubeconform -strict.
#    Offline after the first run: CRD schemas are looked up locally first, downloaded upstream schemas are cached.
if [[ -z "$tests_only" ]]; then
  RENDERED_DIR=$TMP/rendered
  export RENDERED_DIR
  render_charts=()
  if [[ -n "$CHARTS" && -z "${RENDER_ALL:-}" ]]; then read -r -a render_charts <<<"$CHARTS"; fi
  phase "render (hack/render.sh)" bash hack/render.sh "$RENDERED_DIR" ${render_charts[@]+"${render_charts[@]}"}
  mkdir -p "$SCHEMAS_DIR/.kubeconform-cache"
  phase "kubeconform renders + bootstrap/root-app.yaml" kubeconform -n "$JOBS" -cache "$SCHEMAS_DIR/.kubeconform-cache" \
    -strict -summary -kubernetes-version 1.35.0 -skip CustomResourceDefinition \
    -schema-location "$SCHEMAS_DIR/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
    -schema-location default "$RENDERED_DIR" bootstrap/root-app.yaml
fi

# 4. helm unittest (charts with tests/) and the contract tests in hack/tests/test_*.sh, JOBS at a time, slowest first
#    (durations of the last run), each with its own temp dir; output buffered per suite (hack/lib/run-suite.sh).
suites=()
for dir in charts/* addons/*; do
  if [[ -d "$dir/tests" && -z "$tests_only" ]] && selected "$dir"; then suites+=("unittest $dir"); fi
done
for t in hack/tests/test_*.sh; do
  if [[ -z "$CHARTS$TESTS" || " $TESTS " == *" $t "* ]]; then suites+=("contract $t"); fi
done
by_last_duration() {   # "<kind> <path>" lines -> slowest (last run) first, unknown first
  local s name secs
  while IFS= read -r s; do
    name=${s#* }; [[ "$s" == unittest* ]] && name="helm unittest $name"
    secs=$(N="$name" awk -F'\t' '$2 == ENVIRON["N"] { print $1 }' "$TIMES_CACHE" 2>/dev/null || true)
    printf '%s\t%s\n' "${secs:-999}" "$s"
  done | sort -t "$(printf '\t')" -k1,1nr | cut -f2
}
start=$SECONDS
echo "==> ${#suites[@]} suites, $JOBS at a time"
if (( ${#suites[@]} > 0 )); then   # GNU xargs would run the worker once on empty input
  printf '%s\n' "${suites[@]}" | by_last_duration | xargs -n 2 -P "$JOBS" bash hack/lib/run-suite.sh "$TMP/logs"
fi
printf '%s\t%s\t0\n' "$((SECONDS - start))" "suites (wall, $JOBS at a time)" >> "$TMP/logs/phases.tsv"

# 5. Timing table (slowest first) and result.
touch "$TMP/logs/results.tsv"
mkdir -p "$(dirname "$TIMES_CACHE")"
cat "$TMP/logs/results.tsv" "$TIMES_CACHE" 2>/dev/null | awk -F'\t' '!seen[$2]++' > "$TMP/times.tsv" || true
mv "$TMP/times.tsv" "$TIMES_CACHE"
echo
echo "==> Timings, slowest first (total ${SECONDS}s; suites run $JOBS at a time)"
sort -t "$(printf '\t')" -k1,1nr "$TMP/logs/phases.tsv" "$TMP/logs/results.tsv" \
  | awk -F'\t' 'NR <= 25 { printf "  %5ss  %s%s\n", $1, $2, ($3 == 0 ? "" : "  FAILED") }'
passed=$(awk -F'\t' '$3 == 0' "$TMP/logs/results.tsv" | wc -l | tr -d ' ')
failed=$(awk -F'\t' '$3 != 0' "$TMP/logs/results.tsv" | wc -l | tr -d ' ')
echo
awk -F'\t' '$3 != 0 { print "  FAILED: " $2 }' "$TMP/logs/results.tsv"
echo "$passed suite(s) passed, $failed failed"
(( failed == 0 && passed + failed == ${#suites[@]} ))
