#!/usr/bin/env bash
# Detect the Node.js package manager and version file of a project.
#
# Env in:
#   WORKDIR  project directory, default .
# Outputs:
#   pm                 npm | pnpm | yarn
#   lockfile           path relative to WORKDIR ('' when none)
#   node_version_file  .nvmrc | .node-version | .tool-versions | package.json
#                      (relative to the repository root, i.e. prefixed with WORKDIR)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

wd="${WORKDIR:-.}"
[[ -f "${wd}/package.json" ]] || die "${wd}/package.json not found"

pm="npm"
lockfile=""
if [[ -f "${wd}/pnpm-lock.yaml" ]]; then
  pm="pnpm"
  lockfile="pnpm-lock.yaml"
elif [[ -f "${wd}/yarn.lock" ]]; then
  pm="yarn"
  lockfile="yarn.lock"
elif [[ -f "${wd}/package-lock.json" ]]; then
  lockfile="package-lock.json"
elif [[ -f "${wd}/npm-shrinkwrap.json" ]]; then
  lockfile="npm-shrinkwrap.json"
else
  warn "no lockfile in ${wd}; installs are not reproducible"
fi

vfile="package.json"
for f in .nvmrc .node-version .tool-versions; do
  if [[ -f "${wd}/${f}" ]]; then
    if [[ "$f" != ".tool-versions" ]] || grep -Eq '^(nodejs|node)[[:space:]]' "${wd}/${f}"; then
      vfile="$f"
      break
    fi
  fi
done

emit_output pm "${pm}"
emit_output lockfile "${lockfile}"
emit_output node_version_file "${wd%/}/${vfile}"
log "package manager=${pm} lockfile=${lockfile:-none} node version file=${vfile}"
