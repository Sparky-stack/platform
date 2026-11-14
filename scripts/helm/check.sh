#!/usr/bin/env bash
# Helm chart checks: dependency build, helm lint --strict, helm-unittest.
#
# Env in:
#   CHART_PATH      chart directory (required)
#   RUN_UNITTEST    default auto: run when <chart>/tests/ exists
#   UNITTEST_PLUGIN default https://github.com/helm-unittest/helm-unittest
#   LINT_ARGS       extra helm lint args (e.g. "--values ci/values.yaml")
# Files out: none
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_env CHART_PATH
require_cmd helm
chart="${CHART_PATH}"
[[ -f "${chart}/Chart.yaml" ]] || die "${chart}/Chart.yaml not found"

if grep -q '^dependencies:' "${chart}/Chart.yaml"; then
  log "helm dependency build"
  helm dependency build "${chart}"
fi

log "helm lint --strict ${chart}"
# shellcheck disable=SC2086
helm lint --strict ${LINT_ARGS:-} "${chart}"

unittest="${RUN_UNITTEST:-auto}"
if [[ "${unittest}" == "auto" ]]; then
  if [[ -d "${chart}/tests" ]]; then unittest=true; else unittest=false; fi
fi
if is_true "${unittest}"; then
  if ! helm plugin list 2>/dev/null | grep -q '^unittest'; then
    log "installing helm-unittest"
    plugin="${UNITTEST_PLUGIN:-https://github.com/helm-unittest/helm-unittest}"
    # Helm 4 verifies plugin signatures by default; git installs carry none.
    if helm plugin install --help 2>/dev/null | grep -q -- '--verify'; then
      helm plugin install "${plugin}" --verify=false
    else
      helm plugin install "${plugin}"
    fi
  fi
  log "helm unittest ${chart}"
  helm unittest "${chart}"
else
  log "no ${chart}/tests; skipping helm-unittest"
fi
