# OpenChoreo AI agents (switched off)

OpenChoreo 1.3.3 ships two AI agents in its observability plane chart. Both are configured here and **switched off**
until LLM credentials exist; so are the two addons they lean on. Nothing below runs, renders a workload, or reads a
secret until you flip the switches in [Turning them on](#turning-them-on).

| Component | Where | What it does | Default |
|---|---|---|---|
| RCA (SRE) agent | addon `openchoreo-observability-plane`, `rca.*` (image `ghcr.io/openchoreo/sre-agent`) | Root-cause analysis of alerts/incidents: reads logs, metrics, traces and events through the observer and component/release state through openchoreo-api, writes RCA reports (SQLite PVC) shown in the portal. | `rca.enabled: false` |
| FinOps agent | addon `openchoreo-observability-plane`, `finOpsAgent.*` (image `ghcr.io/openchoreo/finops-agent`) | Cost analysis and rightsizing recommendations from OpenCost data (MCP) and observed usage; enriches budget alerts. OpenAI models only in 1.3.3. | `finOpsAgent.enabled: false` |
| FinOps module | addon `finops-opencost` (OpenChoreo community module `finops-opencost` 0.2.1 = the 0.2.x line for OpenChoreo 1.3.x) | OpenCost over the plane's Prometheus (`opencost`: 9003 API, 8081 MCP) + Cost Insights adapter (`finops-adapter`: 9101). Needed by the FinOps agent and the portal's Cost Insights. | catalog `default: false` |
| agentgateway | addon `agentgateway` (agentgateway v1.1.0, the version OpenChoreo's `ai-gateway-agentgateway` module installs) | OpenAI-compatible LLM gateway: Gateway `agentgateway-proxy` → one `AgentgatewayBackend` that injects the provider key. Agents call it instead of holding provider keys. | catalog `default: false` |

All four run on **mgmt** (the observability plane is co-located with the control plane, docs/observability.md). The
upstream module puts `agentgateway-proxy` in `openchoreo-data-plane` for component traits; here it serves the
platform's own agents, so it lives on mgmt in `agentgateway-system` and accepts routes from its own namespace only.
Component-facing LLM routing (the module's ClusterTraits on data planes) is not part of this change.

Images are pinned by digest and multi-arch (amd64 + arm64): `sre-agent` / `finops-agent` v1.3.3, agentgateway
`controller` / `agentgateway` v1.1.0, `finops-opencost-adapter` 0.2.1, `opencost` 1.121.1 (pinned by the opencost chart).

## How the pieces connect

```
sre-agent, finops-agent (openchoreo-observability-plane)
  ├─ LLM ──────────> http://agentgateway-proxy.agentgateway-system.svc.cluster.local ──> provider (key from ESO)
  ├─ OAuth2 client_credentials ──> Thunder clients openchoreo-rca-agent / openchoreo-finops-agent (scripts 53 / 60)
  ├─ openchoreo-api (authz roles rca-agent / finops-agent, bound to those client_ids upstream)
  ├─ observer (+ /mcp)
  └─ finops-agent ──> opencost:8081 (MCP); observer ──> finops-adapter:9101   (addon finops-opencost)
portal ──> ClusterObservabilityPlane rcaAgentURL / finOpsAgentURL ──> http://{rca,finops}-agent.<host>:<obs http port>
```

The control plane's `rca-agent` / `finops-agent` authz roles and their `client_id` bindings ship enabled in the upstream
`openchoreo-control-plane` defaults (the wrapper does not override `bootstrap.roles`), so nothing changes there.

## Secrets

One key in the `platform` store, `openchoreo-ai` (never committed). Each property is read only by what is switched on:

| Property | Read by | Notes |
|---|---|---|
| `rca-llm-api-key` | Secret `rca-agent-secret` → `RCA_LLM_API_KEY` | any placeholder when `rca.llm.baseUrl` is the agentgateway |
| `rca-oauth-client-secret` | `rca-agent-secret` → `OAUTH_CLIENT_SECRET`, and Thunder (`bootstrapSecret.aiAgentClients: [rca]`) | one property, both sides: they cannot drift |
| `finops-llm-api-key` | Secret `finops-agent` → `LLM_API_KEY` | placeholder when `finOpsAgent.llmBaseUrl` is the agentgateway |
| `finops-oauth-client-secret` | `finops-agent` → `OAUTH_CLIENT_SECRET`, and Thunder (`aiAgentClients: [finops]`) | |
| `openai-api-key` (or `anthropic-api-key`, `gemini-api-key`) | addon agentgateway, Secret `<provider>-llm-auth` (`Authorization: Bearer …` via ESO template) | the only real provider key |

Namespaces `openchoreo-observability-plane`, `thunder` and `agentgateway-system` are in secret-stores
`platformStore.namespaces` (hack/tests/test_secret_store_scope.sh renders these opt-in consumers).

## Turning them on

Host RAM: the RCA agent requests 512Mi (upstream 1Gi, limit 1.5Gi); budget for it on a laptop.

### 1. Gateway (recommended first)

1. Seed `openchoreo-ai` property `openai-api-key`.
2. `installation.yaml`: `mgmt.addons.agentgateway: "true"`.
   Provider/model: `llm.provider` (`openai` | `anthropic` | `gemini`) and `llm.model` in
   `installations/<inst>/addons/agentgateway/values.yaml`.

Without the gateway, set `rca.llm.baseUrl: ""` / `finOpsAgent.llmBaseUrl: ""` and put the real provider key in
`rca-llm-api-key` / `finops-llm-api-key`.

### 2. RCA (SRE) agent

1. Seed `openchoreo-ai` properties `rca-llm-api-key` (placeholder with the gateway) and `rca-oauth-client-secret`.
2. `addons/thunder/values.yaml`: `bootstrapSecret.aiAgentClients: [rca]`, uncomment the
   `RCA_AGENT_CLIENT_SECRET` line in `thunderid.setup.secretEnv` and script `53-rca-agent-client.yaml`.
3. `addons/openchoreo-observability-plane/values.yaml` (or the installation overlay):
   `openchoreo-observability-plane.rca.enabled: true` and `rca.llm.modelName` (e.g. `gpt-5.2`).

### 3. FinOps agent

1. `installation.yaml`: `mgmt.addons.finops-opencost: "true"`.
2. Seed `openchoreo-ai` properties `finops-llm-api-key` and `finops-oauth-client-secret`.
3. Thunder: `aiAgentClients: [rca, finops]` (or `[finops]`), uncomment `FINOPS_AGENT_CLIENT_SECRET` and script
   `60-finops-agent-client.yaml`.
4. `openchoreo-observability-plane.finOpsAgent.enabled: true` and `finOpsAgent.llmName` (an OpenAI model).

With an agent enabled, `templates/secrets.yaml` creates its ExternalSecret and `templates/cluster-observability-plane.yaml`
publishes `rcaAgentURL` / `finOpsAgentURL` (`http://rca-agent.<host>:<port>`, `http://finops-agent.<host>:<port>`,
the plane Gateway's HTTPRoutes). `templates/validate.yaml` refuses an enabled agent without a model or with a hostname
outside the installation's control-plane host.

## Tests

- `hack/tests/test_ai_agents.sh`: everything off by default; one store key across agents, Thunder and agentgateway;
  Thunder scripts 53/60 match upstream ids and the agents' client IDs; switched on, the agents' base URLs hit the
  agentgateway Gateway, the observer/FinOps URLs hit `finops-opencost` Services, all images are digest-pinned.
- helm-unittest: `addons/agentgateway`, `addons/openchoreo-observability-plane` (agent Secrets, plane URLs, guards),
  `addons/thunder` (agent client secrets).

## VERIFY

- Live RCA / FinOps runs against OpenChoreo 1.3.3 (no LLM key has been used yet).
- agentgateway controller accepting `tag@digest` for the proxy image (`AGW_PROXY_IMAGE_TAG`).
- OpenCost attribution of remote-written workload metrics on mgmt (`defaultClusterId: mgmt`).
- Agent SQLite PVCs under Argo CD health (Pending until first consumer on local-path).
