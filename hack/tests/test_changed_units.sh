#!/usr/bin/env bash
# hack/changed-units.sh on fixture path lists: which units a PR validates, and when it falls back to the full suite.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

units() { printf '%s\n' "$@" | bash "$ROOT/hack/changed-units.sh" | tr '\n' ' ' | sed 's/ $//'; }

assert_eq "$(units charts/tenant/values.yaml charts/tenant/templates/ns.yaml)" "charts/tenant" "chart-only -> that chart"
assert_eq "$(units addons/kyverno/values.yaml)" "addons/kyverno" "addon-only -> that addon (not kyverno-policies)"
assert_eq "$(units installations/local/addons/mesh/values.yaml)" "addons/mesh" "installation addon values -> addon"
assert_eq "$(units packages/postgresql/apis/composition.yaml)" "packages/postgresql" "package -> that package"
assert_eq "$(units docs/data-services.md)" "docs/data-services.md" "doc read by contract tests -> doc unit"
assert_eq "$(units docs/openchoreo.md)" "docs/openchoreo.md" "doc read via path prefix -> doc unit"
assert_eq "$(units README.md)" "README.md" "root README read by contract tests -> README.md unit"
assert_eq "$(units docs/diagrams/x.svg)" "docs/diagrams" "docs/diagrams/** -> docs/diagrams unit"
assert_eq "$(units ci/fixtures/go/main.go .github/workflows/app-go.yaml)" "ci" "ci stack"
assert_eq "$(units templates/go/template.yaml)" "templates" "backstage templates"
assert_eq "$(units addons/mesh/values.yaml docs/dns.md addons/mesh/README.md)" "addons/mesh" "docs ride along"
assert_eq "$(units docs/dns.md)" "docs" "a doc no test reads -> docs-only"
assert_eq "$(units docs/dns.md wiki/index.md AGENTS.md addons/README.md)" "docs" "docs-only"
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
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests addons/mesh | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_mesh_probe_cidrs.sh " "addons/mesh -> test_mesh_probe_cidrs"
assert_match "$tests" " hack/check-istio-probe-cidr.sh " "addons/mesh -> check-istio-probe-cidr"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests addons/kyverno | tr '\n' ' ')"
assert_eq "${tests/test_kyverno_policies/}" "$tests" "addons/kyverno does not match addons/kyverno-policies"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests packages/none | tr '\n' ' ')"
assert_eq "$tests" " " "a package nothing names -> no contract tests"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests docs/data-services.md | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_data_services.sh " "docs/data-services.md -> test_data_services"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests docs/openchoreo.md | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_set_repo.sh " "docs/openchoreo.md -> test_set_repo (via \$W/ prefix)"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests "$(units docs/runbooks/incidents.md)" | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_set_repo.sh " "docs/runbooks/incidents.md -> test_set_repo (via \$W/ prefix)"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests README.md | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_set_repo.sh " "README.md -> test_set_repo"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests docs/diagrams | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_diagrams.sh " "docs/diagrams -> test_diagrams"
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests packages/postgresql | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_data_services.sh " "packages/postgresql -> test_data_services (XRD examples)"

# Secret store scope (#244): a chart with ExternalSecrets gets the per-chart check in a scoped run; only a chart that
# defines a store or workflow takes the cross-chart test's full-if (hack/test-changed.sh greps the changed charts).
tests=" $(cd "$ROOT" && bash hack/changed-units.sh --tests addons/telemetry | tr '\n' ' ')"
assert_match "$tests" " hack/tests/test_secret_store_scope_chart.sh " "addons/telemetry -> per-chart secret store scope"
assert_eq "$(sed -n 's/^# scoped-ci full-if: //p' "$ROOT/hack/tests/test_secret_store_scope_chart.sh")" "" \
  "test_secret_store_scope_chart runs in scoped PR runs (no full-if)"
full_if=$(sed -n 's/^# scoped-ci full-if: //p' "$ROOT/hack/tests/test_secret_store_scope.sh")
for c in addons/telemetry addons/harbor addons/falco charts/tenant; do
  assert_eq "$(grep -rEqs --exclude-dir=charts "$full_if" "$ROOT/$c" && echo full || echo scoped)" scoped \
    "$c (ExternalSecrets only) stays scoped"
done
for c in addons/secret-stores addons/openchoreo-workflow-plane addons/openchoreo-platform addons/external-dns; do
  assert_eq "$(grep -rEqs --exclude-dir=charts "$full_if" "$ROOT/$c" && echo full || echo scoped)" full \
    "$c (defines a store, workflow plane, workflows or the dns guard) -> full"
done

finish
