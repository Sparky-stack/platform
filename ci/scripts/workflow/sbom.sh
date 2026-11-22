#!/usr/bin/env bash
# koorikla-build step `sbom`: syft SPDX SBOM of the pushed image's first platform (ci/scripts/common/sbom.sh).
#
# Env in:  DIGEST_REF, PLATFORMS (comma-separated; the first one is described), CI_OUT_DIR
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

registry_trust
export DOCKER_CONFIG=/registry-auth
IMAGE_REF="$DIGEST_REF" SOURCE=registry PLATFORM="${PLATFORMS%%,*}" "$here/../common/sbom.sh"
