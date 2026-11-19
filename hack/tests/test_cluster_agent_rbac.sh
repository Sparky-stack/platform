#!/usr/bin/env bash
# Least-privilege RBAC of OpenChoreo's workflow-plane cluster-agent (#33, addon openchoreo-workflow-plane
# templates/cluster-agent-rbac.yaml). The agent replays the control plane's API requests with its own ServiceAccount, so
# its RBAC is the control plane's reach into mgmt. Over every manifest rendered for mgmt (each installation with
# RENDERED_DIR from hack/test.sh, else the standalone renders of the two addons that grant it anything):
#   - clusterAgentRBAC.serviceAccount is the agent Deployment's ServiceAccount; the upstream ClusterRole
#     cluster-agent-workflowplane is gone
#   - every grant resolves to a role rendered here (no cluster-admin / edit), no aggregation, no wildcards, no
#     escalate/bind/impersonate, no SecretStores/ClusterSecretStores/PushSecrets, no Secrets at all (cluster-wide write
#     verbs on secrets are the regression this guards), cluster-wide only namespaces get/create, namespaced grants only
#     in workflows-*
#   - namespace creation is limited to workflows-* by a ValidatingAdmissionPolicy (kyverno CLI: allowed + denied)
#   - what OpenChoreo 1.3.3 needs is still granted (kubectl-free auth check of the rules: runs, logs, generators)
# Negative: the upstream RBAC (clusterAgent.rbac.create=true) and synthetic bindings must be reported.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"
wp=addons/openchoreo-workflow-plane
agent_ns=openchoreo-workflow-plane
for c in addons/openchoreo-workflow-plane addons/openchoreo-platform; do
  [[ -d "$c/charts" ]] || helm dependency build "$c" >/dev/null
done
# The agent's identity comes from the rendered Deployment (whatever the values say).
helm template openchoreo-workflow-plane "$wp" --namespace "$agent_ns" > "$TMP/wp-default.yaml"
agent_sa=$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cluster-agent-workflowplane") | .spec.template.spec.serviceAccountName' \
  "$TMP/wp-default.yaml")
assert_nonempty "$agent_sa" "the agent Deployment cluster-agent-workflowplane is rendered with a ServiceAccount"
assert_eq "$(yq -r '.clusterAgentRBAC.serviceAccount' "$wp/values.yaml" | tr -d '\r')" "$agent_sa" \
  "clusterAgentRBAC.serviceAccount is the agent's ServiceAccount"
assert_eq "$(yq -r '.["openchoreo-workflow-plane"].clusterAgent.rbac.create' "$wp/values.yaml" | tr -d '\r')" false \
  "upstream agent RBAC is off (openchoreo-workflow-plane.clusterAgent.rbac.create)"

check() { yq -o=json -I=0 '.' "$@" | py hack/tests/cluster_agent_rbac.py "$agent_ns/$agent_sa"; }
sets=()
if [[ -n "${RENDERED_DIR:-}" && -d "${RENDERED_DIR:-}" ]]; then
  for f in "$RENDERED_DIR"/addon-openchoreo-workflow-plane-*-mgmt.yaml; do
    [[ -s "$f" ]] || continue
    inst=${f#"$RENDERED_DIR"/addon-openchoreo-workflow-plane-}; inst=${inst%-mgmt.yaml}
    sets+=("$inst")
  done
fi
if [[ ${#sets[@]} -eq 0 ]]; then
  helm template openchoreo-workflow-plane "$wp" --namespace "$agent_ns" > "$TMP/addon-openchoreo-workflow-plane-standalone-mgmt.yaml"
  helm template openchoreo-platform addons/openchoreo-platform --namespace openchoreo-control-plane \
    > "$TMP/addon-openchoreo-platform-standalone-mgmt.yaml"
  dir=$TMP; sets=(standalone)
else
  dir=$RENDERED_DIR
fi

for inst in "${sets[@]}"; do
  files=()
  for f in "$dir"/addon-*-"$inst"-mgmt.yaml; do [[ -s "$f" ]] && files+=("$f"); done
  w="$dir/addon-openchoreo-workflow-plane-$inst-mgmt.yaml"
  out=$(check "${files[@]}")
  assert_eq "$(printf '%s\n' "$out" | grep '^VIOLATION' || true)" "" "$inst: agent RBAC has no violation (${#files[@]} mgmt renders)"
  assert_eq "$(yq -N 'select(.kind == "Deployment" and .metadata.name == "cluster-agent-workflowplane") | .spec.template.spec.serviceAccountName' "$w")" \
    "$agent_sa" "$inst: the agent Deployment runs as $agent_sa"
  assert_eq "$(yq -N 'select(.kind == "ClusterRole" and .metadata.name == "cluster-agent-workflowplane") | .metadata.name' "$w")" "" \
    "$inst: upstream ClusterRole cluster-agent-workflowplane is not rendered"
  # What OpenChoreo 1.3.3 sends through the agent must still be granted (scope, group, resource, verb).
  for need in "cluster  namespaces create" "cluster  namespaces get" \
    "namespace:workflows-default  serviceaccounts create" "namespace:workflows-default rbac.authorization.k8s.io roles create" \
    "namespace:workflows-default rbac.authorization.k8s.io rolebindings create" \
    "namespace:workflows-default argoproj.io workflowtaskresults create" "namespace:workflows-default argoproj.io workflowtaskresults patch" \
    "namespace:workflows-default argoproj.io workflows create" "namespace:workflows-default argoproj.io workflows update" \
    "namespace:workflows-default argoproj.io workflows delete" "namespace:workflows-default argoproj.io workflows get" \
    "namespace:workflows-default external-secrets.io externalsecrets create" \
    "namespace:workflows-default external-secrets.io externalsecrets delete" \
    "namespace:workflows-default generators.external-secrets.io githubaccesstokens create" \
    "namespace:workflows-default  pods list" "namespace:workflows-default  pods/log get"; do
    read -r scope group res verb <<<"$(printf '%s' "$need" | sed 's/  / - /')"
    hit=$(printf '%s\n' "$out" | awk -v s="$scope" -v g="$group" -v r="$res" -v v="$verb" '
      $1 == "GRANT" && $2 == s {
        ng = split($3, gs, ","); nr = split($4, rs, ","); nv = split($5, vs, ",")
        for (i = 1; i <= ng; i++) for (j = 1; j <= nr; j++) for (k = 1; k <= nv; k++)
          if (gs[i] == g && rs[j] == r && vs[k] == v) { print "yes"; exit }
      }')
    assert_eq "$hit" yes "$inst: agent may $verb ${group/#-/core}/$res ($scope)"
  done
done

# Negative: the upstream ClusterRole (what this replaces) and synthetic regressions are reported.
helm template openchoreo-workflow-plane "$wp" --namespace "$agent_ns" --set clusterAgentRBAC.enabled=false \
  --set openchoreo-workflow-plane.clusterAgent.rbac.create=true > "$TMP/upstream.yaml"
out=$(check "$TMP/upstream.yaml")
for v in 'cluster-wide write verbs on secrets' 'wildcard in' 'secret store / push access \(clustersecretstores\)' \
  'cluster-wide rbac.authorization.k8s.io/roles'; do
  assert_match "$out" "VIOLATION: ClusterRoleBinding cluster-agent-workflowplane -> ClusterRole cluster-agent-workflowplane: $v" \
    "upstream agent RBAC is reported: $v"
done
cat > "$TMP/synthetic.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: sneaky }
rules:
  - { apiGroups: [""], resources: [secrets], verbs: [get, create] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: sneaky }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: sneaky }
subjects: [{ kind: ServiceAccount, name: $agent_sa, namespace: $agent_ns }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: admin }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [{ kind: ServiceAccount, name: $agent_sa, namespace: $agent_ns }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: r, namespace: kube-system }
rules:
  - { apiGroups: [rbac.authorization.k8s.io], resources: [roles], verbs: [bind] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: r, namespace: kube-system }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: r }
subjects: [{ kind: ServiceAccount, name: $agent_sa, namespace: $agent_ns }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: s, namespace: workflows-default }
rules:
  - { apiGroups: [""], resources: [secrets], verbs: [get] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: s, namespace: workflows-default }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: s }
subjects: [{ kind: ServiceAccount, name: $agent_sa, namespace: $agent_ns }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: someone-else }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [{ kind: ServiceAccount, name: other, namespace: $agent_ns }]
EOF
out=$(check "$TMP/synthetic.yaml")
assert_match "$out" 'VIOLATION: ClusterRoleBinding sneaky -> ClusterRole sneaky: cluster-wide write verbs on secrets \["create"\]' \
  "a cluster-wide secrets create grant is reported"
assert_match "$out" 'VIOLATION: ClusterRoleBinding admin -> ClusterRole cluster-admin: role not rendered here' "a cluster-admin binding is reported"
assert_match "$out" 'VIOLATION: RoleBinding kube-system/r -> Role r: namespaced grant outside the run namespaces' \
  "a grant outside workflows-* is reported"
assert_match "$out" 'VIOLATION: RoleBinding kube-system/r -> Role r: RBAC escalation verbs \["bind"\]' "bind is reported"
assert_match "$out" 'VIOLATION: RoleBinding workflows-default/s -> Role s: secrets in workflows-default' \
  "secrets access in the run namespace is reported"
assert_eq "$(printf '%s\n' "$out" | grep -c 'someone-else' || true)" 0 "other subjects are not the agent's"

# Namespace creation by the agent: only workflows-* (native ValidatingAdmissionPolicy, evaluated by the kyverno CLI).
KYVERNO=${KYVERNO:-kyverno}
if command -v "$KYVERNO" >/dev/null 2>&1; then
  helm template openchoreo-workflow-plane "$wp" --namespace "$agent_ns" -s templates/cluster-agent-rbac.yaml \
    | yq 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding")' > "$TMP/ns-vap.yaml"
  cat > "$TMP/ns-ok.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: workflows-acme }
EOF
  cat > "$TMP/ns-bad.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: kube-sneaky }
---
apiVersion: v1
kind: Namespace
metadata: { name: workflowsx }
EOF
  for who in agent:"system:serviceaccount:$agent_ns:$agent_sa" other:"system:serviceaccount:argocd:argocd-application-controller"; do
    printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: UserInfo\nmetadata: { name: u }\nuserInfo: { username: "%s" }\n' "${who#*:}" \
      > "$TMP/user-${who%%:*}.yaml"
  done
  for c in agent:ok agent:bad other:bad; do
    "$KYVERNO" apply "$TMP/ns-vap.yaml" --resource "$TMP/ns-${c#*:}.yaml" --userinfo "$TMP/user-${c%%:*}.yaml" \
      > "$TMP/ns-${c%%:*}-${c#*:}.out" 2>&1 || true
  done
  assert_match "$(cat "$TMP/ns-agent-ok.out")" 'pass: 1, fail: 0, warn: 0, error: 0' "agent may create namespace workflows-acme"
  assert_match "$(cat "$TMP/ns-agent-bad.out")" 'pass: 0, fail: 2, warn: 0, error: 0' "agent may not create kube-sneaky or workflowsx"
  assert_match "$(cat "$TMP/ns-agent-bad.out")" 'may only create run namespaces workflows-\*, not kube-sneaky' "denial names the allowed prefix"
  assert_match "$(cat "$TMP/ns-other-bad.out")" 'pass: 0, fail: 0, warn: 0, error: 0' "other identities are not matched"
else
  echo "  SKIP kyverno CLI not found: namespace admission policy (set KYVERNO=/path/to/kyverno)"
fi

finish
