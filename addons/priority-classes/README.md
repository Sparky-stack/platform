# priority-classes

## Purpose

Renders the PriorityClasses `app-production` (100000) and `app-standard` (1000) that ClusterTrait `resilience` assigns to OpenChoreo component pods; both `preemptionPolicy: Never`, so app priority orders the scheduling queue and never evicts platform pods.

## Where it runs

- **Roles / providers:** `roles: [workload]` (`namespace: kube-system`; the classes are cluster-scoped).
- **Catalog label:** `addons.platform.koorikla.io/priority-classes` (`default: true`). Turning it off makes every pod of ClusterTrait `resilience` fail admission.
- **Diff:** the only addon with `compareOptions: [ServerSideDiff=false]` (#281): `value` and `preemptionPolicy` are immutable, server-side diff's dry-run apply would reject a change and block the Application forever. Client-side, `Force=true,Replace=true` deletes and recreates a changed class ([conventions](../../docs/conventions.md#immutable-fields)).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| priorityClasses | object | `{"app-production":{"description":"OpenChoreo components in the production environment (ClusterTrait resilience).","preemptionPolicy":"Never","value":100000},"app-standard":{"description":"OpenChoreo components outside production (ClusterTrait resilience).","preemptionPolicy":"Never","value":1000}}` | PriorityClasses by name. value and preemptionPolicy are immutable: changing either makes Argo CD delete and recreate the class on the next sync (#281, docs/conventions.md "Immutable fields"). |

## Day-2 notes

- Changing `value` or `preemptionPolicy` recreates the class on the next sync: running pods keep their priority, a pod created while the class is absent is rejected once and retried by its controller.

## Links

- [OpenChoreo: Resilience defaults](../../docs/openchoreo.md#resilience-defaults)