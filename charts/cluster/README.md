# cluster

## Purpose

The one Cluster API chart (`addons/capi-operator` only installs the upstream operator). Folders: `templates/<provider>/` (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`: provider install, credentials, ClusterClass or byo access) and `templates/common/` (CAPI core + k3s providers, namespace `fleet`, and everything every cluster gets). Value `scope` picks what renders:

- `scope: fleet`: provider installs (cluster-api-operator CRs), their credentials, and the ClusterClasses `k3s-docker`, `k3s-aws`, `k3s-hetzner`, `gke-managed` for the providers `installation.yaml` `capi.providers` enables.
- `scope: cluster` (default): onboards one workload cluster from `installations/<inst>/clusters/<name>.yaml`: renders its Cluster API topology `Cluster` (`k3s-<provider>`, or `gke-managed` for `gcp-gke`; none for `byo`, an existing cluster registered from its kubeconfig, whose payloads go by `PushSecret` instead of `ClusterResourceSet`), Argo CD cluster secret (via ESO), OpenChoreo per-cluster agent CA/cert + `ClusterDataPlane` + `Environment`s, Falco escalation token, Kyverno image-verification material for Harbor-built images (platform `cosign.pub`, Harbor CA, pull-only robot), and optional multicluster mesh trust.

## Where it runs

- **Target:** `mgmt` cluster only. `scope: fleet`: once per installation by catalog entry `cluster-fleet` (`ApplicationSet/addon-cluster-fleet`, `Application/cluster-fleet-<mgmt>`; namespaces `fleet` and `cap*-system`). `scope: cluster`: `ApplicationSet/fleet` renders `Application/cluster-<name>` per fleet file (`fleet`, `argocd`, and `openchoreo.orgNamespace`).
- **Selection:** `provider: docker | aws | hetzner | gcp-gke | byo`, `role: workload` (stamped onto the CAPI `Cluster` and Argo CD cluster secret alongside `addons.platform.koorikla.io/<addon>`, `platform.koorikla.io/cni`, and `mesh.platform.koorikla.io/{group,network}`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| addons | object | `{}` | Per-cluster addon overrides (`addons.platform.koorikla.io/<addon>`). |
| addonsRevision | string | `"HEAD"` | Git revision pin (`platform.koorikla.io/addons-revision`). |
| aws.configSecret | string | `"capa-variables"` |  |
| aws.controlPlaneMachineType | string | `"t3.large"` | EC2 defaults (`aws.{controlPlaneMachineType,workerMachineType,iamInstanceProfiles}`). |
| aws.credentialsFromStore | bool | `true` |  |
| aws.featureGates | object | `{}` |  |
| aws.iamInstanceProfiles.controlPlane | string | `"control-plane.cluster-api-provider-aws.sigs.k8s.io"` |  |
| aws.iamInstanceProfiles.nodes | string | `"nodes.cluster-api-provider-aws.sigs.k8s.io"` |  |
| aws.leaseFlags | bool | `true` |  |
| aws.version | string | `"v2.13.1"` | CAPA `v2.13.1` (`configSecret`, `credentialsFromStore`) . |
| aws.workerMachineType | string | `"t3.large"` |  |
| capi.gcp.serviceAccount | string | `""` |  |
| capi.gcp.workloadIdentityProvider | string | `""` | WIF pool provider (`capi.gcp.{workloadIdentityProvider,serviceAccount}`) that CAPG impersonates. |
| capi.providers | object | `{"aws":false,"docker":true,"gcp":false,"hetzner":false}` | Infrastructure providers of the installation (`capi.providers.{docker,aws,hetzner,gcp}`): scope fleet installs their provider and ClusterClass; scope cluster refuses a cluster whose provider is off. |
| cni | string | `"cilium"` | `cilium` or `flannel` (fixed at cluster creation; derives `addons.platform.koorikla.io/cilium`); `gke` only on `gcp-gke`. |
| controlPlane.machineType | string | `""` | Server instance type (`controlPlane.replicas` is odd, `>= 3` for cloud production; none on `gcp-gke`). |
| core.featureGates.ClusterTopology | bool | `true` |  |
| core.leaseFlags | bool | `true` |  |
| core.version | string | `"v1.13.8"` | `v1.13.8` with `core.featureGates.ClusterTopology: true` (`ClusterClass` managed topologies). |
| docker.featureGates.ClusterTopology | bool | `true` |  |
| docker.kindImage | string | `"docker.io/kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"` | `kindest/node` container image pinned by multi-arch index digest. |
| docker.leaseFlags | bool | `true` |  |
| docker.version | string | `"v1.13.8"` | CAPD `v1.13.8` (`ClusterTopology: true`). |
| environment | string | `"development"` |  |
| externalSecrets.refreshInterval | string | `"1h"` |  |
| externalSecrets.store | string | `"platform"` |  |
| falcoEscalation.enabled | bool | `true` |  |
| falcoEscalation.namespace | string | `"falco"` |  |
| falcoEscalation.remoteKey | string | `"falco-webhook"` |  |
| gcp.configSecret | string | `"capg-variables"` |  |
| gcp.featureGates.GKE | bool | `true` |  |
| gcp.featureGates.MachinePool | bool | `true` |  |
| gcp.image | string | `"registry.k8s.io/cluster-api-gcp/cluster-api-gcp-controller:v1.13.1@sha256:4432fe0b984a99810f139029a62f16dd23eeeb8f0a31037f8c5c5ef89ddfcba5"` |  |
| gcp.leaseFlags | bool | `true` |  |
| gcp.releaseChannel | string | `"regular"` |  |
| gcp.tokenPath | string | `"/var/run/secrets/tokens/gcp"` |  |
| gcp.version | string | `"v1.13.1"` | CAPG `v1.13.1`, manager `image` pinned by digest, `GKE` + `MachinePool` `featureGates`. |
| gcp.workerMachineType | string | `"e2-standard-4"` | GKE node pool machine type and `releaseChannel` defaults (`gke-managed`). |
| hetzner.controlPlaneMachineType | string | `"cpx31"` | Hetzner Cloud machine, LB, and secret defaults (`hetzner.{controlPlaneMachineType,workerMachineType,image,networkZone,loadBalancerType,secretName}`). |
| hetzner.image | string | `"ubuntu-24.04"` |  |
| hetzner.loadBalancerType | string | `"lb11"` |  |
| hetzner.networkZone | string | `"eu-central"` |  |
| hetzner.secretName | string | `"hetzner"` |  |
| hetzner.version | string | `"v1.1.12"` |  |
| hetzner.workerMachineType | string | `"cpx31"` |  |
| imageVerification.configMap | string | `"platform-image-verification"` |  |
| imageVerification.cosignKey | string | `"cosign-platform"` |  |
| imageVerification.enabled | bool | `true` |  |
| imageVerification.namespace | string | `"kyverno"` |  |
| imageVerification.pullSecret | string | `"platform-registry"` |  |
| installation.name | string | `"local"` |  |
| k3s.cloudDisableComponents[0] | string | `"traefik"` |  |
| k3s.cloudDisableComponents[1] | string | `"servicelb"` |  |
| k3s.disableComponents | list | `["traefik"]` | Disables `traefik` (and `servicelb` on cloud via `cloudDisableComponents`) and tunes CAPD lease renewal (`dockerLeaderElectionArgs`). |
| k3s.dockerLeaderElectionArgs[0] | string | `"leader-elect-lease-duration=60s"` |  |
| k3s.dockerLeaderElectionArgs[1] | string | `"leader-elect-renew-deadline=40s"` |  |
| k3s.dockerLeaderElectionArgs[2] | string | `"leader-elect-retry-period=10s"` |  |
| k3s.releaseURL | string | `"https://github.com/k3s-io/cluster-api-k3s/releases"` |  |
| k3s.version | string | `"v0.5.0"` | `v0.5.0` from `cluster-api-k3s` releases (`k3s.releaseURL`). |
| kubernetesVersion | string | `""` | k3s version (or GKE `vX.Y.Z` version on `gcp-gke`). |
| leaderElection.leaseDuration | string | `"60s"` |  |
| leaderElection.renewDeadline | string | `"40s"` |  |
| leaderElection.retryPeriod | string | `"10s"` |  |
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
| scope | string | `"cluster"` | `cluster` (one workload cluster) or `fleet` (providers + ClusterClasses, once on mgmt). |
| secrets.backend | string | `"kubernetes"` |  |
| secrets.nodeRegistryAuth.enabled | bool | `true` |  |
| secrets.nodeRegistryAuth.key | string | `"platform-ghcr"` |  |
| secrets.nodeRegistryAuth.registry | string | `"ghcr.io"` |  |
| secrets.workloadKubernetes.namespace | string | `"openchoreo-secrets"` |  |
| secrets.workloadSeed.keys[0] | string | `"openchoreo-observability"` |  |
| workers | list | `[]` | Node pools (`[{name, replicas, machineType, failureDomain}]`; GKE: MachinePools). |

## Day-2 notes

- Provider and ClusterClass upgrades (`core.version`, `<provider>.version`, `docker.kindImage`): [upgrades](../../docs/runbooks/upgrades.md); a ClusterClass template change rolls every cluster of that class.
- Adding/removing clusters, worker scaling, and `1` vs `3` server HA: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md) and [upgrades](../../docs/runbooks/upgrades.md).
- Unreachable clusters or disconnected agents: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md).

## Links

- [Cluster API providers: Adding a cluster](../../docs/providers.md#adding-a-cluster), [Bring your own cluster](../../docs/providers.md#bring-your-own-cluster-byo)
- [Portability](../../docs/portability.md)
- [OpenChoreo: Trust model](../../docs/openchoreo.md#trust-model)
- [Multicluster mesh](../../docs/multicluster.md)