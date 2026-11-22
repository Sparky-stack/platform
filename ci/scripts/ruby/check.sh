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
# brakeman / bundler-audit: from the bundle when Gemfile.lock pins them, else
# installed at the version in gem-versions.env (never an unpinned latest).
# Files out: none
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"
# shellcheck source=gem-versions.env
source "${SCRIPT_DIR}/gem-versions.env"

require_cmd ruby bundle
cd "${WORKDIR:-.}"

# locked GEM - true when GEM is in Gemfile.lock.
locked() {
  [[ -f Gemfile.lock ]] && grep -Eq "^    $1 \(" Gemfile.lock
}

if is_true "${RUN_RUBOCOP:-true}"; then
  if locked rubocop; then
    log "rubocop"
    bundle exec rubocop --format progress
  else
    log "rubocop not in Gemfile.lock; skipping"
  fi
fi

cmd="${TEST_COMMAND:-auto}"
if [[ "${cmd}" == "auto" ]]; then
  if [[ -d spec ]] && locked rspec-core; then
    cmd="bundle exec rspec"
  elif [[ -x bin/rails ]] && locked rails; then
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
  if locked rails || locked railties; then brakeman=true; else brakeman=false; fi
fi
if is_true "${brakeman}"; then
  brakeman_args="${BRAKEMAN_ARGS:---no-pager --quiet}"
  log "brakeman ${brakeman_args}"
  if locked brakeman; then
    # shellcheck disable=SC2086
    bundle exec brakeman ${brakeman_args}
  else
    gem install --no-document --version "${BRAKEMAN_VERSION}" brakeman
    # shellcheck disable=SC2086
    brakeman ${brakeman_args}
  fi
else
  log "not a Rails app; skipping brakeman"
  step_summary "- brakeman: skipped (no rails in Gemfile.lock)"
fi

if is_true "${RUN_AUDIT:-true}"; then
  log "bundler-audit check --update"
  if locked bundler-audit; then
    bundle exec bundle-audit check --update
  else
    gem install --no-document --version "${BUNDLER_AUDIT_VERSION}" bundler-audit
    bundle-audit check --update
  fi
fi
