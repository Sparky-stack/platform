#!/usr/bin/env bash
# Push one or more .xpkg files (several = multi-arch index) under every tag
# and resolve the pushed digest.
#
# Env in:
#   PACKAGE_FILES  comma list of .xpkg files (required)
#   TAGS           newline/space separated full refs, e.g.
#                  ghcr.io/koorikla/my-config:abc1234 (required, same repo)
# Outputs:
#   digest            sha256:...
#   repo              repository (first tag without :tag)
#   image_digest_ref  repo@sha256:...
#   function_repo / function_digest / function_digest_ref
#                     PROJECT_ROOT with an embedded function (functions/<fn>/): `crossplane project push` pushes it as
#                     <repo>_<fn> (multi-arch index) under the same tags; empty without one. One embedded function per
#                     project (the workflow signs and attests exactly one).
# Requires: crossplane; crane or docker buildx (digest lookup); registry
# credentials in the docker config (docker login / crane auth login).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_env PACKAGE_FILES TAGS
require_cmd crossplane

first=""
for t in ${TAGS}; do
  if [[ -n "${PROJECT_ROOT:-}" ]]; then
    # Crossplane Project build output (xpkg-build.sh mode=project): push with the project tooling, one tag at a time.
    log "crossplane project push --repository ${t%:*} -t ${t##*:} (in ${PROJECT_ROOT})"
    (cd "${PROJECT_ROOT}" && crossplane project push --package-file "${PACKAGE_FILES}" --repository "${t%:*}" -t "${t##*:}")
  else
    log "crossplane xpkg push -f ${PACKAGE_FILES} ${t}"
    crossplane xpkg push -f "${PACKAGE_FILES}" "${t}"
  fi
  [[ -n "${first}" ]] || first="${t}"
done

repo="${first%:*}"
# resolve_digest <ref>: digest of a pushed tag (crane, or docker buildx as a fallback)
resolve_digest() {
  local d
  if command -v crane >/dev/null 2>&1; then
    d="$(crane digest "$1")"
  else
    require_cmd docker jq
    d="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r '.digest')"
  fi
  case "${d}" in
    sha256:*) printf '%s\n' "${d}" ;;
    *) die "could not resolve digest of $1" ;;
  esac
}
digest="$(resolve_digest "${first}")"
emit_output digest "${digest}"
emit_output repo "${repo}"
emit_output image_digest_ref "${repo}@${digest}"
step_summary "- Pushed package \`${repo}@${digest}\`"

fns=()
if [[ -n "${PROJECT_ROOT:-}" && -d "${PROJECT_ROOT}/functions" ]]; then
  for d in "${PROJECT_ROOT}"/functions/*/; do
    [[ -d "${d}" ]] && fns+=("$(basename "${d}")")
  done
fi
[[ ${#fns[@]} -le 1 ]] || die "more than one embedded function (${fns[*]}): extend the workflow's sign/attest steps"
fn_repo="" fn_digest="" fn_ref=""
if [[ ${#fns[@]} -eq 1 ]]; then
  fn_repo="${repo}_${fns[0]}"
  fn_digest="$(resolve_digest "${fn_repo}:${first##*:}")"
  fn_ref="${fn_repo}@${fn_digest}"
  step_summary "- Pushed embedded function \`${fn_ref}\`"
fi
emit_output function_repo "${fn_repo}"
emit_output function_digest "${fn_digest}"
emit_output function_digest_ref "${fn_ref}"
