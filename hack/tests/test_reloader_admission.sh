#!/usr/bin/env bash
# Reloader rollout guard (#268), evaluated offline with the kyverno CLI (CEL, same language as the API server).
# On workload clusters Reloader watches cluster-wide so it can roll app Deployments in tenant cells (dp-*, runtime
# names) when their OpenBao-backed Secret rotates. Its ClusterRole could update any workload; VAP reloader-rollout-only
# (addons/reloader/templates/rollout-guard.yaml) admits Reloader's writes only in cells (incl. previews) and
# rolloutGuard.platformNamespaces. The CLI evaluates as CREATE (oldObject unset), so this checks the namespace fence;
# the UPDATE rule (only the rollout annotation may change) is pinned by addons/reloader/tests/reloader_test.yaml.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if ! command -v kyverno >/dev/null 2>&1; then
  echo "  SKIP: kyverno CLI not installed (mise install)"
  exit 0
fi
cd "$ROOT"

helm template reloader addons/reloader --namespace reloader -s templates/rollout-guard.yaml > "$TMP/guard.yaml"
yq 'select(.kind == "ValidatingAdmissionPolicy")' "$TMP/guard.yaml" > "$TMP/policy.yaml"
assert_eq "$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions[]' "$TMP/guard.yaml")" \
  Deny "binding denies"

# Namespace labels as OpenChoreo renders them on a cell (ClusterProjectType default: metadata.labels).
cat > "$TMP/values.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Value
metadata: { name: values }
namespaceSelector:
  - name: dp-default-demo-development-ad621210
    labels: { openchoreo.dev/project: demo, openchoreo.dev/environment: development }
  - name: dp-default-demo-pr-7-1a2b3c4d
    labels: { openchoreo.dev/project: demo, openchoreo.dev/environment: pr-7 }
  - name: dp-lookalike
    labels: { openchoreo.dev/project: demo }
  - name: openchoreo-data-plane
    labels: { kubernetes.io/metadata.name: openchoreo-data-plane }
  - name: kube-system
    labels: { kubernetes.io/metadata.name: kube-system }
YAML

# check <kind> <namespace> <username> <pass|fail|skip> <label>
check() {
  local kind=$1 ns=$2 user=$3 want=$4 label=$5 out got
  printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: UserInfo\nmetadata: { name: u }\nuserInfo:\n  username: %s\n' "$user" > "$TMP/user.yaml"
  printf 'apiVersion: apps/v1\nkind: %s\nmetadata: { name: app, namespace: %s }\nspec:\n  selector: { matchLabels: { app: x } }\n  template:\n    metadata: { labels: { app: x } }\n    spec: { containers: [ { name: main, image: ghcr.io/koorikla/hello-world:1 } ] }\n' \
    "$kind" "$ns" > "$TMP/res.yaml"
  out=$(kyverno apply "$TMP/policy.yaml" --resource "$TMP/res.yaml" --userinfo "$TMP/user.yaml" -f "$TMP/values.yaml" 2>&1 || true)
  got=$(printf '%s\n' "$out" | sed -n 's/^pass: \([0-9]*\), fail: \([0-9]*\), warn: [0-9]*, error: \([0-9]*\), skip: \([0-9]*\).*/p\1 f\2 e\3 s\4/p')
  case "$got" in
    "p1 f0 e0 s0") got=pass ;;
    "p0 f1 e0 s0") got=fail ;;
    "p0 f0 e0 s1"|"p0 f0 e0 s0") got=skip ;;
    *) got="unexpected: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" ;;
  esac
  assert_eq "$got" "$want" "$label"
}

R=system:serviceaccount:reloader:reloader
check Deployment dp-default-demo-development-ad621210 "$R" pass "Reloader rolls an app in a tenant cell"
check Deployment dp-default-demo-pr-7-1a2b3c4d "$R" pass "Reloader rolls an app in a preview cell"
check StatefulSet dp-default-demo-development-ad621210 "$R" pass "Reloader rolls a StatefulSet in a tenant cell"
check Deployment openchoreo-data-plane "$R" pass "Reloader rolls cluster-agent in openchoreo-data-plane"
check Deployment kube-system "$R" fail "negative: Reloader writes a Deployment in kube-system"
check DaemonSet kube-system "$R" fail "negative: Reloader writes a DaemonSet (node agent) in kube-system"
check Deployment dp-lookalike "$R" fail "negative: namespace with a project label but no environment (not a cell)"
check Deployment kube-system system:serviceaccount:kube-system:deployment-controller skip "other users are not matched"

finish
