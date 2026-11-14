#!/usr/bin/env bash
# Sign a container image (or OCI artifact) and optionally attach a Trivy
# vulnerability attestation.
#
# Contract:
#   Env in:
#     IMAGE_DIGEST_REF  (required: <registry>/<repo>@sha256:...)
#     VULN_PREDICATE    (optional: path to cosign-vuln JSON file)
#     COSIGN_KEY        (optional: KMS/file/k8s key ref for in-cluster builds;
#                        when unset, uses Sigstore keyless OIDC)
#   Files out:
#     ${CI_OUT_DIR}/signed_ref (if CI_OUT_DIR is set)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

if [[ -z "${IMAGE_DIGEST_REF:-}" ]]; then
  echo "ERROR: IMAGE_DIGEST_REF is required" >&2
  exit 1
fi

if [[ -n "${COSIGN_KEY:-}" ]]; then
  log "Signing ${IMAGE_DIGEST_REF} with key ${COSIGN_KEY}"
  cosign sign --yes --key "${COSIGN_KEY}" "${IMAGE_DIGEST_REF}"
  if [[ -n "${VULN_PREDICATE:-}" && -f "${VULN_PREDICATE}" ]]; then
    log "Attesting vulnerability scan for ${IMAGE_DIGEST_REF} with key"
    cosign attest --yes --key "${COSIGN_KEY}" --type vuln --predicate "${VULN_PREDICATE}" "${IMAGE_DIGEST_REF}"
  fi
else
  log "Signing ${IMAGE_DIGEST_REF} keyless (Sigstore OIDC)"
  cosign sign --yes "${IMAGE_DIGEST_REF}"
  if [[ -n "${VULN_PREDICATE:-}" && -f "${VULN_PREDICATE}" ]]; then
    log "Attesting vulnerability scan for ${IMAGE_DIGEST_REF} keyless"
    cosign attest --yes --type vuln --predicate "${VULN_PREDICATE}" "${IMAGE_DIGEST_REF}"
  fi
fi

emit_output "signed_ref" "${IMAGE_DIGEST_REF}"
