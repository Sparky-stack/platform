#!/usr/bin/env bash
# Resolve the OCI registry for Helm charts and the push decision.
#
# Env in:
#   OWNER       repository owner (required unless REGISTRY is set)
#   REGISTRY    chart registry prefix, default ghcr.io/<owner>/charts
#   INPUT_PUSH  true/false, default true
#   EVENT_NAME  CI event; pull_request never pushes
# Outputs:
#   registry registry_host should_push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

reg="${REGISTRY:-}"
if [[ -z "${reg}" ]]; then
  require_env OWNER
  reg="ghcr.io/$(lower "${OWNER}")/charts"
fi
reg="$(lower "${reg%/}")"
reg="${reg#oci://}"

push=false
if is_true "${INPUT_PUSH:-true}" && [[ "${EVENT_NAME:-push}" != "pull_request" ]]; then
  push=true
fi

emit_output registry "${reg}"
emit_output registry_host "${reg%%/*}"
emit_output should_push "${push}"
