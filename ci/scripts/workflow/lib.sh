#!/usr/bin/env bash
# Helpers shared by the step scripts in this directory. Sourced, never executed directly.

# registry_trust: Go tools (trivy, syft, cosign, crane, helm) read SSL_CERT_FILE. The registry CA (absent for
# external registries with a public CA) is appended to the system bundle, so public registries (Trivy DB, Sigstore)
# keep working. The bundle lives in the pod's own /tmp emptyDir.
registry_trust() {
  cat /etc/ssl/certs/ca-certificates.crt > /tmp/ca.pem
  if [ -f /registry-ca/ca.crt ]; then cat /registry-ca/ca.crt >> /tmp/ca.pem; fi
  export SSL_CERT_FILE=/tmp/ca.pem
}
