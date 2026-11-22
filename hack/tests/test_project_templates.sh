#!/usr/bin/env bash
# Contract: golden-path project templates (templates/, docs/project-templates.md), Backstage scaffolder entities that
# OpenChoreo's Backstage loads from templates/catalog-info.yaml.
#   - the catalog Location lists exactly templates/*/template.yaml; every template shares parameters and steps (only
#     metadata, the stack skeleton and the stack name differ) and uses only actions the OpenChoreo 1.3.3 image ships;
#   - day-0 only (koorikla/platform#100): publish:github gets no token (the platform write GitHub App is the
#     integration credential, no PAT), protectDefaultBranch false and nothing else that sets repo governance;
#   - every template renders offline (hack/tests/render_template.py, the subset of nunjucks skeletons may use) with
#     and without a new tenant; the result: YAML/JSON parse, deploy/openchoreo passes kubeconform -strict with the
#     OpenChoreo CRD schemas, the tenant file renders through charts/tenant, the CI caller pins the app-* workflow by SHA,
#     Dockerfiles pin every base by digest and run non-root on distroless/Chainguard, the Workload bump script works;
#   - TEMPLATES_BUILD=1 (CI workflow templates.yaml; needs docker): `docker build` of every rendered skeleton (the
#     build stage runs its linters and unit tests) and a smoke test of GET /healthz on a read-only, non-root container.
# TEMPLATES_ONLY="go-service ..." limits rendering/building to those templates (CI matrix).
# shellcheck disable=SC2016  # literal ${{ ... }} template expressions in single quotes
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"

# Scaffolder actions registered in openchoreo-ui v1.3.3 (backend features of @openchoreo/backstage-portal-backend:
# scaffolder-backend built-ins + scaffolder-backend-module-github). Golden paths need only these five.
ALLOWED_ACTIONS="catalog:register fetch:template fetch:template:file publish:github publish:github:pull-request"
# publish:github inputs a template may set. Everything else (branch protection, required checks/reviews, collaborators,
# merge settings, secrets, environments) is repo governance: declared in installations/<inst>/repos/ and reconciled by
# Crossplane (#100), never set imperatively at creation. No `token`: the GitHub App integration authenticates.
PUBLISH_INPUTS="defaultBranch description gitCommitMessage protectDefaultBranch repoUrl repoVisibility"
PIN_RE='^([a-z0-9-]+(\.[a-z0-9-]+)+)(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]{1,128})?@sha256:[0-9a-f]{64}$'
SHA_USES_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@]+)?@[0-9a-f]{40}$'
BUSYBOX=docker.io/library/busybox:1.38.0-musl@sha256:80e38f9a1b39188b8bdb28879178edb322a4402b081a9aedda1924609decd6f6

SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
if [[ ! -d "$SCHEMAS_DIR/openchoreo.dev" ]]; then   # standalone run (CI workflow templates.yaml): chart deps first
  ./hack/deps.sh >/dev/null
  SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
fi
# ci/schemas (what app-openchoreo-manifests.yaml validates app repos against) == the CRDs of the vendored OpenChoreo
# charts: regenerate with `cp "$SCHEMAS_DIR"/openchoreo.dev/<kind>_v1alpha1.json ci/schemas/openchoreo.dev/` (jq .).
# assert_same <label> <expected> <actual>: like assert_eq for long JSON documents; prints a short diff on mismatch
assert_same() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); return 0; fi
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s, diff (expected vs actual):\n' "$1" >&2
  diff <(printf '%s' "$2" | yq -P '.') <(printf '%s' "$3" | yq -P '.') | sed -n 1,20p >&2 || true
}
words_in() { local w; for w in $1; do [[ " $2 " == *" $w "* ]] || { echo "$w"; return 0; }; done; echo; }

stale=""
for f in ci/schemas/openchoreo.dev/*.json; do
  [[ "$(jq -S . "$f")" == "$(jq -S . "$SCHEMAS_DIR/openchoreo.dev/${f##*/}" 2>/dev/null)" ]] || stale="$stale ${f##*/}"
done
assert_eq "$stale" "" "ci/schemas/openchoreo.dev matches the vendored OpenChoreo CRDs"
assert_eq "$(find ci/schemas/openchoreo.dev -name '*.json' | wc -l | tr -d ' ')" 6 "ci/schemas covers the six app-repo kinds"

TRUSTED_CI_SHA=$(yq -r '.imageVerification.github.workflowRef' addons/kyverno-policies/values.yaml)
TEMPLATES=()
for d in templates/*/template.yaml; do
  t=${d#templates/}; t=${t%/template.yaml}
  [[ "$t" == _* ]] || TEMPLATES+=("$t")
done
# service golden paths (spec.type service) share parameters and steps; the platform API template (spec.type
# platform-api, templates/crossplane-api) has its own contract in hack/tests/test_crossplane_api_template.sh
SERVICES=(); OTHERS=""
for t in "${TEMPLATES[@]}"; do
  case "$(yq -r '.spec.type' "templates/$t/template.yaml")" in
    service) SERVICES+=("$t") ;;
    *) OTHERS="$OTHERS $t:$(yq -r '.spec.type' "templates/$t/template.yaml")" ;;
  esac
done
assert_eq "$([[ ${#SERVICES[@]} -ge 6 ]] && echo yes)" yes "at least the first batch of service templates exists (${#SERVICES[@]})"
assert_eq "$OTHERS" " crossplane-api:platform-api" "every non-service template is the platform API template (own test)"
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
for t in "${SERVICES[@]}"; do
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
params() {   # <newTenant>
  printf '{"name":"sample-svc","description":"Sample \\"quoted\\" service: golden path","owner":"group:default/openchoreo-users","project":"demo","newTenant":%s,"installation":"local","repoOwner":"koorikla","visibility":"public","codeowners":"@koorikla @octocat"}' "$1"
}
params true > "$TMP/params-new.json"; params false > "$TMP/params-existing.json"
yq -o=json '.' installations/local/installation.yaml > /dev/null

for t in "${SERVICES[@]}"; do
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
    deploy/openchoreo/component.yaml deploy/openchoreo/workload.yaml \
    deploy/openchoreo/release-bindings/development.yaml deploy/openchoreo/release-bindings/staging.yaml \
    deploy/openchoreo/release-bindings/production.yaml; do
    assert_eq "$([[ -s "$R/$p" ]] && echo yes)" yes "$t: has $p"
  done
  assert_eq "$(kc_valid "$R/deploy/openchoreo")" yes "$t: deploy/openchoreo passes kubeconform -strict (OpenChoreo CRDs)"
  assert_eq "$(yq -r 'select(.kind == "Component") | .metadata.name + " " + .spec.owner.projectName' "$R/deploy/openchoreo/component.yaml")" "sample-svc demo" "$t: Component sample-svc in project demo"
  assert_eq "$(yq -r '.spec.container.image' "$R/deploy/openchoreo/workload.yaml")" "ghcr.io/koorikla/sample-svc:main" "$t: Workload names the image CI publishes"
  assert_eq "$(yq -r '.kind + " " + .metadata.name + " " + .spec.dependencyOf[0]' "$R/catalog-info.yaml")" "Resource sample-svc-repo component:default/sample-svc" "$t: catalog-info is a Resource pointing at OpenChoreo's Component (no duplicate Component ref)"
  assert_eq "$(grep -v '^#' "$R/.github/CODEOWNERS")" "* @koorikla @octocat" "$t: CODEOWNERS from the parameter"

  # no code in the app repo (owner rule): no hack/, no scripts; the CI caller has no run: steps
  assert_eq "$([[ -e "$R/hack" ]] && echo present || echo absent)" absent "$t: no hack/ (validation and bump live in the platform)"
  assert_eq "$(yq -r '[.jobs[].steps[]? | select(has("run"))] | length' "$R/.github/workflows/ci.yaml")" 0 "$t: CI caller has no inline run: steps"
  # the platform's bump script (app-workload-bump.yaml) pins image and commit in the rendered Workload, still valid
  cp "$R/deploy/openchoreo/workload.yaml" "$TMP/wl.yaml"
  d64=$(printf 'a%.0s' $(seq 64))
  CI_OUT_DIR="$TMP/wb" WORKLOAD_FILE="$TMP/wl.yaml" IMAGE=ghcr.io/koorikla/sample-svc:abc1234 DIGEST="sha256:$d64" COMMIT=abc1234def \
    bash ci/scripts/common/workload-bump.sh >/dev/null 2>&1 || true
  assert_eq "$(yq -r '.spec.container.image + " " + .spec.source.commit' "$TMP/wl.yaml")" "ghcr.io/koorikla/sample-svc:abc1234@sha256:$d64 abc1234def" "$t: app-workload-bump pins image and commit"
  assert_eq "$(kc_valid "$TMP/wl.yaml")" yes "$t: bumped Workload passes kubeconform -strict"

  # CI caller: koorikla/platform app-* workflow by SHA (# ci-v1.0.0); every action pinned by SHA; actionlint
  wf="$R/.github/workflows/ci.yaml"
  ci_uses=$(yq -r '.jobs.build.uses' "$wf")
  assert_match "$ci_uses" '^koorikla/platform/\.github/workflows/app-[a-z-]+\.yaml@[0-9a-f]{40}$' "$t: build job calls an app-* workflow by commit SHA"
  assert_eq "$(grep -cE 'uses: koorikla/platform/[^ ]+@[0-9a-f]{40} # ci-v[0-9]+\.[0-9]+\.[0-9]+$' "$wf")" 2 "$t: both platform workflow SHAs carry a '# ci-vX.Y.Z' release tag comment (Renovate)"
  assert_eq "$(yq -r '.jobs.bump.uses' "$wf")" "koorikla/platform/.github/workflows/app-workload-bump.yaml@$TRUSTED_CI_SHA" "$t: bump job calls app-workload-bump.yaml at the same SHA"
  assert_eq "${ci_uses##*@}" "$TRUSTED_CI_SHA" "$t: workflow SHA == the commit Kyverno trusts for keyless signatures (kyverno-policies imageVerification.github.workflowRef)"
  bad=""
  for u in $(yq -r '.jobs[].steps[]?.uses // ""' "$wf"); do [[ "$u" =~ $SHA_USES_RE ]] || bad="$bad $u"; done
  assert_eq "$bad" "" "$t: every action pinned by commit SHA"
  ci_wf=${ci_uses#koorikla/platform/.github/workflows/}; ci_wf=${ci_wf%@*}
  want_wf=$(yq -r '.metadata.annotations["platform.koorikla.io/ci-workflow"]' "templates/$t/template.yaml")
  assert_eq "$ci_wf" "$want_wf" "$t: CI calls $want_wf (annotation platform.koorikla.io/ci-workflow)"
  assert_eq "$(grep -c 'TODO(koorikla/ci#' "$wf")" 0 "$t: no interim TODO(koorikla/ci#...) left in the CI caller"
  assert_eq "$(grep -c 'actions: read' "$wf")" "$([[ "$want_wf" == app-container.yaml ]] && echo 0 || echo 1)" "$t: caller grants actions: read exactly when the stack workflow runs CodeQL"
  if [[ "$want_wf" == app-rust.yaml ]]; then   # app-rust.yaml installs the toolchain rust-toolchain.toml names (rustup)
    chan=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$R/rust-toolchain.toml" 2>/dev/null | tr -d '\r' || true)
    assert_match "$chan" '^[0-9]+\.[0-9]+\.[0-9]+$' "$t: rust-toolchain.toml pins an exact Rust release"
    assert_eq "$chan" "$(sed -n 's/^rust *= *"\(.*\)"/\1/p' "$R/mise.toml" | tr -d '\r')" "$t: rust-toolchain.toml == mise.toml rust"
    assert_match "$(grep -m1 '^FROM ' "$R/Dockerfile")" "/rust:$chan-" "$t: rust-toolchain.toml == Dockerfile build stage Rust"
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
    ok=$(kc_valid "$TMP/$t-tenant.yaml")
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
  for t in "${SERVICES[@]}"; do
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
