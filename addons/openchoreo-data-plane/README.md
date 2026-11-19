# openchoreo-data-plane

## Purpose

Wrapper chart for `openchoreo-data-plane` (`1.3.3`) on workload clusters. Runs the outbound `cluster-agent` (which dials `mgmt`'s `cluster-gateway` over mTLS WebSocket) and the data-plane ingress `Gateway` serving tenant components.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: openchoreo-data-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-data-plane` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| byoDelivery.enabled | bool | `false` | On byo clusters (`values/provider-byo.yaml`), agent TLS and CA arrive by `PushSecret`; `templates/byo-gateway-ca.yaml` rebuilds the `cluster-gateway-ca` ConfigMap ([byo](../../docs/providers.md#bring-your-own-cluster-byo)). |
| byoDelivery.store | string | `"delivery"` |  |
| cluster.name | string | `"default"` |  |
| clusterAgentDataServices.enabled | bool | `true` | Extra agent RBAC (`clusterAgentDataServices.{enabled,serviceAccount,rules}`) for the kinds the platform's data-service types render (KEDA `ScaledObject`, PostgreSQL XR; [data services](../../docs/data-services.md#consuming-them-from-openchoreo)). |
| clusterAgentDataServices.rules[0].apiGroup | string | `"keda.sh"` |  |
| clusterAgentDataServices.rules[0].resources[0] | string | `"scaledobjects"` |  |
| clusterAgentDataServices.rules[1].apiGroup | string | `"platform.koorikla.io"` |  |
| clusterAgentDataServices.rules[1].resources[0] | string | `"postgresqls"` |  |
| clusterAgentDataServices.serviceAccount | string | `"cluster-agent-dataplane"` |  |
| openchoreo-data-plane.clusterAgent.image.tag | string | `"v1.3.3@sha256:de4907fcf4ffa6822dcbcaff876b02861bae0804c3aa86db6df64f918ef8451c"` |  |
| openchoreo-data-plane.clusterAgent.planeID | string | `"default"` |  |
| openchoreo-data-plane.clusterAgent.podAnnotations."configmap.reloader.stakater.com/reload" | string | `"cluster-gateway-ca"` |  |
| openchoreo-data-plane.clusterAgent.podAnnotations."secret.reloader.stakater.com/reload" | string | `"cluster-agent-tls"` |  |
| openchoreo-data-plane.clusterAgent.resources.limits.cpu | string | `"100m"` |  |
| openchoreo-data-plane.clusterAgent.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-data-plane.clusterAgent.resources.requests.cpu | string | `"10m"` |  |
| openchoreo-data-plane.clusterAgent.resources.requests.memory | string | `"64Mi"` |  |
| openchoreo-data-plane.clusterAgent.serverUrl | string | `"wss://cluster-gateway.openchoreo.localhost:8443/ws"` | Set from `openchoreo.controlPlane.clusterGatewayURL` (`installationParameters`) alongside per-cluster `planeID` (`clusterNameParameters`). |
| openchoreo-data-plane.clusterAgent.tls.caSecretName | string | `""` |  |
| openchoreo-data-plane.clusterAgent.tls.clientSecretName | string | `"cluster-agent-tls"` | Mounts `cluster-agent-tls` and `serverCAConfigMap: cluster-gateway-ca` delivered by CAPI `ClusterResourceSet` (with Reloader annotations). |
| openchoreo-data-plane.clusterAgent.tls.enabled | bool | `true` |  |
| openchoreo-data-plane.clusterAgent.tls.generateCerts | bool | `true` |  |
| openchoreo-data-plane.clusterAgent.tls.secretName | string | `"cluster-agent-selfsigned-unused"` |  |
| openchoreo-data-plane.clusterAgent.tls.serverCAConfigMap | string | `"cluster-gateway-ca"` |  |
| openchoreo-data-plane.gateway.httpPort | int | `19080` | Workload data-plane Gateway ports (`19080` / `19443`). |
| openchoreo-data-plane.gateway.httpsPort | int | `19443` |  |
| openchoreo-data-plane.gateway.infrastructure.labels."istio.io/dataplane-mode" | string | `"ambient"` |  |
| openchoreo-data-plane.gateway.tls.enabled | bool | `false` |  |
| openchoreo-data-plane.security.enabled | bool | `false` |  |
| openchoreo.controlPlane.clusterGatewayURL | string | `"wss://cluster-gateway.openchoreo.localhost:8443/ws"` |  |
| priorityClasses.app-production.description | string | `"OpenChoreo components in the production environment (ClusterTrait resilience)."` |  |
| priorityClasses.app-production.preemptionPolicy | string | `"PreemptLowerPriority"` |  |
| priorityClasses.app-production.value | int | `100000` |  |
| priorityClasses.app-standard.description | string | `"OpenChoreo components outside production (ClusterTrait resilience)."` |  |
| priorityClasses.app-standard.preemptionPolicy | string | `"Never"` |  |
| priorityClasses.app-standard.value | int | `1000` |  |

## Day-2 notes

- Disconnected agents and client cert rotation: [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#3-openchoreo-agent-certificates).

## Links

- [OpenChoreo](../../docs/openchoreo.md)