#!/usr/bin/env bash
# Kyverno CLI tests of rendered admission policies:
#   addons/openchoreo-platform ValidatingAdmissionPolicy openchoreo-gated-bindings-from-git (offline): production
#                              bindings from the gated Argo CD Application pass; from openchoreo-api, from the app's
#                              main Application, another tenant's Application or without tracking-id are denied;
#                              staging is out of scope
# and of the kyverno-policies addon (supply-chain gate per environment):
#   tests/kyverno/registries   offline: trusted-registry policy per environment (Audit vs Deny, default action for
#                              unlisted environments, init/ephemeral containers, platform registry untrusted w/o key)
#   tests/kyverno/platform-key offline: with a platform key only <registry.host>/<appsProject>/ is trusted
#   tests/kyverno/signatures   online (registry + Sigstore): cosign keyless verification of a real signed image;
#                              runs only with KYVERNO_ONLINE=1
# A suite's helm-values.yaml (optional) is passed to helm template. The kyverno CLI comes from mise.toml; skips only
# when it is missing (KYVERNO=/path/to/kyverno overrides).
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
suites=(registries platform-key)
[[ "${KYVERNO_ONLINE:-0}" == "1" ]] && suites+=(signatures)
for s in "${suites[@]}"; do
  hv=()
  [[ -f "$addon/tests/kyverno/$s/helm-values.yaml" ]] && hv=(-f "$addon/tests/kyverno/$s/helm-values.yaml")
  helm template kyverno-policies "$addon" --namespace kyverno -s templates/image-verification.yaml \
    ${hv[@]+"${hv[@]}"} > "$TMP/kyverno/$s/policies.yaml"
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
# who:resources:expected  (staging bindings are out of scope and not counted)
for c in argocd:resources:'pass: 1, fail: 0' api:resources:'pass: 0, fail: 1' argocd:smuggled:'pass: 0, fail: 3'; do
  who=${c%%:*}; rest=${c#*:}; res=${rest%%:*}; want=${rest#*:}
  out=$("$KYVERNO" apply "$TMP/vap.yaml" --resource "$ocp/tests/vap/$res.yaml" --userinfo "$ocp/tests/vap/$who.yaml" \
    --values-file "$ocp/tests/vap/values.yaml" --crd-paths "$TMP/rb-crd.yaml" 2>&1 || true)
  assert_match "$out" "$want" "VAP openchoreo-gated-bindings-from-git: $who applying tests/vap/$res.yaml -> $want"
done

finish
