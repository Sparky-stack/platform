# OpenChoreo AI Agents and Agentgateway (Disabled by Default)

OpenChoreo 1.3.3 ships two AI agents inside the observability plane (`addons/openchoreo-observability-plane`), plus an optional AI gateway module (`ai-gateway-agentgateway`). All three are **disabled/commented by default** here because they require LLM provider API tokens and extra cluster resources.

## Components

| Component | Chart / Source | What it does |
|---|---|---|
| **RCA (SRE) Agent** | `openchoreo-observability-plane` (`rca.*`, image `ghcr.io/openchoreo/sre-agent`) | Investigates incidents by querying `observer` (`/mcp` / API) and `openchoreo-api`, generating RCA reports when `rca.enabled: true` (`AI_RCA_ENABLED`). |
| **FinOps Agent** | `openchoreo-observability-plane` (`finOpsAgent.*`, image `ghcr.io/openchoreo/finops-agent`) | Analyzes workload resource usage vs cost using `observer` MCP (`/mcp`) and OpenCost MCP (`:8081`), storing reports in SQLite (`finops-agent` PVC). |
| **FinOps OpenCost Module** | `oci://cr.openchoreo.dev/openchoreo/helm-charts/observability-finops-opencost` (`0.2.0`) | Subchart of `openchoreo-observability-plane`: deploys OpenCost (`:9003` API, `:8081` MCP) + `finops-adapter` (`:9101`), reading from `prometheus-operated:9090`. |
| **Agentgateway AI Gateway** | `oci://cr.agentgateway.dev/charts/agentgateway-crds` + `agentgateway` (`v1.1.0`) | Kubernetes Gateway API AI proxy (`GatewayClass/agentgateway`, `AgentgatewayBackend`, `HTTPRoute`) providing unified `/openai`, `/anthropic`, `/gemini` routing, credential injection, and metering. |

## Topology Note (mgmt vs workload)

In this platform, `openchoreo-observability-plane` runs on **mgmt** (`docs/observability.md`), so `sre-agent` and `finops-agent` run in namespace `openchoreo-observability-plane` on mgmt. Running `ai-gateway-agentgateway` on **mgmt** (either inside `openchoreo-observability-plane` via `aiGateway.enabled: true` or as a dedicated `addons/agentgateway` addon on role `mgmt`) lets both agents dial the gateway in-cluster:

```text
http://agentgateway-proxy.openchoreo-observability-plane.svc.cluster.local/openai/v1
```

(Upstream's single-cluster guide deploys `agentgateway-proxy` in `openchoreo-data-plane`; in our multi-cluster layout workload clusters are separate CAPI clusters, so mgmt agents would not reach workload `.svc.cluster.local` addresses directly.)

## Prerequisites to Enable

1. **Secrets in `ClusterSecretStore/platform`** (never commit values):
   - Key `openchoreo-ai`:
     - `rca-llm-api-key` — maps to `RCA_LLM_API_KEY` in Secret `rca-agent-secret` (or a placeholder when `agentgateway` injects the real upstream key)
     - `rca-oauth-client-secret` — maps to `OAUTH_CLIENT_SECRET` in `rca-agent-secret`; must match Thunder client `openchoreo-rca-agent`
     - `finops-llm-api-key` — maps to `LLM_API_KEY` in Secret `finops-agent` (or placeholder when routed via `agentgateway`)
     - `finops-oauth-client-secret` — maps to `OAUTH_CLIENT_SECRET` in `finops-agent`; must match Thunder client `openchoreo-finops-agent`
     - `openai-authorization` (or `anthropic-authorization` / `gemini-authorization`) — `"Bearer <provider-api-key>"` when using `agentgateway`
   - Key `openchoreo` (read by `addons/thunder/templates/bootstrap-secret.yaml`):
     - Add properties `rca-agent-client-secret` and `finops-agent-client-secret` (matching `rca-oauth-client-secret` and `finops-oauth-client-secret`), and map them in `addons/thunder/templates/bootstrap-secret.yaml`.
2. **Thunder OAuth2 clients (`addons/thunder/values.yaml`):**
   - Uncomment `RCA_AGENT_CLIENT_SECRET` / `FINOPS_AGENT_CLIENT_SECRET` under `thunderid.setup.secretEnv`.
   - Uncomment `53-openchoreo-rca-agent-app.yaml` (`openchoreo-rca-agent`) and `60-openchoreo-finops-agent-app.yaml` (`openchoreo-finops-agent`) under `thunderid.bootstrap.scripts`.
3. **Control Plane Authz Roles & RoleMappings (`addons/openchoreo-control-plane/values.yaml`):**
   - Add the upstream `rca-agent` and `finops-agent` roles under `openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.roles` and `rca-agent-mapping` (`client_id: openchoreo-rca-agent`) / `finops-agent-mapping` (`client_id: openchoreo-finops-agent`) under `bootstrap.roleMappings`. (Note: our wrapper chart overrides `bootstrap.roles` and `bootstrap.roleMappings`, so they must be listed explicitly there.)

## Exact Switches to Flip

### Option A: Enable Agentgateway (`ai-gateway-agentgateway`) on mgmt
1. Add `"oci://cr.agentgateway.dev/*"` to `AppProject/platform` (`charts/platform/templates/projects.yaml`).
2. Either:
   - **Inline in `openchoreo-observability-plane`:** uncomment `agentgateway-crds` and `agentgateway` (`v1.1.0`) in `addons/openchoreo-observability-plane/Chart.yaml` (run `helm dependency build`), and copy `addons/openchoreo-observability-plane/values/ai-gateway-agentgateway.yaml.disabled` (which sets `aiGateway.enabled: true` and activates `templates/ai-gateway-agentgateway.yaml`) into `addons/openchoreo-observability-plane/values.yaml` or `installations/<inst>/addons/openchoreo-observability-plane/values.yaml`.
   - **Or promote to a standalone addon:** create `addons/agentgateway/` (`roles: [mgmt]`) and add it to `charts/platform/values.yaml`.

### Option B: Enable RCA (SRE) Agent
1. Complete Prerequisites 1-3 above (`openchoreo-ai`, Thunder script 53, `rca-agent` + `rca-agent-mapping`).
2. In `addons/openchoreo-observability-plane/values.yaml` (or `installations/<inst>/addons/openchoreo-observability-plane/values.yaml`):
   - Set `openchoreo-observability-plane.rca.enabled: true`.
   - Uncomment `name` (`sre-agent`), `observerApiUrl`, `openchoreoApiUrl`, `secretName` (`rca-agent-secret`), `externalSecrets.enabled: true`, `llm.modelName`, `llm.baseUrl` (pointing at `agentgateway-proxy` or your LLM endpoint), `llm.auth`, and `oauth.clientId`.
   - `templates/secrets.yaml` will automatically create `ExternalSecret/rca-agent-secret`.

### Option C: Enable FinOps Agent + OpenCost
1. Complete Prerequisites 1-3 above (`openchoreo-ai`, Thunder script 60, `finops-agent` + `finops-agent-mapping`).
2. In `addons/openchoreo-observability-plane/Chart.yaml`, uncomment `observability-finops-opencost` (`0.2.0`) and run `helm dependency build`.
3. In `addons/openchoreo-observability-plane/values.yaml` (or installation overlay):
   - Uncomment `observability-finops-opencost:` (`enabled: true`, `opencost.*`, `adapter.*`, `mcpServer.*`).
   - Uncomment `openchoreo-observability-plane.observer.finOpsAdapter` (`url: "http://openchoreo-observability-plane-observability-finops-opencost-adapter:9101"`).
   - Set `openchoreo-observability-plane.finOpsAgent.enabled: true` and uncomment `observabilityMcpServerUrl`, `opencostMcpServerUrl` (`http://openchoreo-observability-plane-observability-finops-opencost-mcp.openchoreo-observability-plane.svc.cluster.local:8081`), `openchoreoApiUrl`, `secretName` (`finops-agent`), `llmName`, `llmBaseUrl`, `llmAuth`, and `oauth.clientId`.
   - `templates/secrets.yaml` will automatically create `ExternalSecret/finops-agent`.

## Untested / VERIFY
- Live RCA report generation and FinOps cost analysis against OpenChoreo 1.3.3 `observer`, `openchoreo-api`, and `agentgateway` v1.1.0.
- OpenCost metrics ingestion on mgmt from workload-cluster remote-write Prometheus (`prometheus-operated:9090`).
- `finops-agent` PVC binding under Argo CD's `Pending = Healthy` PVC rule.
