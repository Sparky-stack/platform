#!/usr/bin/env bash
# Emit the GitHub Actions build matrix for container.yaml.
#
# Env in:
#   PLATFORMS      comma list, default linux/amd64,linux/arm64
#   STRATEGY       native (one runner per arch, merged into one manifest list)
#                  | qemu (single amd64 runner, buildx + QEMU), default native
#   SHOULD_PUSH    true/false; false (PRs) builds linux/amd64 only
#   RUNNER_AMD64   default ubuntu-24.04
#   RUNNER_ARM64   default ubuntu-24.04-arm
# Outputs:
#   matrix  JSON {"include":[{"platforms":..,"runner":..,"slug":..}, ...]}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

platforms="$(printf '%s' "${PLATFORMS:-linux/amd64,linux/arm64}" | tr -d '[:space:]')"
strategy="${STRATEGY:-native}"
amd="${RUNNER_AMD64:-ubuntu-24.04}"
arm="${RUNNER_ARM64:-ubuntu-24.04-arm}"

entry() {
  printf '{"platforms":"%s","runner":"%s","slug":"%s"}' "$1" "$2" "$3"
}

if ! is_true "${SHOULD_PUSH:-false}"; then
  matrix="{\"include\":[$(entry linux/amd64 "${amd}" linux-amd64)]}"
elif [[ "${strategy}" == "qemu" ]]; then
  matrix="{\"include\":[$(entry "${platforms}" "${amd}" multi)]}"
elif [[ "${strategy}" == "native" ]]; then
  items=""
  for p in $(csv_words "${platforms}"); do
    case "$p" in
      linux/arm64* | linux/arm/*) r="${arm}" ;;
      *) r="${amd}" ;;
    esac
    [[ -z "${items}" ]] || items="${items},"
    items="${items}$(entry "$p" "$r" "$(platform_slug "$p")")"
  done
  matrix="{\"include\":[${items}]}"
else
  die "STRATEGY must be native or qemu (got ${strategy})"
fi

emit_output matrix "${matrix}"
log "matrix=${matrix}"
