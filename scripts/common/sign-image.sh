#!/usr/bin/env bash
# Sign an OCI artifact (image index, image or xpkg) with cosign and optionally
# attach a vulnerability attestation.
#
# Env in:
#   IMAGE_DIGEST_REF  required: <registry>/<repo>@sha256:...
#   VULN_PREDICATE    optional: cosign-vuln predicate file (trivy convert output)
#   RECURSIVE         true/false, default true: also sign each platform manifest
#                     of a multi-arch index
#   COSIGN_KEY        optional key ref (file, k8s://ns/secret, KMS URI) used by
#                     in-cluster builds; unset = Sigstore keyless (GitHub OIDC)
# Files out:
#   $CI_OUT_DIR/signed_ref (when CI_OUT_DIR is set)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env IMAGE_DIGEST_REF
require_cmd cosign

case "${IMAGE_DIGEST_REF}" in
  *@sha256:*) ;;
  *) die "IMAGE_DIGEST_REF must be a digest reference (got ${IMAGE_DIGEST_REF})" ;;
esac

key_args=""
mode="keyless (Sigstore OIDC)"
if [[ -n "${COSIGN_KEY:-}" ]]; then
  key_args="--key ${COSIGN_KEY}"
  mode="key ${COSIGN_KEY}"
fi

sign_args=""
if is_true "${RECURSIVE:-true}"; then
  sign_args="--recursive"
fi

log "cosign sign ${IMAGE_DIGEST_REF} [${mode}]"
# shellcheck disable=SC2086
cosign sign --yes ${key_args} ${sign_args} "${IMAGE_DIGEST_REF}"

if [[ -n "${VULN_PREDICATE:-}" ]]; then
  if [[ -f "${VULN_PREDICATE}" ]]; then
    log "cosign attest --type vuln ${IMAGE_DIGEST_REF}"
    # shellcheck disable=SC2086
    cosign attest --yes ${key_args} --type vuln --predicate "${VULN_PREDICATE}" "${IMAGE_DIGEST_REF}"
  else
    warn "VULN_PREDICATE ${VULN_PREDICATE} not found; skipping vuln attestation"
  fi
fi

emit_output signed_ref "${IMAGE_DIGEST_REF}"
step_summary "- Signed \`${IMAGE_DIGEST_REF}\` (${mode})"
