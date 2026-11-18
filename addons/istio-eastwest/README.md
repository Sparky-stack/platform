# istio-eastwest

## Purpose

Deploys the Istio ambient multi-network east-west `Gateway` (`istio-eastwestgateway`) and scoped `platform:istio-reader` RBAC on multicluster mesh members so peers can discover endpoints and tunnel HBONE traffic across clusters.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`; layers `values/provider-aws.yaml` on AWS).
- **Catalog label:** `addons.platform.koorikla.io/istio-eastwest` (`default: false`, set to `"true"` by `charts/cluster` when `mesh.group` is set).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.name | string | `"sample"` |  |
| cluster.provider | string | `"docker"` |  |
| cluster.region | string | `"local"` |  |
| gateway.loadBalancerSourceRanges | list | `[]` |  |
| gateway.name | string | `"istio-eastwestgateway"` | East-west Gateway sizing (`gateway.{name,replicas,serviceAnnotations,loadBalancerSourceRanges}`) and required peer egress CIDR allowlist outside Docker. |
| gateway.replicas | int | `1` |  |
| gateway.resources.limits.memory | string | `"256Mi"` |  |
| gateway.resources.requests.cpu | string | `"50m"` |  |
| gateway.resources.requests.memory | string | `"64Mi"` |  |
| gateway.serviceAnnotations | object | `{}` |  |
| installation.name | string | `"local"` |  |
| mesh.group | string | `""` | Mesh group and `network` labels injected from the cluster secret (`clusterLabelParameters`). |
| mesh.network | string | `""` |  |
| reader.enabled | bool | `true` | Scoped discovery RBAC (`reader.{enabled,user,remoteCredentialsSecrets}`) for `platform:istio-reader`. |
| reader.remoteCredentialsSecrets | bool | `false` |  |
| reader.user | string | `"platform:istio-reader"` |  |

## Day-2 notes

- Removing a mesh member cleanly and upgrading Istio: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md#2-remove-decommission-a-workload-cluster) and [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Multicluster mesh](../../docs/multicluster.md)