#!/usr/bin/env bash
# Kyverno CLI tests of rendered admission policies:
#   addons/openchoreo-platform ValidatingAdmissionPolicy openchoreo-gated-bindings-from-git (offline): production
#                              bindings from Argo CD pass, from openchoreo-api are denied, staging is out of scope
# and of the kyverno-policies addon (supply-chain gate per environment):
#   tests/kyverno/registries   offline: trusted-registry policy per environment (Audit vs Deny, scoping)
#   tests/kyverno/signatures   online (registry + Sigstore): cosign keyless verification of a real signed image;
#                              runs only with KYVERNO_ONLINE=1
# Skips when the kyverno CLI is not installed (optional tool: https://github.com/kyverno/kyverno/releases, = addons/kyverno appVersion).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_kyverno_policies =="
KYVERNO=${KYVERNO:-kyverno}
if ! command -v "$KYVERNO" >/dev/null 2>&1; then
  echo "  SKIP kyverno CLI not found (set KYVERNO=/path/to/kyverno)"
  finish
  exit 0
fi

addon="$ROOT/addons/kyverno-policies"
[[ -d "$addon/charts" ]] || helm dependency build "$addon" >/dev/null
cp -R "$addon/tests/kyverno" "$TMP/kyverno"
suites=(registries)
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] && suites+=(signatures)
for s in "${suites[@]}"; do
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/image-verification.yaml \
    > "$TMP/kyverno/$s/policies.yaml"
  if out=$("$KYVERNO" test "$TMP/kyverno/$s" 2>&1) && [[ "$out" =~ "0 tests failed" ]]; then
    assert_eq ok ok "kyverno test $s"
  else
    echo "$out" >&2
    assert_eq failed ok "kyverno test $s"
  fi
done
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] || echo "  SKIP signatures (needs network: KYVERNO_ONLINE=1)"

# Native VAP: promotion to gated environments only through git (Argo CD)
ocp="$ROOT/addons/openchoreo-platform"
cp_chart="$ROOT/addons/openchoreo-control-plane"
[[ -d "$cp_chart/charts" ]] || helm dependency build "$cp_chart" >/dev/null
helm show crds "$cp_chart" | yq 'select(.metadata.name == "releasebindings.openchoreo.dev")' > "$TMP/rb-crd.yaml"
helm template openchoreo-platform "$ocp" --namespace default -s templates/promotion-git-only.yaml > "$TMP/vap.yaml"
for who in argocd:pass api:fail; do
  out=$("$KYVERNO" apply "$TMP/vap.yaml" --resource "$ocp/tests/vap/resources.yaml" --userinfo "$ocp/tests/vap/${who%%:*}.yaml" \
    --values-file "$ocp/tests/vap/values.yaml" --crd-paths "$TMP/rb-crd.yaml" 2>&1 || true)
  if [[ "${who##*:}" == pass ]]; then want='pass: 1, fail: 0'; else want='pass: 0, fail: 1'; fi
  assert_match "$out" "$want" "VAP openchoreo-gated-bindings-from-git: ${who%%:*} -> ${who##*:} (staging skipped)"
done

finish
