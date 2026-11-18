# capi-operator

## Purpose

Wrapper chart for `cluster-api-operator` (`0.30.0`). Runs the Cluster API lifecycle operator on `mgmt`; provider custom resources are declared separately in `charts/cluster`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: capi-operator-system`).
- **Catalog label:** `addons.platform.koorikla.io/capi-operator` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster-api-operator.addon | object | `{}` |  |
| cluster-api-operator.bootstrap | object | `{}` |  |
| cluster-api-operator.controlPlane | object | `{}` |  |
| cluster-api-operator.core | object | `{}` | `{}` (kept empty alongside `bootstrap`, `controlPlane`, `infrastructure`, `addon`, `ipam` so `charts/cluster` (scope fleet) owns provider CRs). |
| cluster-api-operator.image.manager.repository | string | `"registry.k8s.io/capi-operator/cluster-api-operator"` |  |
| cluster-api-operator.image.manager.tag | string | `"v0.30.0@sha256:2dd577d7bd9cf65deb45b8cd6444f5c89c3de3237ed8e150bd3d34df24fbce10"` | `v0.30.0` pinned by multi-arch index digest. |
| cluster-api-operator.infrastructure | object | `{}` |  |
| cluster-api-operator.ipam | object | `{}` |  |
| cluster-api-operator.leaderElection.enabled | bool | `true` |  |
| cluster-api-operator.leaderElection.leaseDuration | string | `"60s"` |  |
| cluster-api-operator.leaderElection.renewDeadline | string | `"40s"` |  |
| cluster-api-operator.leaderElection.retryPeriod | string | `"10s"` |  |
| cluster-api-operator.watchConfigSecret | bool | `true` | `true` so provider controllers re-reconcile when ESO rotates `configSecret` credentials (such as CAPA's `capa-variables`). |

## Day-2 notes

- Upgrading the CAPI operator and providers: [upgrades](../../docs/runbooks/upgrades.md#2-capi-operator-and-providers).
- Triaging unreachable workload clusters: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable).

## Links

- [Cluster API providers](../../docs/providers.md)