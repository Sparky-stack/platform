# openchoreo-workflow-plane

## Purpose

Wrapper chart for `openchoreo-workflow-plane` (`1.3.3`) on `mgmt`. Runs Argo Workflows, the workflow `cluster-agent`, `ClusterWorkflowPlane/default`, rootless BuildKit `ClusterWorkflowTemplate`s, and strict egress `NetworkPolicy` rules for workflow runs.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-workflow-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-workflow-plane` (`default: true`, opt-out with `"false"`).

## Key values

- `clusterWorkflowPlane.{name,planeID,secretStore}`: binds `ClusterWorkflowPlane/default` to the key-scoped `ClusterSecretStore/workflows`.
- `agentServerCA.{enabled,store,sourceSecret}`: syncs `cluster-gateway-ca` from `ClusterSecretStore/mgmt-openchoreo`.
- `runNetworkPolicy.{enabled,registry,apiServer}`: restricts build/gate pod egress in `workflows-*` namespaces.

## Day-2 notes

- Workflow controller crash loops and upgrades: [incidents](../../docs/runbooks/incidents.md#workflows-controller-crash-loop) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [Build plane](../../docs/build-plane.md)
