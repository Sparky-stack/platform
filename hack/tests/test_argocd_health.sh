#!/usr/bin/env bash
# Argo CD resource health customizations of addons/argo-cd (argocd-cm resource.customizations.health.*), evaluated
# offline by the pinned argocd CLI (`argocd admin settings resource-overrides health`) against the fixtures in
# addons/argo-cd/tests/health/: <expected>-<case>.yaml, expected = healthy | degraded | progressing.
#   DeletingPolicy / NamespacedDeletingPolicy: Kyverno never sets conditionStatus.ready on them, Argo CD's built-in
#   check reads that as Degraded; ours is Healthy unless Kyverno reports a False condition or ready=false.
#   PersistentVolumeClaim: Pending (WaitForFirstConsumer) is Healthy.
#   ClusterResourceSet: reconciled without ResourcesApplied (no Cluster matches) is Healthy, not Progressing (#192).
# The argocd CLI comes from mise.toml; skips only when it is missing (ARGOCD=/path/to/argocd overrides).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_argocd_health =="

ARGOCD=${ARGOCD:-argocd}
if ! command -v "$ARGOCD" >/dev/null 2>&1; then
  echo "  SKIP argocd CLI not found (set ARGOCD=/path/to/argocd)"
  finish
  exit 0
fi

render_standalone_addon argo-cd "$TMP/argo-cd.yaml"
yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm")' "$TMP/argo-cd.yaml" > "$TMP/argocd-cm.yaml"
assert_nonempty "$(yq '.data["resource.customizations.health.policies.kyverno.io_NamespacedDeletingPolicy"]' "$TMP/argocd-cm.yaml")" \
  "argocd-cm customizes NamespacedDeletingPolicy health"

n=0
for f in "$ROOT"/addons/argo-cd/tests/health/*.yaml; do
  n=$((n + 1))
  base=$(basename "$f" .yaml)
  want=${base%%-*}
  out=$("$ARGOCD" admin settings resource-overrides health "$f" --argocd-cm-path "$TMP/argocd-cm.yaml" 2>&1) || true
  got=$(printf '%s\n' "$out" | sed -n 's/^STATUS: //p' | tr -d '\r' | tr '[:upper:]' '[:lower:]')
  assert_eq "$got" "$want" "health of $base"
done
assert_eq "$([[ $n -ge 11 ]] && echo yes)" yes "health fixtures present ($n)"

finish
