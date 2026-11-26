#!/usr/bin/env bash
# GitHub repository governance (addon crossplane githubRepos, docs/github-repos.md, #100):
#   1. renders (every installation, RENDERED_DIR): provider-upjet-github only on the mgmt of an installation that turns
#      githubRepos on, pinned by digest, restricted runtime, an MRAP for exactly the kinds the Composition composes,
#      ProviderConfig github from the ESO Secret of store key github-repo-admin; the XRD and Composition are the files
#      in addons/crossplane/files/github-repository/; everything passes kubeconform -strict (provider + XRD schemas).
#      Safety contract: write access is never implicit. `management` has no default anywhere (XRD required, values
#      schema required, no defaulting in the template); a repository is fully managed only where its declaration
#      says `management: Full` (the one-line switch); this PR declares only Observe repositories.
#   2. `crossplane render` of the Composition (pinned CLI, engine and functions in Docker) for every GitHubRepository
#      the renders declare plus hack/tests/github-repos/xr-*.yaml: Observe composes every object with
#      managementPolicies exactly [Observe] (nothing on GitHub can change), the ruleset only to adopt an existing one;
#      Full adds Create, Update, LateInitialize and never Delete; the ruleset keeps CI bump commits, releases and
#      promotion PRs flowing (bypassApps always, platform-engineers by pull request only) and requires the declared checks from
#      GitHub Actions; status.url comes from the observed repository.
# Part 2 needs a Linux Docker engine; without one (macOS / Windows CI runners) it is skipped, part 1 still runs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=crossplane_render_lib.sh
source "$(dirname "$0")/crossplane_render_lib.sh"

ADDON=addons/crossplane
FILES=$ADDON/files/github-repository
FIX=hack/tests/github-repos
SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
[[ -f "$SCHEMAS_DIR/repo.github.m.upbound.io/repositoryruleset_v1alpha1.json" ]] || SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
kc() { assert_kc_valid "$1" "$2"; }
q() { xp_yq "$1" "$2"; }
need_renders
shopt -s nullglob

# --- 1. renders ---------------------------------------------------------------------------------------------------------
for f in definition composition; do
  assert_eq "$([[ -f "$FILES/$f.yaml" ]] && echo present || echo missing)" present "$FILES/$f.yaml ships with addon crossplane"
done
assert_eq "$(yq '.githubRepos.enabled' "$ADDON/values.yaml")" false "addon default: githubRepos is opt-in per installation"
assert_eq "$(yq '.githubRepos.enabled // false' "$ADDON/values/role-mgmt.yaml")" false \
  "values/role-mgmt.yaml leaves githubRepos off (one mgmt per GitHub account: the installation decides)"
assert_eq "$(yq -o=json -I=0 '.spec.versions[0].schema.openAPIV3Schema.properties.spec.required' "$FILES/definition.yaml")" \
  '["management"]' "XRD: spec.management is required"
assert_eq "$(yq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.management | has("default")' "$FILES/definition.yaml")" \
  false "XRD: spec.management has no default (Observe or Full is always written down)"
assert_eq "$(yq -o=json -I=0 '.properties.githubRepos.properties.repositories.additionalProperties.required' "$ADDON/values.schema.json")" \
  '["management"]' "values schema: every githubRepos.repositories entry states management"
if out=$(helm template crossplane "$ADDON" -n crossplane-system --set githubRepos.enabled=true --set githubRepos.owner=o \
  --set githubRepos.repositories.r.description=x 2>&1); then
  assert_eq rendered fails "a repository without management fails the render"
else
  assert_match "$out" "management" "a repository without management fails the render (values schema)"
fi

xrs=()
for f in "$RENDERED_DIR"/addon-crossplane-*.yaml; do
  n=$(basename "$f")
  providers=$(q 'select(.kind == "Provider" and (.spec.package | test("provider-upjet-github"))) | .metadata.name' "$f")
  repos=$(q 'select(.kind == "GitHubRepository") | .metadata.name' "$f")
  if [[ -z "$providers" ]]; then
    assert_eq "$repos$(q 'select(.kind == "CompositeResourceDefinition" and .spec.group == "platform.koorikla.io" and .spec.names.kind == "GitHubRepository") | .kind' "$f")" \
      "" "$n: no GitHub provider, no GitHubRepository API or objects"
    continue
  fi
  case $n in *-mgmt.yaml) ;; *) assert_eq "$n" "a mgmt render" "$n: the GitHub provider runs on mgmt only" ;; esac
  assert_match "$(q 'select(.kind == "Provider" and .metadata.name == "provider-upjet-github") | .spec.package' "$f")" \
    '^xpkg\.crossplane\.io/crossplane-contrib/provider-upjet-github:v[0-9.]+@sha256:[0-9a-f]{64}$' \
    "$n: provider-upjet-github (crossplane-contrib, xpkg.crossplane.io) pinned tag@digest"
  assert_eq "$(q 'select(.kind == "Provider" and .metadata.name == "provider-upjet-github") | .spec.runtimeConfigRef.name' "$f")" \
    provider-github "$n: the provider runs under DeploymentRuntimeConfig provider-github"
  assert_eq "$(q 'select(.kind == "DeploymentRuntimeConfig" and .metadata.name == "provider-github")
    | .spec.deploymentTemplate.spec.template.spec.containers[0].securityContext
    | [.allowPrivilegeEscalation, .readOnlyRootFilesystem, (.capabilities.drop | join(","))] | join(" ")' "$f")" \
    "false true ALL" "$n: provider-github runtime meets Pod Security restricted"
  # MRAP = exactly the managed kinds the Composition + teams template use.
  want=$( ( (grep -E '^ *kind: (Repository|RepositoryRuleset|RepositoryCollaborator)$' "$FILES/composition.yaml" 2>/dev/null || true) \
      | awk '{print tolower($2) "s.repo.github.m.upbound.io"}' | sed 's/ys\./ies./'; \
      printf '%s\n' teams.team.github.m.upbound.io teamrepositories.team.github.m.upbound.io ) \
    | LC_ALL=C sort -u | tr '\n' ' ')
  assert_eq "$(q 'select(.kind == "ManagedResourceActivationPolicy" and .metadata.name == "github") | .spec.activate[]' "$f" | LC_ALL=C sort | tr '\n' ' ')" \
    "$want" "$n: MRAP github activates exactly the composed + team kinds"
  assert_eq "$(q 'select(.kind == "ProviderConfig" and .apiVersion == "github.m.upbound.io/*") | .metadata.name + " " + .spec.credentials.secretRef.name + "/" + .spec.credentials.secretRef.key' "$f")" \
    "github github-repo-admin/credentials" "$n: ProviderConfig github reads Secret github-repo-admin key credentials"
  assert_eq "$(q 'select(.kind == "ExternalSecret" and .metadata.name == "github-repo-admin") | .spec.secretStoreRef.name + " " + ([.spec.data[].remoteRef.key] | unique | join(","))' "$f")" \
    "platform github-repo-admin" "$n: the App credentials come from store platform, key github-repo-admin (bootstrap GITHUB_REPO_ADMIN_APP_*)"
  assert_match "$(q 'select(.kind == "ExternalSecret" and .metadata.name == "github-repo-admin") | .spec.target.template.data.credentials' "$f")" \
    '"app_auth" \(list \(dict "id" \.githubAppID "installation_id" \.githubAppInstallationID "pem_file" \.githubAppPrivateKey\)\)' \
    "$n: provider credentials are app_auth (GitHub App installation tokens), no PAT"
  for kind in CompositeResourceDefinition Composition; do
    file=$([[ $kind == Composition ]] && echo composition || echo definition)
    assert_eq "$(yq "select(.kind == \"$kind\" and .metadata.name == \"$(yq '.metadata.name' "$FILES/$file.yaml")\")" "$f" | yq -o=json -I=0 'del(.metadata.annotations)')" \
      "$(yq -o=json -I=0 'del(.metadata.annotations)' "$FILES/$file.yaml" 2>/dev/null || echo missing)" "$n: the $kind is $FILES/$file.yaml"
  done
  assert_eq "$(q 'select(.kind == "GitHubRepository") | select(.spec.management != "Observe" and .spec.management != "Full") | .metadata.name' "$f")" \
    "" "$n: every GitHubRepository states management Observe or Full"
  yq 'select(.kind == "GitHubRepository")' "$f" > "$TMP/xrs-$n"
  kc "$TMP/xrs-$n" "$n: GitHubRepository objects (XRD schema)"
  while IFS= read -r r; do
    yq "select(.kind == \"GitHubRepository\" and .metadata.name == \"$r\")" "$f" > "$TMP/xr-${n%.yaml}-$r.yaml"
    xrs+=("${n%.yaml}-$r")
  done < <(printf '%s\n' "$repos" | sed '/^$/d')
done
assert_eq "$(q 'select(.kind == "GitHubRepository") | .metadata.name' "$RENDERED_DIR/addon-crossplane-local-mgmt.yaml" | sort | tr '\n' ' ')" \
  "hello-world platform " "local mgmt declares Sparky-stack/platform and Sparky-stack/hello-world"

# --- 2. crossplane render -----------------------------------------------------------------------------------------------
xp_check_docker
XP_IMAGE="$(yq -r '.crossplane.image.repository + ":" + .crossplane.image.tag' "$ADDON/values.yaml" | tr -d '\r')"
# One Docker network and one container per Function for the run (crossplane_render_lib.sh), removed on exit.
xp_render_init koorikla-xp-github
fns=""
for fn in function-go-templating function-auto-ready; do
  fns="${fns}---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: $fn
  annotations:
    render.crossplane.io/runtime-docker-pull-policy: IfNotPresent
    render.crossplane.io/runtime-docker-network: $XP_NET
    render.crossplane.io/runtime-docker-name: $XP_NET-${fn#function-}
    render.crossplane.io/runtime-docker-cleanup: Orphan
spec:
  package: $(yq -r ".packages.functions[\"$fn\"]" "$ADDON/values.yaml" | tr -d '\r')
"
done
printf '%s' "$fns" > "$TMP/functions.yaml"
pkgs=(); read_lines pkgs yq -N -r '.spec.package' "$TMP/functions.yaml"
xp_pull_images "$XP_IMAGE" ${pkgs[@]+"${pkgs[@]}"}

# render <case> <xr> [observed]: composed objects -> $TMP/out-<case>.yaml, XR -> $TMP/xrout-<case>.yaml
render() {
  local c=$1 xr=$2 obs=${3:-} args=()
  [[ -n "$obs" ]] && args=(--observed-resources "$obs")
  if ! retry_with_backoff 2 2 crossplane composition render "$xr" "$FILES/composition.yaml" "$TMP/functions.yaml" \
      --xrd "$FILES/definition.yaml" --crossplane-image "$XP_IMAGE" ${args[@]+"${args[@]}"} > "$TMP/render-$c.yaml" 2> "$TMP/render-$c.err"; then
    cat "$TMP/render-$c.err" >&2
    assert_eq failed ok "crossplane render $c"
    : > "$TMP/out-$c.yaml"; : > "$TMP/xrout-$c.yaml"
    return 0
  fi
  yq 'select(.kind != "GitHubRepository")' "$TMP/render-$c.yaml" > "$TMP/out-$c.yaml"
  yq 'select(.kind == "GitHubRepository")' "$TMP/render-$c.yaml" > "$TMP/xrout-$c.yaml"
  kc "$TMP/out-$c.yaml" "crossplane render $c: composed resources"
  assert_eq "$(q '.status.conditions[] | select(.type == "Synced") | .status' "$TMP/xrout-$c.yaml")" True "crossplane render $c: XR Synced"
}
kinds() { xp_kinds "$1"; }
policies() { q '[.kind, (.spec.managementPolicies | join(","))] | join(":")' "$1" | LC_ALL=C sort -u | tr '\n' ' '; }
RULESET='select(.kind == "RepositoryRuleset") | .spec.forProvider'

# Every repository the installations declare: Observe-only unless its declaration says `management: Full`, and even
# then never deleted.
for c in ${xrs[@]+"${xrs[@]}"}; do
  render "$c" "$TMP/xr-$c.yaml"
  mode=$(q '.spec.management' "$TMP/xr-$c.yaml")
  if [[ "$mode" == Observe ]]; then
    bad=$(q 'select((.spec.managementPolicies | join(",")) != "Observe") | .kind + "/" + .metadata.annotations["gotemplating.fn.crossplane.io/composition-resource-name"]' "$TMP/out-$c.yaml")
    assert_eq "$bad" "" "$c (Observe): every composed object is managementPolicies [Observe] (zero writes to GitHub)"
  else
    bad=$(q 'select(.spec.managementPolicies | any_c(test("^(Delete|[*])$"))) | .kind' "$TMP/out-$c.yaml")
    assert_eq "$bad" "" "$c ($mode, switched explicitly): nothing composed may be deleted on GitHub"
  fi
  assert_eq "$(q 'select(.kind == "Repository") | .metadata.annotations["crossplane.io/external-name"]' "$TMP/out-$c.yaml")" \
    "${c##*-mgmt-}" "$c: observes the existing repository by name (external-name)"
done
# The local declarations in Observe (as shipped; the shape checks below hold after a switch too).
for r in platform hello-world; do
  yq '.spec.management = "Observe"' "$TMP/xr-addon-crossplane-local-mgmt-$r.yaml" > "$TMP/xr-observe-$r.yaml"
done
render observe-platform "$TMP/xr-observe-platform.yaml" "$FIX/observed-platform.yaml"
assert_eq "$(kinds "$TMP/out-observe-platform.yaml")" "Repository=1 RepositoryRuleset=1 " \
  "platform (Observe, rulesetId): the repository and its existing ruleset, nothing else"
assert_eq "$(q 'select(.kind == "RepositoryRuleset") | .metadata.annotations["crossplane.io/external-name"]' "$TMP/out-observe-platform.yaml")" \
  27395845 "platform: observes the hand-made ruleset 27395845"
assert_eq "$(q '.status.url' "$TMP/xrout-observe-platform.yaml")" https://github.com/Sparky-stack/platform \
  "platform: XR status.url from the observed repository (status.atProvider.htmlUrl)"
render observe-hello "$TMP/xr-observe-hello-world.yaml"
assert_eq "$(kinds "$TMP/out-observe-hello.yaml")" "Repository=1 " \
  "hello-world (Observe, no ruleset yet): only the repository (no ruleset to observe)"
render observe-collaborator "$FIX/xr-observe-collaborator.yaml"
assert_eq "$(policies "$TMP/out-observe-collaborator.yaml")" "Repository:Observe RepositoryCollaborator:Observe " \
  "Observe with a collaborator: the collaborator is observed too, read-only"

# Full: a new repository (scaffolder path) and an adopted existing one.
render full-new "$FIX/xr-full-new.yaml"
F=$TMP/out-full-new.yaml
assert_eq "$(kinds "$F")" "Repository=1 RepositoryCollaborator=2 RepositoryRuleset=1 " "Full: repository, ruleset, one collaborator each"
assert_eq "$(policies "$F")" \
  "Repository:Observe,Create,Update,LateInitialize RepositoryCollaborator:Observe,Create,Update,LateInitialize RepositoryRuleset:Observe,Create,Update,LateInitialize " \
  "Full: Observe, Create, Update, LateInitialize on every object, never Delete"
assert_eq "$(q 'select(.kind == "Repository") | .spec.forProvider | [.visibility, .allowSquashMerge, .allowMergeCommit, .allowRebaseMerge, .deleteBranchOnMerge, .vulnerabilityAlerts, .securityAndAnalysis[0].secretScanningPushProtection[0].status] | join(" ")' "$F")" \
  "private true false false true true enabled" "Full: squash only, branches deleted on merge, Dependabot alerts, push protection"
assert_eq "$(q 'select(.kind == "RepositoryRuleset") | .metadata.annotations | has("crossplane.io/external-name")' "$F")" false \
  "Full without rulesetId: a new ruleset (GitHub assigns the ID)"
assert_eq "$(q "$RULESET | .conditions[0].refName[0].include[0] + \" \" + .target + \" \" + .enforcement" "$F")" \
  "~DEFAULT_BRANCH branch active" "ruleset: the default branch, enforced"
assert_eq "$(q "$RULESET | .rules[0] | [.deletion, .nonFastForward, .requiredLinearHistory] | join(\" \")" "$F")" \
  "true true true" "ruleset: no deletion, no force push, linear history"
assert_eq "$(q "$RULESET | .rules[0].pullRequest[0] | [.requiredApprovingReviewCount, .requireCodeOwnerReview, .dismissStaleReviewsOnPush, .requiredReviewThreadResolution, (.allowedMergeMethods | join(\",\"))] | join(\" \")" "$F")" \
  "0 true true true squash" "ruleset: pull requests (0 approvals, code-owner review, stale dismissal, resolved threads, squash)"
assert_eq "$(q "$RULESET | .rules[0].requiredStatusChecks[0].requiredCheck[] | .context + \"@\" + (.integrationId | tostring)" "$F" | tr '\n' ';')" \
  "checks / vet, lint, test, govulncheck@15368;checks / manifests / OpenChoreo manifests@15368;" \
  "ruleset: the declared checks, pinned to the GitHub Actions app (15368)"
assert_eq "$(q "$RULESET | .bypassActors[] | .actorType + \":\" + (.actorId | tostring) + \":\" + .bypassMode" "$F" | tr '\n' ' ')" \
  "Integration:5788333:always RepositoryRole:5:pull_request " \
  "ruleset bypass: the bump App always (hand-off commits, releases, promotion PRs), platform-engineers by pull request only"
assert_eq "$(q 'select(.kind == "RepositoryCollaborator") | .metadata.annotations["crossplane.io/external-name"] + "=" + .spec.forProvider.permission' "$F" | tr '\n' ' ')" \
  "orders-api:alice=push orders-api:Bob=push " "collaborators: write access, external-name <repo>:<user>"
render full-adopt "$FIX/xr-full-adopt.yaml"
assert_eq "$(q 'select(.kind == "RepositoryRuleset") | .metadata.annotations["crossplane.io/external-name"] + " " + (.spec.managementPolicies | join(","))' "$TMP/out-full-adopt.yaml")" \
  "27395845 Observe,Create,Update,LateInitialize" "Full with rulesetId: rewrites the existing ruleset in place (no second ruleset)"
assert_eq "$(q "$RULESET | .rules[0] | has(\"requiredStatusChecks\")" "$TMP/out-full-new.yaml")" true "ruleset: checks rule present when checks are declared"
yq '.spec.requiredChecks = []' "$FIX/xr-full-adopt.yaml" > "$TMP/xr-nochecks.yaml"
render full-nochecks "$TMP/xr-nochecks.yaml"
assert_eq "$(q "$RULESET | .rules[0] | has(\"requiredStatusChecks\")" "$TMP/out-full-nochecks.yaml")" false \
  "ruleset: no required-checks rule without declared checks (an empty rule would block every merge)"

echo "=== 3. Four GitHub org teams (Team + TeamRepository) ==="
local_val="$ROOT/installations/local/addons/crossplane/cluster-mgmt.yaml"
for team in developers qa release-managers platform-engineers; do
  assert_eq "$(t="$team" yq '.githubRepos.teams[strenv(t)].repositories | length >= 1' "$local_val")" true "local team $team has repositories"
done
teams_out="$TMP/teams.yaml"
helm template crossplane "$ROOT/$ADDON" -f "$ROOT/$ADDON/values/role-mgmt.yaml" -f "$local_val" -s templates/github-repos.yaml >"$teams_out"
assert_eq "$(yq ea '[select(.kind == "Team")] | length' "$teams_out")" "4" "local renders 4 Team objects"
assert_eq "$(yq ea '[select(.kind == "Team") | select(.spec.forProvider.privacy != "closed")] | length' "$teams_out")" "0" "all Teams have privacy closed"
assert_eq "$(yq ea '[select(.kind == "Team") | select(.spec.managementPolicies[] == "Delete")] | length' "$teams_out")" "0" "Team excludes Delete policy"
assert_eq "$(yq ea '[select(.kind == "TeamRepository")] | length' "$teams_out")" "8" "local renders 8 TeamRepository objects"
assert_eq "$(yq ea '[select(.kind == "TeamRepository") | select(.spec.managementPolicies[] == "Delete")] | length' "$teams_out")" "0" "TeamRepository excludes Delete policy"
finish
