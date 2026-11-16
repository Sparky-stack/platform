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
#   tests/kyverno/signatures   online (registry + Sigstore): cosign keyless verification of a real signed image (built
#                              through koorikla/ci@v1, so rejected by the commit-SHA identity pin); KYVERNO_ONLINE=1 only
# A suite's helm-values.yaml (optional) is passed to helm template. The kyverno CLI comes from mise.toml; skips only
# when it is missing (KYVERNO=/path/to/kyverno overrides).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_kyverno_policies =="

# Keyless identity (#41): the trusted koorikla/ci workflow is a commit SHA, and Renovate's custom manager
# (renovate.json) really matches that line - otherwise the pin would silently never be bumped.
wf_ref=$(yq -r '.imageVerification.github.workflowRef' "$ROOT/addons/kyverno-policies/values.yaml" | tr -d '\r')
assert_match "$wf_ref" '^[0-9a-f]{40}$' "kyverno-policies trusts koorikla/ci by commit SHA"
renovated=$(py - "$ROOT/renovate.json" "$ROOT/addons/kyverno-policies/values.yaml" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1]))
text = open(sys.argv[2]).read()
for m in cfg.get("customManagers", []):
    if not any(re.search(p.strip("/"), "addons/kyverno-policies/values.yaml") for p in m.get("managerFilePatterns", [])):
        continue
    for ms in m.get("matchStrings", []):
        hit = re.search(ms.replace("(?<", "(?P<"), text)
        if hit and m.get("depNameTemplate") == "koorikla/ci":
            print(hit.group("currentDigest"), hit.group("currentValue"))
PY
)
assert_eq "${renovated%% *}" "$wf_ref" "renovate.json custom manager tracks workflowRef (datasource github-tags koorikla/ci)"

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
