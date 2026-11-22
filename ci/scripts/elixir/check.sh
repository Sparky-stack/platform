#!/usr/bin/env bash
# Elixir checks: deps.get, compile --warnings-as-errors, format check, credo,
# test, sobelow, hex.audit, deps.audit. Optional tools run only when the
# project depends on them (looked up in mix.lock), so a plain mix project
# without Phoenix/sobelow passes cleanly.
#
# Env in:
#   WORKDIR            project directory, default .
#   MIX_ENV            default test
#   RUN_FORMAT         default true
#   RUN_CREDO          default true  (if :credo in mix.lock)
#   CREDO_ARGS         default --strict
#   RUN_TEST           default true
#   TEST_ARGS          extra `mix test` args, e.g. --cover
#   RUN_SOBELOW        default true  (if :sobelow in mix.lock)
#   SOBELOW_ARGS       default "--exit low --skip" (respects .sobelow-conf)
#   RUN_AUDIT          default true  (mix hex.audit; mix deps.audit if :mix_audit)
# Files out: _build/, deps/ (cache them keyed on mix.lock)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd mix
cd "${WORKDIR:-.}"
export MIX_ENV="${MIX_ENV:-test}"

# locked DEP - true when DEP is in mix.lock.
locked() {
  [[ -f mix.lock ]] && grep -q "\"$1\": {" mix.lock
}

log "mix deps.get"
mix deps.get

log "mix compile --warnings-as-errors"
mix compile --warnings-as-errors

if is_true "${RUN_FORMAT:-true}"; then
  log "mix format --check-formatted"
  mix format --check-formatted
fi

if is_true "${RUN_CREDO:-true}"; then
  if locked credo; then
    log "mix credo ${CREDO_ARGS:---strict}"
    # shellcheck disable=SC2086
    mix credo ${CREDO_ARGS:---strict}
  else
    log "credo not in mix.lock; skipping"
  fi
fi

if is_true "${RUN_TEST:-true}"; then
  log "mix test ${TEST_ARGS:-}"
  # shellcheck disable=SC2086
  mix test ${TEST_ARGS:-}
fi

if is_true "${RUN_SOBELOW:-true}"; then
  if locked sobelow; then
    log "mix sobelow ${SOBELOW_ARGS:---exit low --skip}"
    # shellcheck disable=SC2086
    mix sobelow ${SOBELOW_ARGS:---exit low --skip}
  else
    log "sobelow not in mix.lock (not a Phoenix app?); skipping"
    step_summary "- sobelow: skipped (not a dependency)"
  fi
fi

if is_true "${RUN_AUDIT:-true}"; then
  log "mix hex.audit (retired packages)"
  mix hex.audit
  if locked mix_audit; then
    log "mix deps.audit (security advisories)"
    mix deps.audit
  else
    warn "mix_audit not in mix.lock; add {:mix_audit, \"~> 2.1\", only: [:dev, :test], runtime: false} for advisory checks (Trivy fs still scans mix.lock)"
  fi
fi
