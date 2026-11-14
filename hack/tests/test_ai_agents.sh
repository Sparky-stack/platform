#!/usr/bin/env bash
# OpenChoreo AI agents (docs/ai-agents.md): switched off by default, and when switched on every side agrees -
# observability-plane agents, Thunder OAuth clients, the platform store key, agentgateway and the FinOps module.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

echo "== test_ai_agents =="
CAT=charts/platform/values.yaml
OBS=addons/openchoreo-observability-plane
o() { yq ".[\"openchoreo-observability-plane\"]$1" "$OBS/values.yaml"; }

# 1. Off by default: agents disabled, opt-in addons default false, Thunder clients not provisioned.
assert_eq "$(o .rca.enabled)" false "rca agent off by default"
assert_eq "$(o .finOpsAgent.enabled)" false "finops agent off by default"
assert_eq "$(yq '.addons.agentgateway.default' "$CAT")" false "addon agentgateway is opt-in"
assert_eq "$(yq '.addons["finops-opencost"].default' "$CAT")" false "addon finops-opencost is opt-in"
assert_eq "$(yq '.addons["finops-opencost"].namespace' "$CAT")" "$(yq '.addons["openchoreo-observability-plane"].namespace' "$CAT")" "finops-opencost runs next to the observability plane"
assert_eq "$(yq '.bootstrapSecret.aiAgentClients | length' addons/thunder/values.yaml)" 0 "Thunder agent clients off by default"
assert_eq "$(grep -cE '^      [0-9]+-(rca|finops)-agent-client\.yaml:' addons/thunder/values.yaml || true)" 0 "Thunder scripts 53/60 stay commented"
helm template obs "$OBS" --namespace openchoreo-observability-plane > "$TMP/obs.yaml"
assert_eq "$(yq -N 'select(.kind == "Deployment" and (.metadata.name == "sre-agent" or .metadata.name == "finops-agent")) | .metadata.name' "$TMP/obs.yaml")" "" "no agent Deployments rendered"

# 2. One store key for everything AI: the agents' Secrets, Thunder's client secrets, agentgateway's provider key.
key=$(yq '.secrets.aiRemoteKey' "$OBS/values.yaml")
assert_eq "$key" openchoreo-ai "agents read key openchoreo-ai"
assert_eq "$(yq '.bootstrapSecret.aiRemoteKey' addons/thunder/values.yaml)" "$key" "Thunder reads the same key"
assert_eq "$(yq '.secrets.remoteKey' addons/agentgateway/values.yaml)" "$key" "agentgateway reads the same key"

# 3. Thunder's commented clients 53/60 are the upstream ones and match the agents' OAuth client IDs.
for pair in "53-rca-agent-client:rca:RCA_AGENT_CLIENT_SECRET:000000000062" "60-finops-agent-client:finOpsAgent:FINOPS_AGENT_CLIENT_SECRET:000000000069"; do
  IFS=: read -r script agent env id <<EOF
$pair
EOF
  block=$(sed -n "/# ${script}.yaml: |/,/validityPeriod/p" addons/thunder/values.yaml)
  assert_nonempty "$block" "Thunder script $script present (commented)"
  assert_match "$block" "clientId: $(o ".$agent.oauth.clientId")" "$script clientId == $agent.oauth.clientId"
  assert_match "$block" "clientSecret: \"\\{\\{ \\.$env \\}\\}\"" "$script secret from the store ($env), not upstream's well-known value"
  assert_match "$block" "id: 01900000-0000-7000-8001-$id" "$script keeps upstream id $id"
  assert_match "$(cat addons/thunder/values.yaml)" "# - \\{ name: $env, secretName: thunder-bootstrap" "$env secretEnv entry present (commented)"
done

# 4. Switched on: agents reach agentgateway's Gateway, the FinOps module's Services, and get their Secrets.
helm template obs "$OBS" --namespace openchoreo-observability-plane \
  --set openchoreo-observability-plane.rca.enabled=true --set openchoreo-observability-plane.rca.llm.modelName=gpt-5.2 \
  --set openchoreo-observability-plane.finOpsAgent.enabled=true --set openchoreo-observability-plane.finOpsAgent.llmName=gpt-5.2 \
  > "$TMP/obs-on.yaml"
helm template agentgateway addons/agentgateway --namespace "$(yq '.addons.agentgateway.namespace' "$CAT")" > "$TMP/agw.yaml"
helm template finops-opencost addons/finops-opencost --namespace "$(yq '.addons["finops-opencost"].namespace' "$CAT")" > "$TMP/fo.yaml"
gw=$(yq -N 'select(.kind == "Gateway") | .metadata.name + "." + .metadata.namespace + ".svc.cluster.local:" + (.spec.listeners[0].port | tostring)' "$TMP/agw.yaml")
for v in RCA_LLM_BASE_URL FINOPS_AGENT_LLM_BASE_URL; do
  url=$(yq -N "select(.kind == \"ConfigMap\") | .data.$v | select(. != null)" "$TMP/obs-on.yaml")
  host=${url#http://}; host=${host%%/*}; [[ "$host" == *:* ]] || host="$host:80"
  assert_eq "$host" "$gw" "$v points at agentgateway's Gateway"
done
svc() { yq -N "select(.kind == \"Service\" and .metadata.name == \"$1\") | .spec.ports[].port" "$TMP/fo.yaml" | grep -qx "$2" && echo yes || echo no; }
adapter=$(yq -N 'select(.kind == "ConfigMap") | .data.FINOPS_ADAPTER_URL | select(. != null)' "$TMP/obs-on.yaml")
a=${adapter#http://}
assert_eq "$(svc "${a%%:*}" "${a##*:}")" yes "observer FINOPS_ADAPTER_URL ($adapter) is a finops-opencost Service"
mcp=$(o .finOpsAgent.opencostMcpServerUrl)
[[ "$mcp" == null ]] && mcp=$(helm show values "$OBS/charts/openchoreo-observability-plane-"*.tgz | yq '.finOpsAgent.opencostMcpServerUrl')
m=${mcp#http://}; m=${m%%/*}
assert_eq "$(svc "${m%%.*}" "${m##*:}")" yes "finOpsAgent.opencostMcpServerUrl ($mcp) is a finops-opencost Service"
for s in "$(o .rca.secretName)" "$(o .finOpsAgent.secretName)"; do
  assert_eq "$(yq -N "select(.kind == \"ExternalSecret\" and .metadata.name == \"$s\") | .spec.secretStoreRef.name" "$TMP/obs-on.yaml")" platform "ExternalSecret $s from store platform"
done
for img in $(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' "$TMP/obs-on.yaml" "$TMP/agw.yaml" "$TMP/fo.yaml" | grep -E 'sre-agent|finops|agentgateway|opencost'); do
  assert_match "$img" '@sha256:[0-9a-f]{64}$' "$img pinned by digest"
done

finish
