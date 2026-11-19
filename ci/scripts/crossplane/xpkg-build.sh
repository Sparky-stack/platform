#!/usr/bin/env bash
# Build a Crossplane package (.xpkg): configuration, function or provider.
#
# Env in:
#   PACKAGE_ROOT          directory with crossplane.yaml, default .
#   EXAMPLES_DIR          examples root relative to PACKAGE_ROOT (bundled when
#                         it exists), default examples
#   IGNORE                comma list of extra --ignore patterns (relative to
#                         PACKAGE_ROOT; wildcards don't cross directories)
#   EMBED_RUNTIME_IMAGE   optional image ref to embed (provider/function)
#   EMBED_RUNTIME_TARBALL optional image tarball to embed instead
#   OUTPUT                output file, default $CI_OUT_DIR/package.xpkg
# Outputs:
#   xpkg  path of the built package
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd crossplane

root="${PACKAGE_ROOT:-.}"
# Crossplane Project (crossplane-project.yaml): `crossplane project build` (Configuration + any embedded functions,
# repository = REPOSITORY, the push target, because it names embedded function references). Tests and other non-API
# files are not part of a project build, so IGNORE / EXAMPLES_DIR do not apply.
if [[ -f "${root}/crossplane-project.yaml" ]]; then
  require_env REPOSITORY
  out="$(cd "$(out_dir)" && pwd)/project"
  name="$(yq -r '.metadata.name' "${root}/crossplane-project.yaml")"
  log "crossplane project build --repository ${REPOSITORY} -o ${out} (in ${root})"
  (cd "${root}" && crossplane project build --repository "${REPOSITORY}" -o "${out}")
  emit_output xpkg "${out}/${name}.xpkg"
  emit_output mode project
  exit 0
fi
[[ -f "${root}/crossplane.yaml" ]] || die "${root}/crossplane.yaml not found"
out_file="${OUTPUT:-$(out_dir)/package.xpkg}"

# Test assets and CI files are never package content.
ignore="tests/*,tests/*/*,tests/*/*/*,tests/*/*/*/*,.github/*,.github/*/*,.git/*"
if [[ -n "${IGNORE:-}" ]]; then
  ignore="${ignore},${IGNORE}"
fi

set -- xpkg build --package-root "${root}" --ignore "${ignore}" -o "${out_file}"
examples="${EXAMPLES_DIR:-examples}"
if [[ -d "${root}/${examples}" ]]; then
  set -- "$@" --examples-root "${root}/${examples}"
fi
if [[ -n "${EMBED_RUNTIME_IMAGE:-}" ]]; then
  set -- "$@" --embed-runtime-image "${EMBED_RUNTIME_IMAGE}"
elif [[ -n "${EMBED_RUNTIME_TARBALL:-}" ]]; then
  set -- "$@" --embed-runtime-image-tarball "${EMBED_RUNTIME_TARBALL}"
fi

log "crossplane $*"
crossplane "$@"
emit_output xpkg "${out_file}"
emit_output mode xpkg
