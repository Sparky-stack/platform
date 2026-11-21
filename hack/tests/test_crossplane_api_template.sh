#!/usr/bin/env bash
# Contract: the platform API golden path templates/crossplane-api (docs/project-templates.md, docs/crossplane.md
# "Inner loop"): a Backstage Template that scaffolds a repository with the `crossplane project init` layout and the
# reusable workflow app-crossplane-configuration.yaml wired.
#   - same day-0 rules as the service templates (hack/tests/test_project_templates.sh): allowed actions only, no token,
#     publish:github sets no governance, a governance record PR to koorikla/platform, catalog:register;
#   - renders offline (hack/tests/render_template.py): crossplane-project.yaml, apis/api/ XRD + Composition consistent
#     with the parameters and the example XR (kubeconform with the Crossplane CRD schemas), the Composition calls the
#     embedded function the project build names (<owner>-<name> + functions/compose), CI pins the workflow by SHA at a
#     ci-vX.Y.Z release whose scripts build Crossplane Projects;
#   - TEMPLATES_BUILD=1 (CI workflow templates.yaml; needs docker + network): `crossplane composition render` of the
#     example (project mode: builds the embedded function) and `crossplane project build` of the rendered repository.
# shellcheck disable=SC2016  # literal ${{ ... }} template expressions in single quotes
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"
cd "$ROOT"

T=crossplane-api; f=templates/$T/template.yaml
ALLOWED_ACTIONS="catalog:register fetch:template fetch:template:file publish:github publish:github:pull-request"
PUBLISH_INPUTS="defaultBranch description gitCommitMessage protectDefaultBranch repoUrl repoVisibility"
SHA_USES_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@]+)?@[0-9a-f]{40}$'
SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
if [[ ! -d "$SCHEMAS_DIR/apiextensions.crossplane.io" ]]; then
  ./hack/deps.sh >/dev/null
  SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
fi
words_in() { local w; for w in $1; do [[ " $2 " == *" $w "* ]] || { echo "$w"; return 0; }; done; echo; }
q() { yq -r "explode(.) | $1" "$f"; }

# --- template entity ---------------------------------------------------------------------------------------------
assert_eq "$(q '.apiVersion + " " + .kind + " " + .metadata.name + " " + .spec.type')" "scaffolder.backstage.io/v1beta3 Template $T platform-api" "$T: scaffolder Template, type platform-api"
assert_eq "$(yq -r '.spec.targets[]' templates/catalog-info.yaml | grep -cx "./$T/template.yaml")" 1 "$T: listed in the catalog Location"
assert_eq "$(q '.metadata.annotations["platform.koorikla.io/stack"] + " " + .metadata.annotations["platform.koorikla.io/ci-workflow"]')" "crossplane app-crossplane-configuration.yaml" "$T: stack + CI workflow annotations"
assert_eq "$(words_in "$(q '.spec.steps[].action' | sort -u | tr '\n' ' ')" "$ALLOWED_ACTIONS")" "" "$T: only actions the OpenChoreo 1.3.3 Backstage registers"
assert_eq "$(q '[.. | select(tag == "!!map") | select(has("token"))] | length')" 0 "$T: no token input (GitHub App integration)"
assert_eq "$(words_in "$(q '.spec.steps[] | select(.action == "publish:github") | .input | keys | .[]' | tr '\n' ' ')" "$PUBLISH_INPUTS")" "" "$T: publish:github sets no repo governance (#100)"
assert_eq "$(q '.spec.steps[] | select(.action == "publish:github") | .input.protectDefaultBranch')" false "$T: protectDefaultBranch false"
assert_eq "$(q '.spec.steps[] | select(.action == "publish:github:pull-request") | .input.repoUrl')" "github.com?owner=koorikla&repo=platform" "$T: governance record is a PR to the platform repo"
assert_eq "$(q '.spec.steps[] | select(.action == "catalog:register") | .input.catalogInfoPath')" /catalog-info.yaml "$T: catalog:register the repo's catalog-info.yaml"
assert_eq "$(q '[.spec.steps[] | select(.id == "fetch-project") | .input.copyWithoutTemplating[]] | join(" ")')" ".github/workflows/* functions/compose/*" "$T: workflows and go-templates copied verbatim"
assert_eq "$(q '[.spec.steps[].id] | join(" ")')" "fetch-project publish fetch-platform-repo platform-pr register" "$T: no tenant/OpenChoreo steps (a platform API is not a service)"

# --- render --------------------------------------------------------------------------------------------------------
printf '{"name":"sample-api","description":"Sample \\"quoted\\" API: golden path","kind":"SampleWidget","plural":"samplewidgets","group":"platform.koorikla.io","owner":"group:default/openchoreo-users","project":"demo","installation":"local","repoOwner":"Koorikla","visibility":"public","codeowners":"@koorikla @octocat"}' > "$TMP/params.json"
yq -o=json 'explode(.)' "$f" > "$TMP/t.json"
R=$TMP/render
if py hack/tests/render_template.py "templates/$T" "$TMP/t.json" "$TMP/params.json" "$R" > "$TMP/render.log" 2>&1; then ok=yes; else ok=no; cat "$TMP/render.log" >&2; fi
assert_eq "$ok" yes "$T: renders"
[[ "$ok" == yes ]] || { finish; exit 1; }
bad=""
while IFS= read -r -d '' y; do yq '.' "$y" >/dev/null 2>&1 || bad="$bad ${y#"$R"/}"; done < <(find "$R" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
py -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$R/renovate.json" >/dev/null 2>&1 || bad="$bad renovate.json"
assert_eq "$bad" "" "$T: every rendered YAML/JSON file parses"
for p in crossplane-project.yaml apis/api/definition.yaml apis/api/composition.yaml examples/example.yaml \
  functions/compose/00-prelude.yaml.gotmpl operations/.gitkeep tests/.gitkeep .gitignore mise.toml catalog-info.yaml \
  .github/CODEOWNERS .github/workflows/ci.yaml renovate.json SECURITY.md README.md; do
  assert_eq "$([[ -e "$R/$p" ]] && echo yes)" yes "$T: has $p (crossplane project init layout + golden-path files)"
done
assert_eq "$(find "$R" -path '*/deploy/*' -o -name 'Dockerfile' | head -n1)" "" "$T: no OpenChoreo deploy/ or Dockerfile"
pf=$R/crossplane-project.yaml; xrd=$R/apis/api/definition.yaml; comp=$R/apis/api/composition.yaml; ex=$R/examples/example.yaml
assert_eq "$(yq -r '.apiVersion + " " + .kind + " " + .metadata.name + " " + .spec.repository' "$pf")" "dev.crossplane.io/v1alpha1 Project sample-api ghcr.io/koorikla/sample-api" "$T: Project sample-api, repository = what CI pushes (owner lowercased)"
assert_eq "$(yq -r '.spec.description' "$pf")" 'Sample "quoted" API: golden path' "$T: description survives quoting"
assert_eq "$(yq -r '.metadata.name + " " + .spec.scope + " " + .spec.names.kind' "$xrd")" "samplewidgets.platform.koorikla.io Namespaced SampleWidget" "$T: XRD <plural>.<group>, namespaced"
assert_eq "$(yq -r '.spec.compositeTypeRef.apiVersion + " " + .spec.compositeTypeRef.kind' "$comp")" "$(yq -r '.apiVersion + " " + .kind' "$ex")" "$T: Composition composes the example's type"
assert_eq "$(yq -r '.spec.group + "/" + .spec.versions[0].name' "$xrd")" "$(yq -r '.apiVersion' "$ex")" "$T: example XR uses the XRD's group/version"
assert_eq "$(yq -r '[.spec.pipeline[].functionRef.name] | join(" ")' "$comp")" "koorikla-sample-apicompose crossplane-contrib-function-auto-ready" \
  "$T: pipeline = embedded function (name crossplane project build derives) + auto-ready"
assert_eq "$(yq -r '.spec.dependencies[].xpkg.package' "$pf")" "xpkg.crossplane.io/crossplane-contrib/function-auto-ready" "$T: auto-ready is a project dependency"
assert_eq "$(kc_valid "$xrd" "$comp")" yes "$T: XRD + Composition pass kubeconform -strict (Crossplane CRDs)"
assert_eq "$(grep -cxE '_output/|schemas/|\.cache/' "$R/.gitignore")" 3 "$T: generated dirs gitignored"
assert_eq "$(sed -n 's/^crossplane *= *"\(.*\)"/\1/p' "$R/mise.toml")" "$(sed -n 's/^crossplane *= *"\([^"]*\)".*/\1/p' mise.toml)" "$T: skeleton pins the platform's Crossplane CLI"
assert_eq "$(grep -v '^#' "$R/.github/CODEOWNERS")" "* @koorikla @octocat" "$T: CODEOWNERS from the parameter"
assert_eq "$(yq -r '.kind + " " + .spec.type + " " + .spec.owner' "$R/catalog-info.yaml")" "Resource crossplane-configuration group:default/openchoreo-users" "$T: catalog Resource"
rec=$R/platform/installations/local/repos/sample-api.yaml
assert_eq "$(yq -r '.kind + " " + .spec.tenant + " " + .spec.framework' "$rec" 2>/dev/null)" "GitHubRepository demo crossplane" "$T: governance record for #100"
assert_eq "$(find "$R/platform" -type f | wc -l | tr -d ' ')" 1 "$T: the platform PR carries only the governance record"

# --- CI caller -------------------------------------------------------------------------------------------------------
wf=$R/.github/workflows/ci.yaml
uses=$(yq -r '.jobs[] | select(.uses) | .uses' "$wf")
assert_match "$uses" '^koorikla/platform/\.github/workflows/app-crossplane-configuration\.yaml@[0-9a-f]{40}$' "$T: calls app-crossplane-configuration.yaml by commit SHA"
tag=$(sed -n 's|.*uses: koorikla/platform/[^ ]*@[0-9a-f]\{40\} # \(ci-v[0-9]*\.[0-9]*\.[0-9]*\)$|\1|p' "$wf")
assert_match "$tag" '^ci-v[0-9]+\.[0-9]+\.[0-9]+$' "$T: SHA carries a '# ci-vX.Y.Z' comment (Renovate)"
assert_eq "$(yq -r '.jobs.package.with.package_root' "$wf")" . "$T: package_root is the repository root"
sha=${uses##*@}
if git cat-file -e "$sha^{commit}" 2>/dev/null; then   # shallow CI checkouts lack the commit: then only the shape is checked
  n=$(git show "$sha:ci/scripts/crossplane/xpkg-build.sh" 2>/dev/null | grep -c 'crossplane project build' || true)
  assert_eq "$([[ "$n" -gt 0 ]] && echo yes || echo no)" yes "$T: pinned workflow commit builds Crossplane Projects (xpkg-build.sh)"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    assert_eq "$(git rev-list -n1 "$tag")" "$sha" "$T: $tag is the pinned commit"
  fi
fi
bad=""
for u in $(yq -r '.jobs[].steps[]?.uses // ""' "$wf"); do [[ "$u" =~ $SHA_USES_RE ]] || bad="$bad $u"; done
assert_eq "$bad" "" "$T: every action pinned by commit SHA"
if command -v actionlint >/dev/null 2>&1; then
  if out=$(cd "$R" && actionlint -no-color .github/workflows/ci.yaml 2>&1); then ok=yes; else ok=no; echo "$out" >&2; fi
  assert_eq "$ok" yes "$T: actionlint"
fi

# --- optional: render + build with the Crossplane CLI ----------------------------------------------------------------
if [[ "${TEMPLATES_BUILD:-0}" == 1 ]]; then
  if (cd "$R" && crossplane composition render examples/example.yaml apis/api/composition.yaml --timeout 10m > "$TMP/xr.yaml" 2> "$TMP/xr.err"); then ok=yes; else ok=no; tail -n 5 "$TMP/xr.err" >&2; fi
  assert_eq "$ok" yes "$T: crossplane composition render of the example (embedded function built from functions/compose)"
  assert_eq "$(yq -r 'select(.kind == "ConfigMap") | .metadata.name + " " + .data.size' "$TMP/xr.yaml")" "example-settings small" "$T: the sample composes its ConfigMap"
  if (cd "$R" && crossplane project build -o "$TMP/out" > "$TMP/build.log" 2>&1); then ok=yes; else ok=no; tail -n 5 "$TMP/build.log" >&2; fi
  assert_eq "$ok" yes "$T: crossplane project build"
  assert_eq "$(tar -xOf "$TMP/out/sample-api.xpkg" manifest.json 2>/dev/null | yq -p=json -oy -r '[.[].RepoTags[0]] | sort | join(" ")')" \
    "ghcr.io/koorikla/sample-api:configuration ghcr.io/koorikla/sample-api_compose:amd64 ghcr.io/koorikla/sample-api_compose:arm64" "$T: xpkg = Configuration + embedded function"
else
  echo "  SKIP crossplane render + project build of the rendered repository (TEMPLATES_BUILD=1; CI workflow templates.yaml)"
fi

finish
