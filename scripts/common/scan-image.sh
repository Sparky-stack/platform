#!/usr/bin/env bash
# Trivy vulnerability scan of a (multi-arch) container image.
#
# Every platform is scanned once to JSON; SARIF (code scanning) and the
# cosign-vuln predicate are derived from the first platform's report with
# `trivy convert`, so the registry is hit once per platform.
#
# Env in:
#   IMAGE_REF        image to scan (required): repo@sha256:... or local tag
#   IMAGE_SRC        trivy --image-src (e.g. remote, docker); default: trivy's
#   PLATFORMS        comma list, default linux/amd64 (only used when
#                    IMAGE_SRC=remote; a local image has a single platform)
#   FAIL_SEVERITIES  comma list that fails the scan, default CRITICAL
#   IGNORE_UNFIXED   true/false, default true
#   FAIL_ON_FINDINGS true/false, default true (false = report only)
#   TRIVY_CACHE_DIR  optional trivy cache dir
#   CI_OUT_DIR       output dir, default ./.ci-out
# Files out ($CI_OUT_DIR):
#   trivy-<os>-<arch>.json   full report per platform
#   trivy.sarif              SARIF (first platform)
#   trivy-vuln.json          cosign-vuln predicate (first platform)
# Exit: 1 when findings at FAIL_SEVERITIES exist and FAIL_ON_FINDINGS=true.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env IMAGE_REF
require_cmd trivy jq

out="$(out_dir)"
platforms="${PLATFORMS:-linux/amd64}"
fail_sev="$(printf '%s' "${FAIL_SEVERITIES:-CRITICAL}" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"

common_args="--quiet --scanners vuln --timeout 15m"
if is_true "${IGNORE_UNFIXED:-true}"; then
  common_args="${common_args} --ignore-unfixed"
fi
if [[ -n "${TRIVY_CACHE_DIR:-}" ]]; then
  common_args="${common_args} --cache-dir ${TRIVY_CACHE_DIR}"
fi

if [[ "${IMAGE_SRC:-}" != "remote" ]]; then
  # Local image: exactly one platform, whatever was loaded.
  platforms="local"
fi

total_fail=0
first_json=""
for p in $(csv_words "${platforms}"); do
  slug="$(platform_slug "$p")"
  json="${out}/trivy-${slug}.json"
  plat_args=""
  if [[ "$p" != "local" ]]; then
    plat_args="--platform ${p}"
  fi
  if [[ -n "${IMAGE_SRC:-}" ]]; then
    plat_args="${plat_args} --image-src ${IMAGE_SRC}"
  fi
  log "trivy image ${IMAGE_REF} (${p})"
  # shellcheck disable=SC2086
  trivy image ${common_args} ${plat_args} --format json --output "${json}" "${IMAGE_REF}"
  [[ -n "${first_json}" ]] || first_json="${json}"

  n="$(jq --arg sev "${fail_sev}" '
        ($sev | split(",")) as $s
        | [.Results[]?.Vulnerabilities[]? | select(.Severity as $v | $s | index($v))]
        | length' "${json}")"
  summary="$(jq -r '[.Results[]?.Vulnerabilities[]?.Severity] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${json}")"
  log "${p}: ${summary:-no vulnerabilities} (failing on ${fail_sev}: ${n})"
  step_summary "- Trivy \`${p}\`: ${summary:-no vulnerabilities}; ${n} at ${fail_sev}"
  total_fail=$((total_fail + n))
done

trivy convert --quiet --format sarif --output "${out}/trivy.sarif" "${first_json}"
trivy convert --quiet --format cosign-vuln --output "${out}/trivy-vuln.json" "${first_json}"
emit_output sarif "${out}/trivy.sarif"
emit_output vuln_predicate "${out}/trivy-vuln.json"

if [[ "${total_fail}" -gt 0 ]]; then
  trivy convert --quiet --format table --severity "${fail_sev}" "${first_json}" >&2 || true
  if is_true "${FAIL_ON_FINDINGS:-true}"; then
    die "${total_fail} vulnerabilities at ${fail_sev} (set trivy_fail=false or adjust trivy_severity)"
  fi
  warn "${total_fail} vulnerabilities at ${fail_sev} (not failing: FAIL_ON_FINDINGS=false)"
fi
