#!/usr/bin/env bash
# koorikla-helm-chart step `package`: ci/scripts helm/check.sh (dependency build, lint --strict, helm-unittest) and
# helm/package-push.sh (OCI artifact to the installation's registry). The pushed digest is signed by sign.sh.
#
# Env in:  CHART_DIR (relative to the repository root), PUSH, CI_OUT_DIR, plus the helm scripts' env (CHART_VERSION,
#          OCI_REGISTRY, HELM_*_HOME)
# Out:     /tmp/digest-ref (the chart's digest ref, or "none" without a push)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

registry_trust
export HELM_REGISTRY_CONFIG=/registry-auth/config.json
export CHART_PATH="/work/source/${CHART_DIR#./}"
"$here/../helm/check.sh"
"$here/../helm/package-push.sh"
if [ "$PUSH" = true ]; then cp "$CI_OUT_DIR/image_digest_ref" /tmp/digest-ref; else printf none > /tmp/digest-ref; fi
