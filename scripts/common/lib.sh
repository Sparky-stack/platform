#!/usr/bin/env bash
# Common CI helper functions for koorikla/ci scripts.
# Works both in GitHub Actions and in-cluster builds (ci-toolbox).
set -euo pipefail

log() {
  printf '==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

emit_output() {
  local key="$1"
  local val="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$val" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${CI_OUT_DIR:-}" ]]; then
    mkdir -p "$CI_OUT_DIR"
    printf '%s' "$val" > "${CI_OUT_DIR}/${key}"
  fi
}
