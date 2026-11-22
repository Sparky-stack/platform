#!/usr/bin/env bash
# koorikla-build step `scan-image`: Trivy on the pushed image, every platform (ci/scripts/common/scan-image.sh).
#
# Env in:  DIGEST_REF, IGNORE_REL (optional), plus scan-image.sh's env (PLATFORMS, FAIL_SEVERITIES, IGNORE_UNFIXED,
#          CI_OUT_DIR, TRIVY_CACHE_DIR)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

registry_trust
export DOCKER_CONFIG=/registry-auth
if [ -n "$IGNORE_REL" ] && [ -f "/work/source/$IGNORE_REL" ]; then export IGNORE_FILE="/work/source/$IGNORE_REL"; fi
IMAGE_REF="$DIGEST_REF" IMAGE_SRC=remote "$here/../common/scan-image.sh"
