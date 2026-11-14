#!/usr/bin/env bash
# Compute normalized image metadata for container builds.
#
# Contract:
#   Env in:
#     OWNER          (GitHub repository owner)
#     REPO_NAME      (GitHub repository name, e.g. koorikla/hello-world or hello-world)
#     SHA            (full 40-char commit SHA)
#     REGISTRY       (optional registry prefix, default ghcr.io/<owner>)
#     IMAGE_NAME     (optional image name override, default repo basename)
#     INPUT_PUSH     (true/false)
#     EVENT_NAME     (github.event_name)
#     WORKDIR        (optional working directory)
#     SARIF_CATEGORY (optional SARIF category override)
#   Outputs (GITHUB_OUTPUT / CI_OUT_DIR):
#     owner, short_sha, repo, image, registry_host, should_push, sarif_cat
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

owner=$(printf '%s' "${OWNER}" | tr '[:upper:]' '[:lower:]')
repo_base="${REPO_NAME##*/}"
img_name="${IMAGE_NAME:-${repo_base}}"
img_name=$(printf '%s' "${img_name}" | tr '[:upper:]' '[:lower:]')

if [[ -z "${REGISTRY:-}" ]]; then
  reg_prefix="ghcr.io/${owner}"
elif [[ "${REGISTRY}" != */* ]]; then
  reg_prefix="${REGISTRY}/${owner}"
else
  reg_prefix="${REGISTRY%/}"
fi

short_sha="${SHA:0:7}"
repo="${reg_prefix}/${img_name}"
image="${repo}:${short_sha}"
registry_host="${repo%%/*}"

should_push="false"
if [[ "${INPUT_PUSH:-true}" == "true" && "${EVENT_NAME:-push}" != "pull_request" ]]; then
  should_push="true"
fi

sarif_cat="${SARIF_CATEGORY:-container-${img_name}}"

emit_output "owner" "${owner}"
emit_output "short_sha" "${short_sha}"
emit_output "repo" "${repo}"
emit_output "image" "${image}"
emit_output "registry_host" "${registry_host}"
emit_output "should_push" "${should_push}"
emit_output "sarif_cat" "${sarif_cat}"
