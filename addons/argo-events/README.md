# argo-events

## Purpose

Wrapper chart for `argo-events` (`2.4.28` / `v1.9.11`) on `mgmt`. Runs the platform's JetStream `EventBus`, `EventSource`s, and `Sensor`s receiving per-cluster Falco `critical` escalations and OpenChoreo `staging` rollout events to trigger `falco-response` and `promotion-gate` workflows.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: argo-events`).
- **Catalog label:** `addons.platform.koorikla.io/argo-events` (`default: true`, opt-out with `"false"`).

## Key values

- `falco.{enabled,clusters,tokenSecret,route,response}`: authenticates per-cluster `falcosidekick` webhooks (`fleetParameters` injects `falco.clusters` from Argo CD cluster secrets) and runs `falco-response`.
- `promotionGate.{enabled,sourceEnvironments,workflow}`: triggers `ClusterWorkflow/promotion-gate` when `staging` bindings roll out.
- `workflowPlane`: `auto` (renders `Sensor`s and `WorkflowTemplate`s when Argo Workflows CRDs and `openchoreo.workflowPlane.enabled` are active).

## Day-2 notes

- Triaging Falco critical escalations and blocked promotion triggers: [incidents](../../docs/runbooks/incidents.md#falco-critical-alert) and [promotion gate failing closed](../../docs/runbooks/incidents.md#promotion-gate-failing-closed).

## Links

- [Observability: Falco](../../docs/observability.md#falco)
- [Promotion gates](../../docs/promotion.md)
