#!/usr/bin/env bash
# Smoke test for ghcr.io/koorikla/ci-toolbox: every tool runs, scripts work.
set -euo pipefail
for t in bash git jq curl make trivy syft cosign crane helm yq crossplane; do
  command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }
done
trivy --version | head -1
syft version | awk '/^Version/ {print "syft " $2}'
cosign version 2>&1 | awk '/GitVersion/ {print "cosign " $2}'
echo "crane $(crane version)"
helm version --short
yq --version
crossplane version --client
CI_OUT_DIR="$(mktemp -d)" OWNER=koorikla REPO_NAME=koorikla/ci SHA=0123456789abcdef \
  image-meta.sh
echo "toolbox OK ($(uname -m), ${KOORIKLA_CI_VERSION:-dev})"
