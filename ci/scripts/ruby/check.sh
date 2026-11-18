#!/usr/bin/env bash
# Ruby / Rails checks: rubocop, tests, brakeman, bundler-audit.
# Assumes gems are installed (`bundle install`; setup-ruby bundler-cache).
#
# Env in:
#   WORKDIR         project directory, default .
#   RUN_RUBOCOP     default true  (if rubocop is in Gemfile.lock)
#   TEST_COMMAND    default auto: bundle exec rspec (spec/ + rspec in lockfile)
#                   | bin/rails test (Rails) | bundle exec rake test (Rakefile)
#   RUN_BRAKEMAN    default auto: true when rails is in Gemfile.lock
#   BRAKEMAN_ARGS   default "--no-pager --quiet" (fails on warnings)
#   RUN_AUDIT       default true (bundler-audit; installed if not bundled)
# Files out: none
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd ruby bundle
cd "${WORKDIR:-.}"

in_lock() {
  [[ -f Gemfile.lock ]] && grep -Eq "^    $1 \(" Gemfile.lock
}

if is_true "${RUN_RUBOCOP:-true}"; then
  if in_lock rubocop; then
    log "rubocop"
    bundle exec rubocop --format progress
  else
    log "rubocop not in Gemfile.lock; skipping"
  fi
fi

cmd="${TEST_COMMAND:-auto}"
if [[ "${cmd}" == "auto" ]]; then
  if [[ -d spec ]] && in_lock rspec-core; then
    cmd="bundle exec rspec"
  elif [[ -x bin/rails ]] && in_lock rails; then
    cmd="bin/rails test"
  elif [[ -f Rakefile ]]; then
    cmd="bundle exec rake test"
  else
    cmd=""
    warn "no test runner detected (spec/ + rspec, bin/rails, Rakefile); skipping tests"
  fi
fi
if [[ -n "${cmd}" && "${cmd}" != "none" ]]; then
  log "tests: ${cmd}"
  bash -euo pipefail -c "${cmd}"
fi

brakeman="${RUN_BRAKEMAN:-auto}"
if [[ "${brakeman}" == "auto" ]]; then
  if in_lock rails || in_lock railties; then brakeman=true; else brakeman=false; fi
fi
if is_true "${brakeman}"; then
  log "brakeman ${BRAKEMAN_ARGS:---no-pager --quiet}"
  if in_lock brakeman; then
    # shellcheck disable=SC2086
    bundle exec brakeman ${BRAKEMAN_ARGS:---no-pager --quiet}
  else
    gem install --no-document brakeman
    # shellcheck disable=SC2086
    brakeman ${BRAKEMAN_ARGS:---no-pager --quiet}
  fi
else
  log "not a Rails app; skipping brakeman"
  step_summary "- brakeman: skipped (no rails in Gemfile.lock)"
fi

if is_true "${RUN_AUDIT:-true}"; then
  log "bundler-audit check --update"
  if in_lock bundler-audit; then
    bundle exec bundle-audit check --update
  else
    gem install --no-document bundler-audit
    bundle-audit check --update
  fi
fi
