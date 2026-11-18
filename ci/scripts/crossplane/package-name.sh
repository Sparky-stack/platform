#!/usr/bin/env bash
# Read the package name (metadata.name) from a Crossplane crossplane.yaml.
#
# Env in:
#   PACKAGE_ROOT  directory with crossplane.yaml, default .
#   PACKAGE_NAME  explicit override (returned as-is when set)
# Outputs:
#   name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

name="${PACKAGE_NAME:-}"
if [[ -z "${name}" ]]; then
  require_cmd yq
  f="${PACKAGE_ROOT:-.}/crossplane.yaml"
  [[ -f "$f" ]] || die "$f not found"
  name="$(yq -r '.metadata.name' "$f")"
fi
[[ -n "${name}" && "${name}" != "null" ]] || die "could not determine package name"
emit_output name "${name}"
