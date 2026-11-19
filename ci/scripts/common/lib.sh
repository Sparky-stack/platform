#!/usr/bin/env bash
# Common helpers for ci/scripts. Sourced, never executed directly.
#
# Portability contract for every script under scripts/:
#   - bash >= 3.2 (macOS /bin/bash): no associative arrays, no mapfile/readarray,
#     no ${var,,}/${var^^}, no `&>>`, no `|&`, no `declare -n`.
#   - BSD and GNU userland: no `sed -i`, no `readlink -f`, no GNU-only flags.
#   - Inputs are environment variables, outputs are files (plus GITHUB_OUTPUT
#     when running in GitHub Actions). See README "Script contract".
set -euo pipefail

log() {
  printf '==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning::%s\n' "$*"
  fi
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# require_env VAR... - fail when any variable is unset or empty.
require_env() {
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      die "required environment variable ${v} is not set"
    fi
  done
}

# require_cmd CMD... - fail when any command is missing from PATH.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command '${c}' not found in PATH"
  done
}

# is_true VALUE - true for true/1/yes/on (any case).
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# lower STRING - portable lowercase.
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# out_dir - directory for file outputs (CI_OUT_DIR, default ./.ci-out).
out_dir() {
  local d="${CI_OUT_DIR:-.ci-out}"
  mkdir -p "$d"
  printf '%s' "$d"
}

# emit_output KEY VALUE - write KEY to GITHUB_OUTPUT (if set) and to
# $CI_OUT_DIR/KEY (if CI_OUT_DIR is set). Single-line values only.
emit_output() {
  local key="$1"
  local val="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$val" >>"$GITHUB_OUTPUT"
  fi
  if [[ -n "${CI_OUT_DIR:-}" ]]; then
    mkdir -p "$CI_OUT_DIR"
    printf '%s\n' "$val" >"${CI_OUT_DIR}/${key}"
  fi
}

# step_summary MARKDOWN - append to the GitHub job summary when available.
step_summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# platform_slug linux/arm64/v8 -> linux-arm64-v8
platform_slug() {
  printf '%s' "$1" | tr '/' '-'
}

# csv_words "a, b,c" -> "a b c" (for `for x in $(csv_words ...)`)
csv_words() {
  printf '%s' "$1" | tr ',' ' '
}

# has_file PATTERN... - true when any of the given paths exists.
has_file() {
  local f
  for f in "$@"; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}
