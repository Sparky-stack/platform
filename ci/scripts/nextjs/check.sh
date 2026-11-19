#!/usr/bin/env bash
# Next.js checks: install, lint, typecheck, test, next build, dependency audit.
#
# Env in:
#   WORKDIR           project directory, default .
#   PM                npm | pnpm | yarn (default: from the lockfile, else npm)
#   RUN_LINT          default true  (runs the `lint` script if defined)
#   RUN_TYPECHECK     default true  (`typecheck` script, else tsc --noEmit when
#                     tsconfig.json exists)
#   RUN_TEST          default true  (`test` script if defined)
#   RUN_BUILD         default true  (`build` script, i.e. next build)
#   RUN_AUDIT         default true
#   AUDIT_LEVEL       low | moderate | high | critical, default critical
#   LINT_SCRIPT TYPECHECK_SCRIPT TEST_SCRIPT BUILD_SCRIPT  script name overrides
# Files out:
#   $WORKDIR/.next (build output)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd node jq
cd "${WORKDIR:-.}"

pm="${PM:-}"
if [[ -z "${pm}" ]]; then
  if [[ -f pnpm-lock.yaml ]]; then pm=pnpm; elif [[ -f yarn.lock ]]; then pm=yarn; else pm=npm; fi
fi
require_cmd "${pm}"
export NEXT_TELEMETRY_DISABLED=1

yarn_berry=false
if [[ "${pm}" == "yarn" ]] && [[ -f .yarnrc.yml ]]; then
  yarn_berry=true
fi

has_script() {
  [[ -n "$(jq -r --arg s "$1" '.scripts[$s] // empty' package.json)" ]]
}

run_script() {
  log "${pm} run $1"
  "${pm}" run "$1"
}

log "install (${pm})"
case "${pm}" in
  npm)
    if [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
      npm ci --no-audit --no-fund
    else
      npm install --no-audit --no-fund
    fi
    ;;
  pnpm) pnpm install --frozen-lockfile ;;
  yarn)
    if [[ "${yarn_berry}" == "true" ]]; then
      yarn install --immutable
    else
      yarn install --frozen-lockfile
    fi
    ;;
  *) die "unsupported package manager ${pm}" ;;
esac

if is_true "${RUN_LINT:-true}"; then
  if has_script "${LINT_SCRIPT:-lint}"; then
    run_script "${LINT_SCRIPT:-lint}"
  else
    warn "no '${LINT_SCRIPT:-lint}' script; skipping lint"
  fi
fi

if is_true "${RUN_TYPECHECK:-true}"; then
  if has_script "${TYPECHECK_SCRIPT:-typecheck}"; then
    run_script "${TYPECHECK_SCRIPT:-typecheck}"
  elif [[ -f tsconfig.json ]]; then
    log "tsc --noEmit"
    case "${pm}" in
      npm) npx --no-install tsc --noEmit ;;
      *) "${pm}" exec tsc --noEmit ;;
    esac
  fi
fi

if is_true "${RUN_TEST:-true}"; then
  if has_script "${TEST_SCRIPT:-test}"; then
    run_script "${TEST_SCRIPT:-test}"
  else
    warn "no '${TEST_SCRIPT:-test}' script; skipping tests"
  fi
fi

if is_true "${RUN_BUILD:-true}"; then
  if has_script "${BUILD_SCRIPT:-build}"; then
    run_script "${BUILD_SCRIPT:-build}"
  else
    log "next build"
    case "${pm}" in
      npm) npx --no-install next build ;;
      *) "${pm}" exec next build ;;
    esac
  fi
fi

if is_true "${RUN_AUDIT:-true}"; then
  level="${AUDIT_LEVEL:-critical}"
  log "dependency audit (${pm}, production deps, level ${level})"
  case "${pm}" in
    npm) npm audit --omit=dev --audit-level="${level}" ;;
    pnpm) pnpm audit --prod --audit-level "${level}" ;;
    yarn)
      if [[ "${yarn_berry}" == "true" ]]; then
        yarn npm audit --environment production --severity "${level}"
      else
        yarn audit --groups dependencies --level "${level}"
      fi
      ;;
  esac
fi
