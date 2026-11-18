# agentgateway

## Purpose

Wrapper chart for `agentgateway-crds` and `agentgateway` (`v1.1.0`) on `mgmt`. Provides an in-cluster LLM proxy (`Gateway` + `AgentgatewayBackend`) so OpenChoreo's opt-in RCA and FinOps agents call OpenAI, Anthropic, or Gemini without holding provider API keys.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: agentgateway-system`).
- **Catalog label:** `addons.platform.koorikla.io/agentgateway` (`default: false`, opt-in via `installation.yaml` `mgmt.addons.agentgateway: "true"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agentgateway-crds | object | `{}` |  |
| agentgateway.controller.image.tag | string | `"v1.1.0@sha256:0c4179780a3353a20f403ed51c764127f2806b6aa1a5ecb6da7655b5b27d7926"` | `v1.1.0` pinned by multi-arch index digest. |
| agentgateway.podSecurityContext.runAsNonRoot | bool | `true` |  |
| agentgateway.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| agentgateway.proxy.image.tag | string | `"v1.1.0@sha256:b5fd647604aa37eb2da372206a6681dfd613461e2445d89ba0b80e8439a4ff29"` |  |
| agentgateway.resources.limits.cpu | string | `"200m"` |  |
| agentgateway.resources.limits.memory | string | `"256Mi"` |  |
| agentgateway.resources.requests.cpu | string | `"10m"` |  |
| agentgateway.resources.requests.memory | string | `"64Mi"` |  |
| gateway.allowedNamespaces[0] | string | `"openchoreo-observability-plane"` |  |
| gateway.name | string | `"agentgateway-proxy"` | `agentgateway-proxy` listener (`gateway.{name,port,allowedNamespaces}`) restricted to routes from `openchoreo-observability-plane`. |
| gateway.port | int | `80` |  |
| llm.enabled | bool | `true` | Enables the LLM backend and route (`llm.{enabled,provider,model}`). |
| llm.model | string | `""` |  |
| llm.provider | string | `"openai"` | Selects upstream AI provider (`openai`, `anthropic`, `gemini`). |
| secrets.remoteKey | string | `"openchoreo-ai"` |  |
| secrets.store | string | `"platform"` | Pulls LLM provider credentials (`secrets.{store,remoteKey}`) from `ClusterSecretStore/platform`. |

## Day-2 notes

- Rotating LLM API keys in ESO: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

## Links

- [OpenChoreo AI agents](../../docs/ai-agents.md)