#!/usr/bin/env bash
# koorikla-build step `scan-fs`: Trivy on the checkout's lockfiles (ci/scripts/common/scan-fs.sh).
#
# Env in:  APP_PATH, IGNORE_REL (trivy-ignore-file, relative to the repository root; optional), plus scan-fs.sh's env
#          (FAIL_SEVERITIES, IGNORE_UNFIXED, CI_OUT_DIR, TRIVY_CACHE_DIR)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SCAN_PATH="/work/source/${APP_PATH#./}"
if [ -n "$IGNORE_REL" ] && [ -f "/work/source/$IGNORE_REL" ]; then export IGNORE_FILE="/work/source/$IGNORE_REL"; fi
"$here/../common/scan-fs.sh"
