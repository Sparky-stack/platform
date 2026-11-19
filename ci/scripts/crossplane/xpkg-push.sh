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
if command -v crane >/dev/null 2>&1; then
  digest="$(crane digest "${first}")"
else
  require_cmd docker jq
  digest="$(docker buildx imagetools inspect "${first}" --format '{{json .Manifest}}' | jq -r '.digest')"
fi
case "${digest}" in
  sha256:*) ;;
  *) die "could not resolve digest of ${first}" ;;
esac

emit_output digest "${digest}"
emit_output repo "${repo}"
emit_output image_digest_ref "${repo}@${digest}"
step_summary "- Pushed package \`${repo}@${digest}\`"
