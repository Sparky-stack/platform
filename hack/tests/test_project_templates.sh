#!/usr/bin/env bash
# Contract: golden-path project templates (templates/, docs/project-templates.md), Backstage scaffolder entities that
# OpenChoreo's Backstage loads from templates/catalog-info.yaml.
#   - the catalog Location lists exactly templates/*/template.yaml; every template shares parameters and steps (only
#     metadata, the stack skeleton and the stack name differ) and uses only actions the OpenChoreo 1.3.3 image ships;
#   - day-0 only (koorikla/platform#100): publish:github gets no token (the platform write GitHub App is the
#     integration credential, no PAT), protectDefaultBranch false and nothing else that sets repo governance;
#   - every template renders offline (hack/tests/render_template.py, the subset of nunjucks skeletons may use) with
#     and without a new tenant; the result: YAML/JSON parse, deploy/openchoreo passes kubeconform -strict with the
#     OpenChoreo CRD schemas, the tenant file renders through charts/tenant, the CI caller pins koorikla/ci by SHA,
#     Dockerfiles pin every base by digest and run non-root on distroless/Chainguard, the Workload bump script works;
#   - TEMPLATES_BUILD=1 (CI workflow templates.yaml; needs docker): `docker build` of every rendered skeleton (the
#     build stage runs its linters and unit tests) and a smoke test of GET /healthz on a read-only, non-root container.
# TEMPLATES_ONLY="go-service ..." limits rendering/building to those templates (CI matrix).
# shellcheck disable=SC2016  # literal ${{ ... }} template expressions in single quotes
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_project_templates =="
cd "$ROOT"

# Scaffolder actions registered in openchoreo-ui v1.3.3 (backend features of @openchoreo/backstage-portal-backend:
# scaffolder-backend built-ins + scaffolder-backend-module-github). Golden paths need only these four.
ALLOWED_ACTIONS="catalog:register fetch:template publish:github publish:github:pull-request"
# publish:github inputs a template may set. Everything else (branch protection, required checks/reviews, collaborators,
# merge settings, secrets, environments) is repo governance: declared in installations/<inst>/repos/ and reconciled by
# Crossplane (#100), never set imperatively at creation. No `token`: the GitHub App integration authenticates.
PUBLISH_INPUTS="defaultBranch description gitCommitMessage protectDefaultBranch repoUrl repoVisibility"
# Stacks whose koorikla/ci workflow is not released yet: <template>|<workflow>|<tracking issue>. Their CI caller uses
# container.yaml (the Dockerfile build stage runs the tests) and carries `TODO(<issue>)`. Drop a line when the
# workflow exists and the skeleton calls it by SHA; a stale line fails below.
PENDING_CI=(
  "python-service|python.yaml|koorikla/ci#1"
  "node-fastify-service|node.yaml|koorikla/ci#2"
  "rust-service|rust.yaml|koorikla/ci#3"
  "java-quarkus-service|java.yaml|koorikla/ci#4"
)
PIN_RE='^([a-z0-9-]+(\.[a-z0-9-]+)+)(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]{1,128})?@sha256:[0-9a-f]{64}$'
SHA_USES_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@]+)?@[0-9a-f]{40}$'
BUSYBOX=docker.io/library/busybox:1.38.0-musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
[[ -d "$SCHEMAS_DIR/openchoreo.dev" ]] || SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
KC_ARGS=(-strict -summary -kubernetes-version 1.35.0 -schema-location default
  -schema-location "$SCHEMAS_DIR/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json")
kc() { local out; if out=$(kubeconform "${KC_ARGS[@]}" "$@" 2>&1); then echo yes; else echo "$out" >&2; echo no; fi; }
# assert_same <label> <expected> <actual>: like assert_eq for long JSON documents; prints a short diff on mismatch
assert_same() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); return 0; fi
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s, diff (expected vs actual):\n' "$1" >&2
  diff <(printf '%s' "$2" | yq -P '.') <(printf '%s' "$3" | yq -P '.') | head -n 20 >&2 || true
}
words_in() { local w; for w in $1; do [[ " $2 " == *" $w "* ]] || { echo "$w"; return 0; }; done; echo; }

TRUSTED_CI_SHA=$(yq -r '.imageVerification.github.workflowRef' addons/kyverno-policies/values.yaml)
TEMPLATES=()
for d in templates/*/template.yaml; do
  t=${d#templates/}; t=${t%/template.yaml}
  [[ "$t" == _* ]] || TEMPLATES+=("$t")
done
assert_eq "$([[ ${#TEMPLATES[@]} -ge 6 ]] && echo yes)" yes "at least the first batch of templates exists (${#TEMPLATES[@]})"
selected() { [[ -z "${TEMPLATES_ONLY:-}" || " $TEMPLATES_ONLY " == *" $1 "* ]]; }

# --- renderer: the subset of nunjucks it accepts (negative cases first) ------------------------------------------
neg="$TMP/neg"; mkdir -p "$neg/skel/.github/workflows"
render_neg() {   # <label> <file content> [verbatim file content]
  rm -rf "$neg/skel" "$neg/out"; mkdir -p "$neg/skel/.github/workflows"
  printf '%s\n' "$2" > "$neg/skel/f.txt"
  [[ -z "${3:-}" ]] || printf '%s\n' "$3" > "$neg/skel/.github/workflows/ci.yaml"
  printf '%s' '{"spec":{"steps":[{"id":"s","action":"fetch:template","input":{"url":"./skel","values":{"name":"${{ parameters.name }}"},"copyWithoutTemplating":[".github/workflows/*"]}}]}}' > "$neg/t.json"
  printf '%s' '{"name":"x"}' > "$neg/p.json"
  if py hack/tests/render_template.py "$neg" "$neg/t.json" "$neg/p.json" "$neg/out" >/dev/null 2>&1; then echo rendered; else echo refused; fi
}
assert_eq "$(render_neg ok 'n=${{ values.name }} j=${{ values.name | dump }}' 'run: ${{ github.sha }}')" rendered "renderer: values, dump and verbatim workflow expressions render"
assert_eq "$(cat "$neg/out/f.txt")" 'n=x j="x"' "renderer: substitutes values (dump = JSON string)"
assert_eq "$(render_neg block '{% if values.name %}x{% endif %}')" refused "renderer: refuses nunjucks blocks in skeletons"
assert_eq "$(render_neg comment 'echo ${#arr[@]}')" refused "renderer: refuses '{#' (nunjucks comment start, e.g. bash \${#x})"
assert_eq "$(render_neg unknown '${{ values.nope }}')" refused "renderer: refuses unknown values"
assert_eq "$(render_neg expr '${{ parameters.name }}')" refused "renderer: refuses other expressions in skeletons"
assert_eq "$(render_neg verbatim 'ok' 'name: ${{ values.name }}')" refused "renderer: refuses values in copyWithoutTemplating files"

# --- catalog Location --------------------------------------------------------------------------------------------
assert_eq "$(yq -r '.kind' templates/catalog-info.yaml)" Location "templates/catalog-info.yaml is a Location"
want=$(for t in "${TEMPLATES[@]}"; do echo "./$t/template.yaml"; done | sort)
assert_eq "$(yq -r '.spec.targets[]' templates/catalog-info.yaml | sort)" "$want" "Location targets == templates/*/template.yaml"

# --- template entities -------------------------------------------------------------------------------------------
REF=go-service
norm_steps() {   # steps with the template's own name and stack replaced, the stack skeleton step's title dropped
  local t=$1 stack
  stack=$(yq -r '.metadata.annotations["platform.koorikla.io/stack"]' "templates/$t/template.yaml")
  yq -o=json -I=0 'explode(.) | .spec.steps | (.[] | select(.id == "fetch-stack")) |= del(.name)' "templates/$t/template.yaml" \
    | sed -e "s/$t/TEMPLATE/g" -e "s/\"stack\":\"$stack\"/\"stack\":\"STACK\"/g"
}
ref_params=$(yq -o=json -I=0 'explode(.) | .spec.parameters' "templates/$REF/template.yaml")
ref_steps=$(norm_steps "$REF")
for t in "${TEMPLATES[@]}"; do
  f="templates/$t/template.yaml"
  q() { yq -r "explode(.) | $1" "$f"; }
  assert_eq "$(q '.apiVersion + " " + .kind')" "scaffolder.backstage.io/v1beta3 Template" "$t: scaffolder Template v1beta3"
  assert_eq "$(q '.metadata.name')" "$t" "$t: metadata.name == directory"
  stack=$(q '.metadata.annotations["platform.koorikla.io/stack"]')
  assert_nonempty "$stack" "$t: annotation platform.koorikla.io/stack"
  assert_eq "$(q '[.spec.steps[] | select(.id == "fetch-base" or .id == "fetch-platform-repo") | .input.values.stack] | unique | join(",")')" "$stack" "$t: skeletons get stack=$stack"
  assert_same "$t: parameters == $REF's" "$ref_params" "$(yq -o=json -I=0 'explode(.) | .spec.parameters' "$f")"
  assert_same "$t: steps == $REF's (except name, stack and stack skeleton)" "$ref_steps" "$(norm_steps "$t")"
  assert_eq "$(words_in "$(q '.spec.steps[].action' | sort -u | tr '\n' ' ')" "$ALLOWED_ACTIONS")" "" "$t: only actions the OpenChoreo 1.3.3 Backstage registers"
  assert_eq "$(q '[.. | select(tag == "!!map") | select(has("token"))] | length')" 0 "$t: no token input anywhere (GitHub App integration, no PAT)"
  assert_eq "$(words_in "$(q '.spec.steps[] | select(.action == "publish:github") | .input | keys | .[]' | tr '\n' ' ')" "$PUBLISH_INPUTS")" "" "$t: publish:github sets no repo governance (#100)"
  assert_eq "$(q '.spec.steps[] | select(.action == "publish:github") | .input.protectDefaultBranch')" false "$t: publish:github protectDefaultBranch: false (its default would set branch protection)"
  assert_eq "$(q '.spec.steps[] | select(.action == "publish:github:pull-request") | .input.repoUrl')" "github.com?owner=koorikla&repo=platform" "$t: tenant wiring is a PR to the platform repo"
  assert_eq "$(q '.spec.steps[] | select(.action == "catalog:register") | .input.catalogInfoPath')" /catalog-info.yaml "$t: catalog:register the repo's catalog-info.yaml"
  assert_eq "$(q '.spec.steps[] | select(.id == "fetch-stack") | .input.url')" ./skeleton "$t: stack skeleton ./skeleton"
  assert_eq "$(q '.spec.steps[] | select(.id == "fetch-stack") | .input.copyWithoutTemplating[]')" '.github/workflows/*' "$t: workflows copied without templating"
  assert_eq "$(q '.spec.steps[] | select(.id == "fetch-base") | .input.url')" ../_shared/skeleton "$t: shared skeleton"
done

# --- render + check every template --------------------------------------------------------------------------------
pending_for() { local e; for e in "${PENDING_CI[@]}"; do [[ "${e%%|*}" == "$1" ]] && { echo "$e"; return 0; }; done; echo; }
for e in "${PENDING_CI[@]}"; do
  assert_eq "$([[ -f "templates/${e%%|*}/template.yaml" ]] && echo yes)" yes "PENDING_CI ${e%%|*} is a template"
done
params() {   # <newTenant>
  printf '{"name":"sample-svc","description":"Sample \\"quoted\\" service: golden path","owner":"group:default/openchoreo-users","project":"demo","newTenant":%s,"installation":"local","repoOwner":"koorikla","visibility":"public","codeowners":"@koorikla @octocat"}' "$1"
}
params true > "$TMP/params-new.json"; params false > "$TMP/params-existing.json"
yq -o=json '.' installations/local/installation.yaml > /dev/null

for t in "${TEMPLATES[@]}"; do
  selected "$t" || continue
  R="$TMP/render/$t"; mkdir -p "$TMP/render"
  yq -o=json 'explode(.)' "templates/$t/template.yaml" > "$TMP/$t.json"
  if py hack/tests/render_template.py "templates/$t" "$TMP/$t.json" "$TMP/params-new.json" "$R" > "$TMP/$t.render.log" 2>&1; then ok=yes; else ok=no; cat "$TMP/$t.render.log" >&2; fi
  assert_eq "$ok" yes "$t: renders (new tenant)"
  [[ "$ok" == yes ]] || continue
  if py hack/tests/render_template.py "templates/$t" "$TMP/$t.json" "$TMP/params-existing.json" "$TMP/render-existing/$t" >/dev/null 2>&1; then ok=yes; else ok=no; fi
  assert_eq "$ok" yes "$t: renders (existing tenant)"
  assert_eq "$([[ -e "$TMP/render-existing/$t/platform/installations/local/tenants/demo.yaml" ]] && echo present || echo absent)" absent "$t: existing tenant: the PR does not overwrite the tenant file"
  stack=$(yq -r '.metadata.annotations["platform.koorikla.io/stack"]' "templates/$t/template.yaml")

  # every YAML / JSON file parses
  bad=""
  while IFS= read -r -d '' y; do yq '.' "$y" >/dev/null 2>&1 || bad="$bad ${y#"$R"/}"; done < <(find "$R" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
  while IFS= read -r -d '' j; do py -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$j" >/dev/null 2>&1 || bad="$bad ${j#"$R"/}"; done < <(find "$R" -type f -name '*.json' -print0)
  assert_eq "$bad" "" "$t: every rendered YAML/JSON file parses"

  # repository content
  for p in catalog-info.yaml .github/CODEOWNERS renovate.json SECURITY.md README.md Dockerfile .github/workflows/ci.yaml \
    deploy/openchoreo/component.yaml deploy/openchoreo/workload.yaml hack/bump-workload.py hack/validate-manifests.py \
    deploy/openchoreo/release-bindings/development.yaml deploy/openchoreo/release-bindings/staging.yaml \
    deploy/openchoreo/release-bindings/production.yaml; do
    assert_eq "$([[ -s "$R/$p" ]] && echo yes)" yes "$t: has $p"
  done
  assert_eq "$(kc "$R/deploy/openchoreo")" yes "$t: deploy/openchoreo passes kubeconform -strict (OpenChoreo CRDs)"
  assert_eq "$(yq -r 'select(.kind == "Component") | .metadata.name + " " + .spec.owner.projectName' "$R/deploy/openchoreo/component.yaml")" "sample-svc demo" "$t: Component sample-svc in project demo"
  assert_eq "$(yq -r '.spec.container.image' "$R/deploy/openchoreo/workload.yaml")" "ghcr.io/koorikla/sample-svc:main" "$t: Workload names the image CI publishes"
  assert_eq "$(yq -r '.kind + " " + .metadata.name + " " + .spec.dependencyOf[0]' "$R/catalog-info.yaml")" "Resource sample-svc-repo component:default/sample-svc" "$t: catalog-info is a Resource pointing at OpenChoreo's Component (no duplicate Component ref)"
  assert_eq "$(grep -v '^#' "$R/.github/CODEOWNERS")" "* @koorikla @octocat" "$t: CODEOWNERS from the parameter"

  # Workload bump script (CI job `bump`): first bump adds the commit, the result stays valid; bad input refused
  cp "$R/deploy/openchoreo/workload.yaml" "$TMP/wl.yaml"
  img="ghcr.io/koorikla/sample-svc:abc1234@sha256:$(printf 'a%.0s' $(seq 64))"
  bump_out=$(cd "$R" && NEW_IMAGE="$img" NEW_COMMIT=abc1234def py hack/bump-workload.py 2>&1) || true
  assert_eq "$(yq -r '.spec.container.image + " " + .spec.source.commit' "$R/deploy/openchoreo/workload.yaml")" "$img abc1234def" "$t: bump-workload pins image and commit ($bump_out)"
  assert_eq "$(kc "$R/deploy/openchoreo/workload.yaml")" yes "$t: bumped Workload passes kubeconform -strict"
  if (cd "$R" && NEW_IMAGE=ghcr.io/koorikla/sample-svc:main NEW_COMMIT=abc1234 py hack/bump-workload.py >/dev/null 2>&1); then r=accepted; else r=refused; fi
  assert_eq "$r" refused "$t: bump-workload refuses an image without digest"
  cp "$TMP/wl.yaml" "$R/deploy/openchoreo/workload.yaml"

  # CI caller: koorikla/ci by SHA (# v1); every action pinned by SHA; actionlint
  wf="$R/.github/workflows/ci.yaml"
  ci_uses=$(yq -r '.jobs[] | select(.uses) | .uses' "$wf")
  assert_match "$ci_uses" '^koorikla/ci/\.github/workflows/[a-z-]+\.yaml@[0-9a-f]{40}$' "$t: build job calls koorikla/ci by commit SHA"
  assert_eq "$(grep -cE 'uses: koorikla/ci/[^ ]+@[0-9a-f]{40} # v1$' "$wf")" 1 "$t: koorikla/ci SHA carries the '# v1' tag comment (Renovate)"
  assert_eq "${ci_uses##*@}" "$TRUSTED_CI_SHA" "$t: koorikla/ci SHA == the commit Kyverno trusts for keyless signatures (kyverno-policies imageVerification.github.workflowRef)"
  bad=""
  for u in $(yq -r '.jobs[].steps[]?.uses // ""' "$wf"); do [[ "$u" =~ $SHA_USES_RE ]] || bad="$bad $u"; done
  assert_eq "$bad" "" "$t: every action pinned by commit SHA"
  ci_wf=${ci_uses#koorikla/ci/.github/workflows/}; ci_wf=${ci_wf%@*}
  want_wf=$(yq -r '.metadata.annotations["platform.koorikla.io/ci-workflow"]' "templates/$t/template.yaml")
  pend=$(pending_for "$t")
  if [[ -n "$pend" ]]; then
    issue=${pend##*|}; pwf=${pend#*|}; pwf=${pwf%|*}
    assert_eq "$want_wf" "$pwf" "$t: PENDING_CI workflow == annotation ci-workflow"
    assert_eq "$ci_wf" container.yaml "$t: interim CI = container.yaml until koorikla/ci ships $pwf ($issue)"
    assert_eq "$(grep -c "TODO($issue)" "$wf")" 1 "$t: CI caller carries TODO($issue)"
    echo "  WARN $t: koorikla/ci $pwf not released yet ($issue); CI uses container.yaml (tests run in the Docker build)"
  else
    assert_eq "$ci_wf" "$want_wf" "$t: CI calls koorikla/ci $want_wf"
    assert_eq "$(grep -c 'TODO(koorikla/ci#' "$wf")" 0 "$t: no stale TODO(koorikla/ci#...) (drop the PENDING_CI line)"
  fi
  if command -v actionlint >/dev/null 2>&1; then
    if out=$(cd "$R" && actionlint -no-color .github/workflows/ci.yaml 2>&1); then ok=yes; else ok=no; echo "$out" >&2; fi
    assert_eq "$ok" yes "$t: actionlint"
  fi

  # Dockerfile: bases pinned by digest; runtime distroless/Chainguard, non-root
  froms=$(awk 'toupper($1) == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--/) { print $i; break } }' "$R/Dockerfile")
  stages=$(awk 'toupper($1) == "FROM" && toupper($(NF-1)) == "AS" { print $NF }' "$R/Dockerfile")
  bad=""
  for ref in $froms; do
    [[ " $(echo "$stages" | tr '\n' ' ') " == *" $ref "* || "$ref" =~ $PIN_RE ]] || bad="$bad $ref"
  done
  assert_eq "$bad" "" "$t: every FROM is fully qualified and pinned by digest"
  final=$(echo "$froms" | tail -n1)
  assert_match "$final" '^(gcr\.io/distroless/|cgr\.dev/chainguard/)' "$t: runtime base is distroless or Chainguard"
  user=$(awk 'toupper($1) == "FROM" { u = "" } toupper($1) == "USER" { u = $2 } END { print u }' "$R/Dockerfile")
  assert_match "$user" '^(nonroot|[1-9][0-9]*)(:(nonroot|[1-9][0-9]*))?$' "$t: runtime stage runs as a non-root USER"

  # platform PR: governance record + (new tenant) tenant file rendered through charts/tenant
  rec="$R/platform/installations/local/repos/sample-svc.yaml"
  assert_eq "$(yq -r '.kind + " " + .spec.tenant + " " + .spec.framework + " " + .spec.visibility' "$rec" 2>/dev/null)" "GitHubRepository demo $stack public" "$t: governance record for #100"
  tf="$R/platform/installations/local/tenants/demo.yaml"
  if helm template tenant-demo charts/tenant --namespace default -f installations/local/installation.yaml -f "$tf" > "$TMP/$t-tenant.yaml" 2>"$TMP/$t-tenant.err"; then
    ok=$(kc "$TMP/$t-tenant.yaml")
  else
    ok=no; cat "$TMP/$t-tenant.err" >&2
  fi
  assert_eq "$ok" yes "$t: new tenant file renders through charts/tenant and passes kubeconform"
  assert_eq "$(yq -r 'select(.kind == "Application" and .metadata.name == "demo-sample-svc") | .spec.source.repoURL' "$TMP/$t-tenant.yaml")" \
    "https://github.com/koorikla/sample-svc.git" "$t: tenant chart syncs the new repo's deploy/openchoreo"
done

# --- optional: build and smoke-test the images -------------------------------------------------------------------
if [[ "${TEMPLATES_BUILD:-0}" == 1 ]]; then
  if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
    echo "  FAIL: TEMPLATES_BUILD=1 needs a docker daemon" >&2; FAIL=$((FAIL + 1))
  fi
  for t in "${TEMPLATES[@]}"; do
    selected "$t" || continue
    R="$TMP/render/$t"; img="golden-path-$t:test"; c="golden-path-$t-smoke"
    [[ -d "$R" ]] || continue
    echo "  building $t ..."
    if docker build --build-arg VERSION=test -t "$img" "$R" > "$TMP/$t.build.log" 2>&1; then ok=yes; else ok=no; tail -n 60 "$TMP/$t.build.log" >&2; fi
    assert_eq "$ok" yes "$t: docker build (linters + unit tests in the build stage)"
    [[ "$ok" == yes ]] || continue
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker run -d --name "$c" --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges "$img" >/dev/null
    body=""
    for _ in $(seq 60); do
      body=$(docker run --rm --network "container:$c" "$BUSYBOX" wget -qO- -T 2 http://127.0.0.1:8080/healthz 2>/dev/null || true)
      [[ -n "$body" ]] && break
      sleep 1
    done
    [[ -n "$body" ]] || docker logs "$c" 2>&1 | tail -n 30 >&2
    assert_match "$body" '"status": ?"ok"' "$t: GET /healthz on a read-only, non-root container"
    docker rm -f "$c" >/dev/null 2>&1 || true
    docker image rm "$img" >/dev/null 2>&1 || true
  done
else
  echo "  SKIP docker build + smoke test (TEMPLATES_BUILD=1; CI workflow templates.yaml runs them)"
fi

finish
