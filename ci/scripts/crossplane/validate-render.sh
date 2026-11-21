#!/usr/bin/env bash
# Validate a Crossplane configuration package and run render tests.
#
#  1. `crossplane resource validate` of every XRD/Composition (and function
#     inputs) against Crossplane core + dependency schemas (from crossplane.yaml).
#  2. Validate every example XR against the XRDs.
#  3. For every example XR: `crossplane composition render` with the matching
#     Composition (spec.crossplane.compositionRef.name, else compositeTypeRef),
#     validate the composed resources, and diff against
#     $RENDER_DIR/expected/<example file name> when that file exists.
#
# Env in:
#   PACKAGE_ROOT     package root containing crossplane.yaml or crossplane-project.yaml, default .
#   EXAMPLES_DIR     example XRs, relative to PACKAGE_ROOT, default examples
#   RENDER_DIR       render test assets, relative to PACKAGE_ROOT, default
#                    tests/render (functions.yaml, observed/<name>,
#                    expected/<name>, extra-resources/<name>)
#   FUNCTIONS_FILE   default $RENDER_DIR/functions.yaml (absent in a Crossplane Project: embedded functions)
#   UPDATE_EXPECTED  true = (re)write expected outputs instead of diffing
#   RENDER_TIMEOUT   render timeout without a functions file (Crossplane Project), default 15m
#   CACHE_DIR        schema cache dir (crossplane --cache-dir)
#   CI_OUT_DIR       output dir, default ./.ci-out
# Files out:
#   $CI_OUT_DIR/render/<example file name>  rendered output per example
# Requires: crossplane, yq (mikefarah v4), docker (render runs functions).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd crossplane yq diff

out="$(out_dir)"
out="$(cd "${out}" && pwd)"
mkdir -p "${out}/render"
cd "${PACKAGE_ROOT:-.}"

# Package metadata: crossplane.yaml (classic package) or, for a Crossplane Project (crossplane-project.yaml), an
# equivalent Configuration generated from the project's dependencies (api-only ones too: they carry the schemas).
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
if [[ -f crossplane-project.yaml ]]; then
  meta="${tmp}/crossplane.yaml"
  yq '{"apiVersion": "meta.pkg.crossplane.io/v1", "kind": "Configuration", "metadata": {"name": .metadata.name},
    "spec": {"dependsOn": [.spec.dependencies[] | select(.type == "xpkg") | .xpkg | del(.apiOnly)]}}' \
    crossplane-project.yaml >"${meta}"
elif [[ -f crossplane.yaml ]]; then
  meta="crossplane.yaml"
else
  die "neither crossplane.yaml nor crossplane-project.yaml found in $(pwd)"
fi

examples="${EXAMPLES_DIR:-examples}"
render_dir="${RENDER_DIR:-tests/render}"
functions="${FUNCTIONS_FILE:-${render_dir}/functions.yaml}"
cache_args=""
if [[ -n "${CACHE_DIR:-}" ]]; then
  cache_args="--cache-dir ${CACHE_DIR}"
fi

# Collect package YAML (everything except examples, tests, dot-dirs).
: >"${tmp}/xrds.list"
: >"${tmp}/comps.list"
find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -not -path './.*' -not -path "./${examples}/*" -not -path "./${render_dir}/*" \
  -not -path './tests/*' -not -path './_output/*' -not -path './schemas/*' \
  -not -name 'crossplane.yaml' -not -name 'crossplane-project.yaml' | LC_ALL=C sort >"${tmp}/files.list"
while IFS= read -r f <&3; do
  # One kind per document of a multi-document file.
  kinds="$(yq -r '.kind' "$f" 2>/dev/null || true)"
  case "${kinds}" in *CompositeResourceDefinition*) echo "$f" >>"${tmp}/xrds.list" ;; esac
  if printf '%s\n' "${kinds}" | grep -qx Composition; then echo "$f" >>"${tmp}/comps.list"; fi
done 3<"${tmp}/files.list"

[[ -s "${tmp}/xrds.list" ]] || die "no CompositeResourceDefinition found"
[[ -s "${tmp}/comps.list" ]] || die "no Composition found"

extensions="${meta}"
while IFS= read -r f; do extensions="${extensions},${f}"; done <"${tmp}/xrds.list"

# 1. Package objects.
: >"${tmp}/package.yaml"
while IFS= read -r f; do
  {
    printf -- '---\n'
    cat "$f"
    printf '\n'
  } >>"${tmp}/package.yaml"
done <"${tmp}/files.list"
log "validate package objects against Crossplane + dependency schemas"
# shellcheck disable=SC2086
crossplane resource validate ${cache_args} "${meta}" "${tmp}/package.yaml"

if [[ ! -d "${examples}" ]]; then
  warn "no ${examples}/ directory; skipping example validation and render tests"
  exit 0
fi

# 2. Examples against XRDs.
log "validate examples against XRDs"
# shellcheck disable=SC2086
crossplane resource validate ${cache_args} "${extensions}" "${examples}"

# 3. Render tests.
[[ -f "${functions}" || -f crossplane-project.yaml ]] || die "functions file ${functions} not found (needed by composition render)"

# A Crossplane Project with a functions file lacks its embedded functions (functions/<fn>/): build the project, load the
# images for this arch and add one Function each, named like Crossplane names the dependency (<repo>_<fn>, see below).
if [[ -f crossplane-project.yaml && -f "${functions}" ]] && compgen -G 'functions/*/' >/dev/null; then
  require_cmd docker
  repo="$(yq -r '.spec.repository' crossplane-project.yaml)"
  log "crossplane project build (embedded functions for the render tests)"
  # shellcheck disable=SC2086
  crossplane project build ${cache_args} --repository "${repo}" -o "${tmp}/project"
  docker load -q -i "${tmp}/project/$(yq -r '.metadata.name' crossplane-project.yaml).xpkg" >/dev/null
  case "$(docker info --format '{{.Architecture}}')" in aarch64 | arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  cp "${functions}" "${tmp}/functions.yaml"
  for d in functions/*/; do
    fn="$(basename "${d}")"
    # Registry host dropped, / -> -, _ dropped.
    name="$(printf '%s_%s' "${repo#*/}" "${fn}" | tr '/' '-' | tr -d '_')"
    printf -- '---\napiVersion: pkg.crossplane.io/v1\nkind: Function\nmetadata:\n  name: %s\n  annotations:\n    render.crossplane.io/runtime-docker-pull-policy: Never\nspec:\n  package: %s\n' \
      "${name}" "${repo}_${fn}:${arch}" >>"${tmp}/functions.yaml"
  done
  functions="${tmp}/functions.yaml"
fi

find_composition() {
  # $1 = XR file; prints the composition file to use.
  local xr="$1" ref api kind f
  ref="$(yq -r '.spec.crossplane.compositionRef.name // ""' "$xr")"
  api="$(yq -r '.apiVersion' "$xr")"
  kind="$(yq -r '.kind' "$xr")"
  while IFS= read -r f; do
    if [[ -n "${ref}" ]]; then
      [[ "$(yq -r '.metadata.name' "$f")" == "${ref}" ]] && { echo "$f"; return 0; }
    elif [[ "$(yq -r '.spec.compositeTypeRef.apiVersion' "$f")" == "${api}" &&
      "$(yq -r '.spec.compositeTypeRef.kind' "$f")" == "${kind}" ]]; then
      echo "$f"
      return 0
    fi
  done <"${tmp}/comps.list"
  return 1
}

find_xrd() {
  # $1 = XR file; prints the XRD file defining its kind.
  local xr="$1" group kind f
  group="$(yq -r '.apiVersion' "$xr" | cut -d/ -f1)"
  kind="$(yq -r '.kind' "$xr")"
  while IFS= read -r f; do
    if [[ "$(yq -r '.spec.group' "$f")" == "${group}" && "$(yq -r '.spec.names.kind' "$f")" == "${kind}" ]]; then
      echo "$f"
      return 0
    fi
  done <"${tmp}/xrds.list"
  return 1
}

failed=0
count=0
find "${examples}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort >"${tmp}/examples.list"
while IFS= read -r xr <&3; do
  name="$(basename "$xr")"
  comp="$(find_composition "$xr" || true)"
  if [[ -z "${comp}" ]]; then
    warn "${name}: no matching Composition; skipping render"
    continue
  fi
  count=$((count + 1))
  set -- "$xr" "$comp"
  # No functions file in a Crossplane Project: render builds the embedded functions (functions/) and resolves the
  # project's dependencies itself (first run pulls them, hence the longer timeout).
  if [[ -f "${functions}" ]]; then set -- "$@" "${functions}"; else set -- "$@" --timeout "${RENDER_TIMEOUT:-15m}"; fi
  xrd="$(find_xrd "$xr" || true)"
  [[ -z "${xrd}" ]] || set -- "$@" --xrd "${xrd}"
  [[ ! -f "${render_dir}/observed/${name}" ]] || set -- "$@" --observed-resources "${render_dir}/observed/${name}"
  [[ ! -f "${render_dir}/extra-resources/${name}" ]] || set -- "$@" --extra-resources "${render_dir}/extra-resources/${name}"
  log "render ${name} with ${comp}"
  crossplane composition render "$@" >"${out}/render/${name}"

  # The rendered XR carries only fields the pipeline set, so validate the
  # composed resources (documents after the first) only.
  yq 'select(di > 0)' "${out}/render/${name}" >"${tmp}/composed.yaml"
  if [[ -s "${tmp}/composed.yaml" ]]; then
    # shellcheck disable=SC2086
    if ! crossplane resource validate ${cache_args} "${extensions}" "${tmp}/composed.yaml"; then
      failed=$((failed + 1))
      continue
    fi
  fi

  expected="${render_dir}/expected/${name}"
  if is_true "${UPDATE_EXPECTED:-false}"; then
    mkdir -p "${render_dir}/expected"
    cp "${out}/render/${name}" "${expected}"
    log "updated ${expected}"
  elif [[ -f "${expected}" ]]; then
    if diff -u "${expected}" "${out}/render/${name}"; then
      log "${name}: render matches ${expected}"
    else
      warn "${name}: render differs from ${expected} (UPDATE_EXPECTED=true to accept)"
      failed=$((failed + 1))
    fi
  else
    log "${name}: no ${expected}; render + validation only"
  fi
done 3<"${tmp}/examples.list"

step_summary "- Crossplane render tests: ${count} example(s), ${failed} failure(s)"
[[ "${failed}" -eq 0 ]] || die "${failed} render test(s) failed"
