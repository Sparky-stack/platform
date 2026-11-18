# openchoreo-data-plane

## Purpose

Wrapper chart for `openchoreo-data-plane` (`1.3.3`) on workload clusters. Runs the outbound `cluster-agent` (which dials `mgmt`'s `cluster-gateway` over mTLS WebSocket) and the data-plane ingress `Gateway` serving tenant components.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: openchoreo-data-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-data-plane` (`default: true`, opt-out with `"false"`).

## Key values

- `openchoreo-data-plane.clusterAgent.{planeID,serverUrl}`: set per cluster (`clusterNameParameters`) and from `openchoreo.controlPlane.clusterGatewayURL` (`installationParameters`).
- `openchoreo-data-plane.clusterAgent.tls.{clientSecretName,serverCAConfigMap}`: mounts `cluster-agent-tls` and `cluster-gateway-ca` delivered by CAPI `ClusterResourceSet` (with Reloader annotations).
- `byoDelivery.enabled` (`values/provider-byo.yaml`): on byo clusters both arrive by `PushSecret`; `templates/byo-gateway-ca.yaml` rebuilds the `cluster-gateway-ca` ConfigMap from the pushed Secret ([byo](../../docs/providers.md#bring-your-own-cluster-byo)).
- `openchoreo-data-plane.gateway.{httpPort,httpsPort}`: workload data-plane Gateway ports (`19080` / `19443`).
- `clusterAgentDataServices.{enabled,serviceAccount,rules}`: extra agent RBAC for the kinds the platform's data-service types render (KEDA `ScaledObject`, PostgreSQL XR; [data services](../../docs/data-services.md#consuming-them-from-openchoreo)).

## Day-2 notes

- Disconnected agents and client cert rotation: [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#3-openchoreo-agent-certificates).

## Links

- [OpenChoreo](../../docs/openchoreo.md)
