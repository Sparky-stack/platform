#!/usr/bin/env bash
# helm-unittest silently passes a test whose `templates:` entry names a file that no longer exists (it renders nothing,
# so "hasDocuments: 0" holds vacuously, #236). After template moves, every templates/... path in a suite must exist.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_unittest_paths =="

# missing_paths <chart dir>: prints "<suite>: <path>" for every referenced template file that does not exist
missing_paths() {
  local chart=$1 suite path
  for suite in "$chart"/tests/*_test.yaml; do
    [[ -f "$suite" ]] || continue
    while IFS= read -r path; do
      [[ -f "$chart/$path" ]] || echo "${suite#"$ROOT"/}: $path"
    done < <(grep -oE '(^|[[:space:]:"])templates/[A-Za-z0-9_./-]+\.(yaml|tpl)' "$suite" | grep -oE 'templates/.*' | sort -u)
  done
}

# Negative first: a fixture suite pointing at a deleted template is reported.
fx="$TMP/chart"
mkdir -p "$fx/templates/common" "$fx/tests"
touch "$fx/templates/common/kept.yaml"
printf 'templates:\n  - templates/common/kept.yaml\n  - templates/moved.yaml\n' > "$fx/tests/x_test.yaml"
out=$(missing_paths "$fx")
assert_match "$out" "templates/moved.yaml" "stale template path in a unittest suite is reported"
assert_eq "$(grep -c kept.yaml <<<"$out" || true)" 0 "existing template path is not reported"

# Real repo: no suite references a missing template.
stale=""
for chart in "$ROOT"/charts/* "$ROOT"/addons/*; do
  [[ -f "$chart/Chart.yaml" && -d "$chart/tests" ]] || continue
  stale+=$(missing_paths "$chart")
done
assert_eq "$stale" "" "every templates/ path in charts/*/tests and addons/*/tests exists"

finish
