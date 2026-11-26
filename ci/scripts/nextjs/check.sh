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
export NEXT_TELEMETRY_DISABLED=1 DEFAULT_BUILD_CMD="${DEFAULT_BUILD_CMD:-next build}"
exec bash "${SCRIPT_DIR}/../node/check.sh" "$@"
