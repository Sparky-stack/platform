# agentgateway

## Purpose

Wrapper chart for `agentgateway-crds` and `agentgateway` (`v1.1.0`) on `mgmt`. Provides an in-cluster LLM proxy (`Gateway` + `AgentgatewayBackend`) so OpenChoreo's opt-in RCA and FinOps agents call OpenAI, Anthropic, or Gemini without holding provider API keys.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: agentgateway-system`).
- **Catalog label:** `addons.platform.koorikla.io/agentgateway` (`default: false`, opt-in via `installation.yaml` `mgmt.addons.agentgateway: "true"`).

## Key values

- `gateway.{name,port,allowedNamespaces}`: `agentgateway-proxy` listener restricted to routes from `openchoreo-observability-plane`.
- `llm.{enabled,provider,model}`: selects upstream AI provider (`openai`, `anthropic`, `gemini`).
- `secrets.{store,remoteKey}`: pulls LLM provider credentials (`openchoreo-ai`) from `ClusterSecretStore/platform`.
- `agentgateway.{controller,proxy}.image.tag`: `v1.1.0` pinned by multi-arch index digest.

## Day-2 notes

- Rotating LLM API keys in ESO: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

## Links

- [OpenChoreo AI agents](../../docs/ai-agents.md)
