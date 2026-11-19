#!/usr/bin/env bash
# hack/changed-units.sh on fixture path lists: which units a PR validates, and when it falls back to the full suite.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_changed_units =="

units() { printf '%s\n' "$@" | bash "$ROOT/hack/changed-units.sh" | tr '\n' ' ' | sed 's/ $//'; }

assert_eq "$(units charts/tenant/values.yaml charts/tenant/templates/ns.yaml)" "charts/tenant" "chart-only -> that chart"
assert_eq "$(units addons/kyverno/values.yaml)" "addons/kyverno" "addon-only -> that addon (not kyverno-policies)"
assert_eq "$(units installations/local/addons/mesh/values.yaml)" "addons/mesh" "installation addon values -> addon"
assert_eq "$(units packages/postgresql/apis/composition.yaml)" "packages/postgresql" "package -> that package"
assert_eq "$(units ci/fixtures/go/main.go .github/workflows/app-go.yaml)" "ci" "ci stack"
assert_eq "$(units templates/go/template.yaml)" "templates" "backstage templates"
assert_eq "$(units addons/mesh/values.yaml docs/networking.md addons/mesh/README.md)" "addons/mesh" "docs ride along"
assert_eq "$(units docs/networking.md wiki/index.md README.md addons/README.md)" "docs" "docs-only"
assert_eq "$(units charts/README.md installations/local/README.md)" "docs" "READMEs outside charts are docs"

for p in hack/test.sh hack/README.md bootstrap/README.md bootstrap/bootstrap.sh charts/platform/values.yaml charts/cluster/values.yaml \
  installations/local/installation.yaml installations/local/clusters/mgmt.yaml mise.toml mise.lock Taskfile.yml \
  prek.toml renovate.json .github/workflows/ci.yaml .github/workflows/release.yaml newdir/file LICENSE; do
  assert_eq "$(units addons/mesh/values.yaml "$p")" "full" "shared/unknown input $p -> full"
done
assert_eq "$(printf '' | bash "$ROOT/hack/changed-units.sh")" "full" "no paths -> full (unsure)"
assert_eq "$(bash "$ROOT/hack/changed-units.sh" addons/mesh/x charts/tenant/y | tr '\n' ' ')" "addons/mesh charts/tenant " \
  "paths as arguments"

# Related contract tests: named by path, word-bounded; charts/addons also get the every-chart tests.
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests addons/harbor | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_harbor_config.sh " "addons/harbor -> test_harbor_config"
assert_match "$tests" " hack/tests/test_image_pins.sh " "addon -> every-chart test (RENDERED_DIR)"
assert_match "$tests" " hack/tests/test_chart_locks.sh " "addon -> every-chart test (addons/*)"
assert_eq "${tests/test_telemetry_series/}" "$tests" "addons/harbor does not pull test_telemetry_series"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests addons/kyverno | tr '\n' ' ')"
assert_eq "${tests/test_kyverno_policies/}" "$tests" "addons/kyverno does not match addons/kyverno-policies"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests packages/none | tr '\n' ' ')"
assert_eq "$tests" " " "a package nothing names -> no contract tests"

finish
