#!/usr/bin/env bash
# Harbor's desired state is declarative (#394): addon harbor renders provider-upjet-harbor managed resources, never a
# Job, CronJob or reconcile script; the Harbor provider runs on mgmt only (addon crossplane values/role-mgmt.yaml) and
# activates exactly the kinds addon harbor renders. Reads every render (RENDERED_DIR: hack/test.sh's, or hack/render.sh's
# when run on its own).
# scoped-ci full-if: upjet-harbor|harbor\.m\.upbound\.io
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"
need_renders
shopt -s nullglob

harbor=("$RENDERED_DIR"/addon-harbor-*.yaml)
assert_nonempty "${harbor[*]}" "addon harbor renders"
for f in "${harbor[@]}"; do
  n=$(basename "$f")
  assert_eq "$(yq -N 'select(.kind == "Job" or .kind == "CronJob") | .kind + "/" + .metadata.name' "$f" | tr -d '\r')" "" \
    "$n: no Job or CronJob reconciles Harbor"
  assert_eq "$(grep -c 'harbor-config' "$f" || true)" 0 "$n: no harbor-config script, ConfigMap or hook"
  assert_eq "$(yq -N 'select(.apiVersion == "*harbor*.crossplane.io/*") | .metadata.namespace' "$f" | sort -u | tr -d '\r')" \
    harbor "$n: every Harbor managed resource lives in ns harbor (namespaced ProviderConfig harbor)"
  # Deleting a project would delete its images (apps holds every build).
  # No managementPolicies means ["*"]. yq's == globs ("*" matches anything): test() instead.
  assert_eq "$(yq -N 'select(.kind == "Project" and .apiVersion == "harbor.m.crossplane.io/*")
    | select((.spec.managementPolicies // ["*"]) | any_c(test("^(Delete|[*])$"))) | .metadata.name' "$f" | tr -d '\r')" "" \
    "$n: no project may be deleted from Harbor"
done
assert_eq "$(ls addons/harbor/files 2>/dev/null)" "" "addons/harbor/files: no reconcile script left"

# The provider exists only where addon harbor's objects are (mgmt), with an activation for exactly their kinds.
# kinds <render>: the managed resource definitions (<plural>.<group>) of the Harbor objects in it.
kinds() {
  yq -N 'select(.apiVersion == "*harbor*.crossplane.io/*" and .kind != "ProviderConfig")
    | (.kind | downcase) + "s." + (.apiVersion | sub("/.*", ""))' "$1" | sed 's/ys\./ies./' | sort -u | tr -d '\r'
}
for f in "$RENDERED_DIR"/addon-crossplane-*.yaml; do
  n=$(basename "$f")
  providers=$(yq -N 'select(.kind == "Provider" and (.spec.package | test("provider-upjet-harbor"))) | .metadata.name' "$f" | tr -d '\r')
  case $n in
    *-mgmt.yaml)
      inst=${n#addon-crossplane-}; inst=${inst%-mgmt.yaml}
      h="$RENDERED_DIR/addon-harbor-$inst-mgmt.yaml"
      [[ -f "$h" ]] || continue
      assert_eq "$providers" provider-upjet-harbor "$n: mgmt with addon harbor installs the Harbor provider"
      active=$(yq -N 'select(.kind == "ManagedResourceActivationPolicy" and .metadata.name == "harbor") | .spec.activate[]' "$f" \
        | sort -u | tr -d '\r')
      assert_eq "$(comm -23 <(kinds "$h") <(echo "$active"))" "" "$n: every Harbor kind addon harbor renders is activated"
      assert_eq "$(yq -N 'select(.kind == "Configuration" or .kind == "EnvironmentConfig") | .metadata.name' "$f" \
        | tr -d '\r')" "" "$n: no platform data API on mgmt"
      # The only Functions on mgmt run the GitHubRepository Composition (githubRepos, hack/tests/test_github_repos.sh).
      assert_eq "$(yq -N 'select(.kind == "Function") | .metadata.name' "$f" | tr -d '\r' \
        | grep -vxE 'function-go-templating|function-auto-ready' || true)" "" "$n: no data API Functions on mgmt" ;;
    *)
      assert_eq "$providers" "" "$n: no Harbor provider outside mgmt" ;;
  esac
done
finish
