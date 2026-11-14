#!/usr/bin/env bash
# Compute normalized image coordinates for a container build.
#
# Env in:
#   OWNER          repository owner (required)
#   REPO_NAME      owner/name or name (required)
#   SHA            full commit SHA (required)
#   REGISTRY       registry prefix, e.g. ghcr.io/koorikla or harbor.example/apps
#                  (default ghcr.io/<owner>; a bare host gets /<owner> appended)
#   IMAGE_NAME     image name (default: repository basename)
#   INPUT_PUSH     true/false (default true)
#   EVENT_NAME     CI event; pull_request never pushes (default push)
#   SARIF_CATEGORY code-scanning category (default container-<image>)
# Outputs (GITHUB_OUTPUT and/or $CI_OUT_DIR/<key>):
#   owner image_name short_sha repo image registry_host should_push sarif_cat
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env OWNER REPO_NAME SHA

owner_lc="$(lower "${OWNER}")"
repo_base="${REPO_NAME##*/}"
img_name="$(lower "${IMAGE_NAME:-${repo_base}}")"

if [[ -z "${REGISTRY:-}" ]]; then
  reg_prefix="ghcr.io/${owner_lc}"
elif [[ "${REGISTRY}" != */* ]]; then
  reg_prefix="${REGISTRY}/${owner_lc}"
else
  reg_prefix="${REGISTRY%/}"
fi
reg_prefix="$(lower "${reg_prefix}")"

short_sha="${SHA:0:7}"
repo="${reg_prefix}/${img_name}"
image="${repo}:${short_sha}"
registry_host="${repo%%/*}"

should_push="false"
if is_true "${INPUT_PUSH:-true}" && [[ "${EVENT_NAME:-push}" != "pull_request" ]]; then
  should_push="true"
fi

emit_output owner "${owner_lc}"
emit_output image_name "${img_name}"
emit_output short_sha "${short_sha}"
emit_output repo "${repo}"
emit_output image "${image}"
emit_output registry_host "${registry_host}"
emit_output should_push "${should_push}"
emit_output sarif_cat "${SARIF_CATEGORY:-container-${img_name}}"
log "image=${image} push=${should_push}"
