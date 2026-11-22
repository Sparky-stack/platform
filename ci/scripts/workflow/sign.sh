#!/usr/bin/env bash
# Steps `sign` of koorikla-build and koorikla-helm-chart: cosign with the platform key (ExternalSecret from the secret
# backend key cosign-platform, mounted at /cosign; the private key is never in git). Cloud installations set the
# ClusterWorkflow's cosign key ref to a KMS URI reached through workload identity instead of a key file.
# ci/scripts/common/sign-image.sh signs the index and (RECURSIVE, default true) every platform manifest and attests the
# Trivy vuln report (VULN_PREDICATE); SBOM_PREDICATE adds the SBOM attestation.
#
# Env in:  DIGEST_REF, COSIGN_KEY, TLOG_UPLOAD ("true": also record in the public Rekor log), CI_OUT_DIR;
#          optional VULN_PREDICATE, SBOM_PREDICATE (koorikla-build), RECURSIVE (koorikla-helm-chart: false)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

registry_trust
export DOCKER_CONFIG=/registry-auth
COSIGN_PASSWORD="$(cat /cosign/cosign.password 2>/dev/null || true)"
export COSIGN_PASSWORD
if [ "$TLOG_UPLOAD" != true ]; then
  # Private by default (installation switch buildWorkflows.signing.transparencyLog): no public Rekor entry
  # leaking repo names and digests. cosign v3 takes a signing config without a transparency log;
  # ci/scripts sign-image.sh has no switch for it yet, so a shim on PATH adds it to sign/attest.
  printf '{ "mediaType": "application/vnd.dev.sigstore.signingconfig.v0.2+json", "rekorTlogConfig": {}, "tsaConfig": {} }\n' > /tmp/signing-config.json
  real=$(command -v cosign); mkdir -p /tmp/bin
  # shellcheck disable=SC2016  # the shim is written with a literal $1 and $@
  printf '#!/bin/sh\ncase "$1" in sign|attest) c=$1; shift; exec %s "$c" --signing-config /tmp/signing-config.json "$@" ;; esac\nexec %s "$@"\n' \
    "$real" "$real" > /tmp/bin/cosign
  chmod 0755 /tmp/bin/cosign; export PATH="/tmp/bin:$PATH"
fi
IMAGE_DIGEST_REF="$DIGEST_REF" "$here/../common/sign-image.sh"
if [ -n "${SBOM_PREDICATE:-}" ]; then
  # Predicate type https://spdx.dev/Document/v2.3 (syft writes SPDX 2.3), the type the app-container.yaml GitHub path attests:
  # admission (addon kyverno-policies attestationTypes.sbom) checks one SBOM type for both build paths.
  # (the cosign type shorthand spdxjson would record https://spdx.dev/Document)
  echo ">> cosign attest --type https://spdx.dev/Document/v2.3 $DIGEST_REF"
  cosign attest --yes --key "$COSIGN_KEY" --type https://spdx.dev/Document/v2.3 --predicate "$SBOM_PREDICATE" "$DIGEST_REF"
fi
