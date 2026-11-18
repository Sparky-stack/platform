# cluster

## Purpose

Onboards one workload cluster from `installations/<inst>/clusters/<name>.yaml`: renders its Cluster API topology `Cluster` (`k3s-<provider>`, or `gke-managed` for `gcp-gke`; none for `byo`, an existing cluster registered from its kubeconfig, whose payloads go by `PushSecret` instead of `ClusterResourceSet`), Argo CD cluster secret (via ESO), OpenChoreo per-cluster agent CA/cert + `ClusterDataPlane` + `Environment`s, Falco escalation token, Kyverno image-verification material for Harbor-built images (platform `cosign.pub`, Harbor CA, pull-only robot), and optional multicluster mesh trust.

## Where it runs

- **Target:** `mgmt` cluster (`fleet`, `argocd`, and `openchoreo.orgNamespace`), rendered by `ApplicationSet/fleet` as `Application/cluster-<name>`.
- **Selection:** `provider: docker | aws | hetzner | gcp-gke | byo`, `role: workload` (stamped onto the CAPI `Cluster` and Argo CD cluster secret alongside `addons.platform.koorikla.io/<addon>`, `platform.koorikla.io/cni`, and `mesh.platform.koorikla.io/{group,network}`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| addons | object | `{}` | Per-cluster addon overrides (`addons.platform.koorikla.io/<addon>`). |
| addonsRevision | string | `"HEAD"` | Git revision pin (`platform.koorikla.io/addons-revision`). |
| cni | string | `"cilium"` | `cilium` or `flannel` (fixed at cluster creation; derives `addons.platform.koorikla.io/cilium`); `gke` only on `gcp-gke`. |
| controlPlane.machineType | string | `""` | Server instance type (`controlPlane.replicas` is odd, `>= 3` for cloud production; none on `gcp-gke`). |
| environment | string | `"development"` |  |
| falcoEscalation.enabled | bool | `true` |  |
| falcoEscalation.namespace | string | `"falco"` |  |
| falcoEscalation.remoteKey | string | `"falco-webhook"` |  |
| imageVerification.configMap | string | `"platform-image-verification"` |  |
| imageVerification.cosignKey | string | `"cosign-platform"` |  |
| imageVerification.enabled | bool | `true` |  |
| imageVerification.namespace | string | `"kyverno"` |  |
| imageVerification.pullSecret | string | `"platform-registry"` |  |
| installation.name | string | `"local"` |  |
| kubernetesVersion | string | `""` | k3s version (or GKE `vX.Y.Z` version on `gcp-gke`). |
| mesh.ca | object | `{}` |  |
| mesh.group | string | `""` | Opt-in Istio ambient multicluster mesh membership. |
| mesh.groups | list | `[]` |  |
| name | string | `""` | Cluster identity (`ClusterDataPlane` name and `planeID`). |
| nodeRegistry.caFile | string | `"/etc/rancher/k3s/registry-ca.crt"` |  |
| nodeRegistry.caSecret | string | `"harbor-ca-bundle"` |  |
| nodeRegistry.caStore | string | `"mgmt-harbor"` |  |
| nodeRegistry.robot | string | `"robot$nodes"` |  |
| nodeRegistry.secretKey | string | `"harbor"` |  |
| nodeRegistry.secretProperty | string | `"nodes-secret"` |  |
| openchoreo.dataPlane.enabled | bool | `false` | Registers the `ClusterDataPlane` and binds `openchoreo.dataPlane.{gatewayHost,gatewayPort,environments}`. |
| openchoreo.dataPlane.environments | list | `[]` |  |
| openchoreo.dataPlane.gatewayHost | string | `""` |  |
| openchoreo.dataPlane.gatewayPort | int | `19080` |  |
| provider | string | `"docker"` | Cluster provider (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`) selecting `ClusterClass` (`k3s-docker`, `k3s-aws`, `k3s-hetzner`, `gke-managed`). |
| providerSpec | object | `{}` | Extra `ClusterClass` provider variables passed as-is. |
| region | string | `"local"` |  |
| registry.host | string | `""` |  |
| registry.mirror.enabled | bool | `false` |  |
| registry.nodeHostAlias | string | `""` |  |
| registry.proxyCache | list | `[]` |  |
| registry.type | string | `"external"` |  |
| secrets.backend | string | `"kubernetes"` |  |
| secrets.nodeRegistryAuth.enabled | bool | `true` |  |
| secrets.nodeRegistryAuth.key | string | `"platform-ghcr"` |  |
| secrets.nodeRegistryAuth.registry | string | `"ghcr.io"` |  |
| secrets.workloadKubernetes.namespace | string | `"openchoreo-secrets"` |  |
| secrets.workloadSeed.keys[0] | string | `"openchoreo-observability"` |  |
| workers | list | `[]` | Node pools (`[{name, replicas, machineType, failureDomain}]`; GKE: MachinePools). |

## Day-2 notes

- Adding/removing clusters, worker scaling, and `1` vs `3` server HA: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md) and [upgrades](../../docs/runbooks/upgrades.md).
- Unreachable clusters or disconnected agents: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md).

## Links

- [Cluster API providers: Adding a cluster](../../docs/providers.md#adding-a-cluster), [Bring your own cluster](../../docs/providers.md#bring-your-own-cluster-byo)
- [Portability](../../docs/portability.md)
- [OpenChoreo: Trust model](../../docs/openchoreo.md#trust-model)
- [Multicluster mesh](../../docs/multicluster.md)