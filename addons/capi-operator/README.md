# capi-operator

## Purpose

Wrapper chart for `cluster-api-operator` (`0.30.0`). Runs the Cluster API lifecycle operator on `mgmt`; provider custom resources are declared separately in `addons/capi-providers`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: capi-operator-system`).
- **Catalog label:** `addons.platform.koorikla.io/capi-operator` (`default: true`, opt-out with `"false"`).

## Key values

- `cluster-api-operator.{core,bootstrap,controlPlane,infrastructure,addon,ipam}`: `{}` (kept empty so `addons/capi-providers` owns provider CRs).
- `cluster-api-operator.watchConfigSecret`: `true` so provider controllers re-reconcile when ESO rotates `configSecret` credentials (such as CAPA's `capa-variables`).
- `cluster-api-operator.image.manager`: `v0.30.0` pinned by multi-arch index digest.

## Day-2 notes

- Upgrading the CAPI operator and providers: [upgrades](../../docs/runbooks/upgrades.md#2-capi-operator-and-providers).
- Triaging unreachable workload clusters: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable).

## Links

- [Cluster API providers](../../docs/providers.md)
