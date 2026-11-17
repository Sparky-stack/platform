# istio-eastwest

## Purpose

Deploys the Istio ambient multi-network east-west `Gateway` (`istio-eastwestgateway`) and scoped `platform:istio-reader` RBAC on multicluster mesh members so peers can discover endpoints and tunnel HBONE traffic across clusters.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`; layers `values/provider-aws.yaml` on AWS).
- **Catalog label:** `addons.platform.koorikla.io/istio-eastwest` (`default: false`, set to `"true"` by `charts/cluster` when `mesh.group` is set).

## Key values

- `mesh.{group,network}`: mesh group and network labels injected from the cluster secret (`clusterLabelParameters`).
- `gateway.{name,replicas,serviceAnnotations,loadBalancerSourceRanges}`: east-west Gateway sizing and required peer egress CIDR allowlist outside Docker.
- `reader.{enabled,user,remoteCredentialsSecrets}`: scoped discovery RBAC for `platform:istio-reader`.

## Day-2 notes

- Removing a mesh member cleanly and upgrading Istio: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md#2-remove-decommission-a-workload-cluster) and [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Multicluster mesh](../../docs/multicluster.md)
