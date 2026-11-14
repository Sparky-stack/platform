#!/usr/bin/env bash
# Trivy filesystem scan of dependency lockfiles (go.sum, mix.lock,
# Gemfile.lock, package-lock.json, pnpm-lock.yaml, yarn.lock, ...).
#
# Env in:
#   SCAN_PATH        directory to scan, default .
#   SCANNERS         trivy --scanners, default vuln
#   FAIL_SEVERITIES  comma list that fails the scan, default CRITICAL
#   IGNORE_UNFIXED   true/false, default true
#   FAIL_ON_FINDINGS true/false, default true
#   SKIP_DIRS        optional comma list passed to --skip-dirs
#   TRIVY_CACHE_DIR  optional trivy cache dir
#   IGNORE_FILE      optional .trivyignore / .trivyignore.yaml (accepted risks)
#   CI_OUT_DIR       output dir, default ./.ci-out
# Files out ($CI_OUT_DIR):
#   trivy-fs.json, trivy-fs.sarif
# Outputs: fs_sarif
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd trivy jq

out="$(out_dir)"
path="${SCAN_PATH:-.}"
fail_sev="$(printf '%s' "${FAIL_SEVERITIES:-CRITICAL}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"

set -- --quiet --scanners "${SCANNERS:-vuln}" --timeout 10m
if is_true "${IGNORE_UNFIXED:-true}"; then
  set -- "$@" --ignore-unfixed
fi
if [[ -n "${TRIVY_CACHE_DIR:-}" ]]; then
  set -- "$@" --cache-dir "${TRIVY_CACHE_DIR}"
fi
if [[ -n "${IGNORE_FILE:-}" ]]; then
  [[ -f "${IGNORE_FILE}" ]] || die "IGNORE_FILE ${IGNORE_FILE} not found"
  set -- "$@" --ignorefile "${IGNORE_FILE}"
fi
if [[ -n "${SKIP_DIRS:-}" ]]; then
  set -- "$@" --skip-dirs "${SKIP_DIRS}"
fi

log "trivy fs ${path}"
trivy fs "$@" --format json --output "${out}/trivy-fs.json" "${path}"
trivy convert --quiet --format sarif --output "${out}/trivy-fs.sarif" "${out}/trivy-fs.json"
emit_output fs_sarif "${out}/trivy-fs.sarif"

targets="$(jq -r '[.Results[]?.Target] | join(", ")' "${out}/trivy-fs.json")"
n="$(jq --arg sev "${fail_sev}" '
      ($sev | split(",")) as $s
      | [.Results[]?.Vulnerabilities[]? | select(.Severity as $v | $s | index($v))]
      | length' "${out}/trivy-fs.json")"
summary="$(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${out}/trivy-fs.json")"
log "targets: ${targets:-none}; ${summary:-no vulnerabilities}; failing on ${fail_sev}: ${n}"
step_summary "- Trivy fs \`${path}\` (${targets:-no lockfiles}): ${summary:-no vulnerabilities}; ${n} at ${fail_sev}"

if [[ "${n}" -gt 0 ]]; then
  trivy convert --quiet --format table --severity "${fail_sev}" "${out}/trivy-fs.json" >&2 || true
  if is_true "${FAIL_ON_FINDINGS:-true}"; then
    die "${n} dependency vulnerabilities at ${fail_sev}"
  fi
  warn "${n} dependency vulnerabilities at ${fail_sev} (not failing)"
fi
