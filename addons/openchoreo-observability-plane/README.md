# openchoreo-observability-plane

## Purpose

Wrapper chart for `openchoreo-observability-plane` (`1.3.3`) plus OpenSearch logs (`0.7.0`), OpenSearch traces (`0.8.0`), and Prometheus metrics (`0.8.0`) on `mgmt`. Runs `ClusterObservabilityPlane/default`, the `observer` API, Alertmanager, and ingress `Gateway`s receiving telemetry from workload clusters.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-observability-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-observability-plane` (`default: true`, opt-out with `"false"`).

## Key values

- `openchoreo.observability.{enabled,httpPort,tlsPort}`: HTTP (`11080`) and OpenSearch TLS passthrough (`11085`) Gateway ports.
- `clusterObservabilityPlane.{name,planeID}` and `agentServerCA`: registers `ClusterObservabilityPlane/default` and syncs `cluster-gateway-ca`.
- `secrets.{store,remoteKey,aiRemoteKey}`: pulls OpenSearch/observer (`openchoreo-observability`) and optional AI agent (`openchoreo-ai`) credentials from `ClusterSecretStore/platform`.
- `prometheusIngress`: `NetworkPolicy` allowing `promotion-gate` pods (`platform.koorikla.io/egress: openchoreo`) to query Prometheus.

## Day-2 notes

- Querying Prometheus/OpenSearch and checking observability readiness: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [Observability and runtime security](../../docs/observability.md)
