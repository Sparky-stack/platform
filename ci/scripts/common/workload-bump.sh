#!/usr/bin/env bash
# Point an OpenChoreo Workload at a new image: rewrite spec.container.image
# to <repo>:<tag>@sha256:<digest> (production admission accepts only digest
# references; the tag keeps it readable) and spec.source.commit to the built
# commit, with yq. Comments survive; the rest of the file keeps its content,
# in yq's layout (2-space indent, no blank lines), exactly like the in-cluster
# GitOps step. Commit/push is done by git-push-change.sh.
#
# Env in:
#   WORKLOAD_FILE  default deploy/openchoreo/workload.yaml
#   IMAGE          <repo>:<tag> or <repo>:<tag>@sha256:<digest>   (required)
#   DIGEST         sha256:<64 hex>, appended to IMAGE when IMAGE has no digest
#   COMMIT         optional source commit SHA, written to spec.source.commit
#                  when the Workload has spec.source
# Outputs:
#   image    the full reference written
#   changed  true when the file changed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env IMAGE
require_cmd yq cmp mktemp

file="${WORKLOAD_FILE:-deploy/openchoreo/workload.yaml}"
[[ -f "${file}" ]] || die "workload file ${file} not found"

image="${IMAGE:?}"
case "${image}" in
  *@*) ;;
  *)
    [[ -n "${DIGEST:-}" ]] || die "IMAGE has no digest and DIGEST is empty"
    image="${image}@${DIGEST}"
    ;;
esac
# <repo>:<tag>@sha256:<64 hex>, no whitespace; the tag part is mandatory.
if ! printf '%s' "${image}" | grep -Eq '^[^[:space:]@]+:[^[:space:]@/]+@sha256:[0-9a-f]{64}$'; then
  die "IMAGE must be <repo>:<tag>@sha256:<64 hex>, got '${image}'"
fi
commit="${COMMIT:-}"
if [[ -n "${commit}" ]] && ! printf '%s' "${commit}" | grep -Eq '^[0-9a-f]{7,64}$'; then
  die "COMMIT must be a hex SHA, got '${commit}'"
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/workload.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT
cp "${file}" "${tmp}"

# The same two yq paths as the in-cluster GitOps step (addons/openchoreo-workflow-plane koorikla-build.yaml).
[[ "$(yq '.spec.container | has("image")' "${tmp}")" == true ]] || die "no image: key found in ${file}"
IMAGE="${image}" yq -i '.spec.container.image = strenv(IMAGE)' "${tmp}"
if [[ -n "${commit}" ]]; then
  if [[ "$(yq '.spec | has("source")' "${tmp}")" == true ]]; then
    COMMIT="${commit}" yq -i '.spec.source.commit = strenv(COMMIT)' "${tmp}"
  else
    warn "COMMIT set but no commit: key in ${file}; only the image was bumped"
  fi
fi

changed=false
if ! cmp -s "${tmp}" "${file}"; then
  cat "${tmp}" >"${file}"
  changed=true
fi

emit_output image "${image}"
emit_output changed "${changed}"
log "${file}: image=${image}${commit:+ commit=${commit}} changed=${changed}"
step_summary "- Workload \`${file}\`: \`${image}\` (changed: ${changed})"
