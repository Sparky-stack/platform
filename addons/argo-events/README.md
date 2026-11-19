# argo-events

## Purpose

Wrapper chart for `argo-events` (`2.4.28` / `v1.9.11`) on `mgmt`. Runs the platform's JetStream `EventBus`, `EventSource`s, and `Sensor`s receiving per-cluster Falco `critical` escalations and OpenChoreo `staging` rollout events to trigger `falco-response` and `promotion-gate` workflows.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: argo-events`).
- **Catalog label:** `addons.platform.koorikla.io/argo-events` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| argo-events.configs.jetstream.streamConfig.duplicates | string | `"300s"` |  |
| argo-events.configs.jetstream.streamConfig.maxAge | string | `"24h"` |  |
| argo-events.configs.jetstream.streamConfig.maxBytes | string | `"64MB"` |  |
| argo-events.configs.jetstream.streamConfig.maxMsgs | int | `10000` |  |
| argo-events.configs.jetstream.streamConfig.replicas | int | `1` |  |
| argo-events.configs.jetstream.versions[0].configReloaderImage | string | `"docker.io/natsio/nats-server-config-reloader:0.14.0@sha256:8c28b75bc416bb068761b19edf9a471bf8e35062bf619ea49c8e22af517e383e"` |  |
| argo-events.configs.jetstream.versions[0].metricsExporterImage | string | `"docker.io/natsio/prometheus-nats-exporter:0.14.0@sha256:839c59f6a23473a657f6560c2a14dca9b9ce722a017933a41d071a3c9dd3a7d7"` |  |
| argo-events.configs.jetstream.versions[0].natsImage | string | `"docker.io/library/nats:2.10.29@sha256:5498ba57b9471840be3d15b033a4eec554d1c02fa6c2cc0ca2d888637f6c6e2f"` |  |
| argo-events.configs.jetstream.versions[0].startCommand | string | `"/nats-server"` |  |
| argo-events.configs.jetstream.versions[0].version | string | `"2.10.29"` |  |
| argo-events.configs.nats.versions[0].metricsExporterImage | string | `"docker.io/natsio/prometheus-nats-exporter:0.14.0@sha256:839c59f6a23473a657f6560c2a14dca9b9ce722a017933a41d071a3c9dd3a7d7"` |  |
| argo-events.configs.nats.versions[0].natsStreamingImage | string | `"docker.io/library/nats-streaming:0.22.1@sha256:3dd7b21a7fceebc956629af8ad31b7e5dfb2cc717cba4be55e6b50f7ca726932"` |  |
| argo-events.configs.nats.versions[0].version | string | `"0.22.1"` |  |
| argo-events.controller.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| argo-events.controller.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| argo-events.controller.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| argo-events.controller.containerSecurityContext.runAsGroup | int | `65532` |  |
| argo-events.controller.containerSecurityContext.runAsNonRoot | bool | `true` |  |
| argo-events.controller.containerSecurityContext.runAsUser | int | `65532` |  |
| argo-events.controller.containerSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| argo-events.controller.rbac.managedNamespace | string | `"argo-events"` |  |
| argo-events.controller.rbac.namespaced | bool | `true` |  |
| argo-events.controller.resources.limits.memory | string | `"128Mi"` |  |
| argo-events.controller.resources.requests.cpu | string | `"10m"` |  |
| argo-events.controller.resources.requests.memory | string | `"48Mi"` |  |
| argo-events.crds.install | bool | `true` |  |
| argo-events.crds.keep | bool | `true` |  |
| argo-events.fullnameOverride | string | `"argo-events"` |  |
| argo-events.global.image.repository | string | `"quay.io/argoproj/argo-events"` |  |
| argo-events.global.image.tag | string | `"v1.9.11@sha256:fa07b2c9ece6ec60a3a8377866dfe21e8bad062d5b5407f1f181d3f1d24fb861"` |  |
| argo-events.webhook.enabled | bool | `false` |  |
| autoBuildWebhook.endpoint | string | `"/github"` |  |
| autoBuildWebhook.port | int | `12001` |  |
| autoBuildWebhook.rateLimit.requestsPerUnit | int | `30` |  |
| autoBuildWebhook.rateLimit.unit | string | `"Minute"` |  |
| autoBuildWebhook.route.gateway.name | string | `"gateway-default"` |  |
| autoBuildWebhook.route.gateway.namespace | string | `"openchoreo-control-plane"` |  |
| autoBuildWebhook.route.hostPrefix | string | `"events"` |  |
| autoBuildWebhook.route.sectionName | string | `"https"` |  |
| autoBuildWebhook.secret.key | string | `"github-webhook"` |  |
| autoBuildWebhook.secret.property | string | `"secret"` |  |
| autoBuildWebhook.secret.store | string | `"platform"` |  |
| autoBuildWebhook.workflowTemplate | string | `"auto-build"` | With installation `openchoreo.workflowPlane.autoBuild: webhook`: GitHub App push webhook (`autoBuildWebhook.{secret,route,rateLimit}`) starting `WorkflowTemplate/auto-build` of addon `openchoreo-platform`. |
| eventBus.maxFileStore | string | `"128MB"` |  |
| eventBus.maxMemoryStore | string | `"64MB"` |  |
| eventBus.natsVersion | string | `"2.10.29"` |  |
| eventBus.resources.metrics.limits.memory | string | `"32Mi"` |  |
| eventBus.resources.metrics.requests.cpu | string | `"5m"` |  |
| eventBus.resources.metrics.requests.memory | string | `"8Mi"` |  |
| eventBus.resources.nats.limits.memory | string | `"128Mi"` |  |
| eventBus.resources.nats.requests.cpu | string | `"10m"` |  |
| eventBus.resources.nats.requests.memory | string | `"48Mi"` |  |
| eventBus.resources.reloader.limits.memory | string | `"32Mi"` |  |
| eventBus.resources.reloader.requests.cpu | string | `"5m"` |  |
| eventBus.resources.reloader.requests.memory | string | `"8Mi"` |  |
| falco.clusters[0] | string | `"mgmt"` |  |
| falco.enabled | bool | `true` | Authenticates per-cluster `falcosidekick` webhooks (`falco.{enabled,clusters,tokenSecret,route,response}`; `fleetParameters` injects `falco.clusters` from Argo CD cluster secrets) and runs `falco-response`. |
| falco.endpoint | string | `"/falco"` |  |
| falco.minimumPriority | string | `"critical"` |  |
| falco.port | int | `12000` |  |
| falco.response.image | string | `"docker.io/library/python:3.14.10-alpine3.24@sha256:5862d971d1f0ae26b258cefa4e893556b1d3aba81bd2ff30888704ad378bab67"` |  |
| falco.response.notify.enabled | bool | `false` |  |
| falco.response.notify.secret.key | string | `"falco-notify"` |  |
| falco.response.notify.secret.store | string | `"platform"` |  |
| falco.response.rateLimit.requestsPerUnit | int | `6` |  |
| falco.response.rateLimit.unit | string | `"Minute"` |  |
| falco.response.rca.enabled | bool | `false` |  |
| falco.response.rca.url | string | `"http://sre-agent.openchoreo-observability-plane.svc.cluster.local:8080/api/v1alpha1/rca-agent/analyze"` |  |
| falco.response.resources.limits.memory | string | `"96Mi"` |  |
| falco.response.resources.requests.cpu | string | `"10m"` |  |
| falco.response.resources.requests.memory | string | `"32Mi"` |  |
| falco.response.ttlSecondsAfterFinished | int | `21600` |  |
| falco.route.enabled | bool | `true` |  |
| falco.route.gateway.name | string | `"gateway-default"` |  |
| falco.route.gateway.namespace | string | `"openchoreo-control-plane"` |  |
| falco.route.hostPrefix | string | `"events"` |  |
| falco.route.sectionName | string | `"http"` |  |
| falco.tokenSecret.key | string | `"falco-webhook"` |  |
| falco.tokenSecret.property | string | `"token"` |  |
| falco.tokenSecret.store | string | `"platform"` |  |
| installation.githubOrg | string | `"https://github.com/koorikla"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| openchoreo.workflowPlane.autoBuild | string | `"poll"` |  |
| openchoreo.workflowPlane.enabled | bool | `true` |  |
| podResources.limits.memory | string | `"96Mi"` |  |
| podResources.requests.cpu | string | `"10m"` |  |
| podResources.requests.memory | string | `"24Mi"` |  |
| promotionGate.enabled | bool | `true` | Triggers `ClusterWorkflow/promotion-gate` (`promotionGate.{enabled,sourceEnvironments,workflow}`) when `staging` bindings roll out. |
| promotionGate.sourceEnvironments[0] | string | `"staging"` |  |
| promotionGate.workflow | string | `"promotion-gate"` |  |
| workflowPlane | string | `"auto"` | `auto` (renders `Sensor`s and `WorkflowTemplate`s when Argo Workflows CRDs and `openchoreo.workflowPlane.enabled` are active). |

## Day-2 notes

- A rejected render names the bad value: `values.schema.json` checks types, formats and enums (Helm prints `at '/<path>'`); cross-field rules live in `templates/validate.yaml`.
- Triaging Falco critical escalations and blocked promotion triggers: [incidents](../../docs/runbooks/incidents.md#falco-critical-alert) and [promotion gate failing closed](../../docs/runbooks/incidents.md#promotion-gate-failing-closed).

## Links

- [Observability: Falco](../../docs/observability.md#falco)
- [Promotion gates](../../docs/promotion.md)
- [Build plane: auto-build](../../docs/build-plane.md#auto-build-poll-or-webhook)