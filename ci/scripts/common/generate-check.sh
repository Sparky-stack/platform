#!/usr/bin/env bash
# Fail when a code-generation command changes the working tree
# (controller-gen / upjet / `make generate` drift check).
#
# Env in:
#   GENERATE_COMMAND  command to run (required), e.g. "make generate"
#   WORKDIR           directory to run it in and check, default .
# Files out: none (prints the diff on failure)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env GENERATE_COMMAND
require_cmd git
cd "${WORKDIR:-.}"

log "${GENERATE_COMMAND}"
bash -euo pipefail -c "${GENERATE_COMMAND}"

changes="$(git status --porcelain -- .)"
if [[ -n "${changes}" ]]; then
  printf '%s\n' "${changes}" >&2
  git --no-pager diff -- . | head -200 >&2 || true
  die "'${GENERATE_COMMAND}' changed files; run it locally and commit the result"
fi
log "generated code is up to date"
