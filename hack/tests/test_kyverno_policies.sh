#!/usr/bin/env bash
# Kyverno CLI tests of the rendered kyverno-policies addon (supply-chain gate per environment):
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

finish
