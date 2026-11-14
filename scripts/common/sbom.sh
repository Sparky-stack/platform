#!/usr/bin/env bash
# Generate an SPDX JSON SBOM for a container image with syft.
#
# Env in:
#   IMAGE_REF  image (required): repo@sha256:... or local tag
#   SOURCE     syft source scheme: registry | docker | oci-dir ... (default
#              registry when IMAGE_REF contains @sha256:, else docker)
#   PLATFORM   platform for registry sources, default linux/amd64
#   CI_OUT_DIR output dir, default ./.ci-out
# Files out:
#   $CI_OUT_DIR/sbom.spdx.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env IMAGE_REF
require_cmd syft

out="$(out_dir)"
source_scheme="${SOURCE:-}"
if [[ -z "${source_scheme}" ]]; then
  case "${IMAGE_REF}" in
    *@sha256:*) source_scheme="registry" ;;
    *) source_scheme="docker" ;;
  esac
fi

args=""
if [[ "${source_scheme}" == "registry" ]]; then
  args="--platform ${PLATFORM:-linux/amd64}"
fi

log "syft ${source_scheme}:${IMAGE_REF} ${args}"
# shellcheck disable=SC2086
syft scan --quiet ${args} "${source_scheme}:${IMAGE_REF}" -o "spdx-json=${out}/sbom.spdx.json"
emit_output sbom "${out}/sbom.spdx.json"
