# clusterclasses

## Purpose

Creates namespace `fleet`, CAPI `ClusterClass`es (`k3s-docker`, `k3s-aws`, `k3s-hetzner`, `gke-managed`) with their bootstrap/machine (or GKE managed) templates, and the Hetzner token `ExternalSecret` (`fleet/hetzner`) for enabled `capi.providers`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: fleet`, `serverSideDiff: true`).
- **Catalog label:** `addons.platform.koorikla.io/clusterclasses` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| aws.controlPlaneMachineType | string | `"t3.large"` | EC2 defaults (`aws.{controlPlaneMachineType,workerMachineType,iamInstanceProfiles}`). |
| aws.iamInstanceProfiles.controlPlane | string | `"control-plane.cluster-api-provider-aws.sigs.k8s.io"` |  |
| aws.iamInstanceProfiles.nodes | string | `"nodes.cluster-api-provider-aws.sigs.k8s.io"` |  |
| aws.workerMachineType | string | `"t3.large"` |  |
| capi.providers | object | `{"aws":false,"docker":true,"gcp":false,"hetzner":false}` | Renders only the `ClusterClass`es (`capi.providers.{docker,aws,hetzner,gcp}`) enabled for the installation. |
| docker.kindImage | string | `"docker.io/kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"` | `kindest/node` container image pinned by multi-arch index digest. |
| externalSecrets.refreshInterval | string | `"1h"` |  |
| externalSecrets.store | string | `"platform"` |  |
| gcp.releaseChannel | string | `"regular"` |  |
| gcp.workerMachineType | string | `"e2-standard-4"` | GKE node pool machine type and `releaseChannel` defaults (`gke-managed`). |
| hetzner.controlPlaneMachineType | string | `"cpx31"` | Hetzner Cloud machine, LB, and secret defaults (`hetzner.{controlPlaneMachineType,workerMachineType,image,networkZone,loadBalancerType,secretName}`). |
| hetzner.image | string | `"ubuntu-24.04"` |  |
| hetzner.loadBalancerType | string | `"lb11"` |  |
| hetzner.networkZone | string | `"eu-central"` |  |
| hetzner.secretName | string | `"hetzner"` |  |
| hetzner.workerMachineType | string | `"cpx31"` |  |
| k3s.cloudDisableComponents[0] | string | `"traefik"` |  |
| k3s.cloudDisableComponents[1] | string | `"servicelb"` |  |
| k3s.disableComponents | list | `["traefik"]` | Disables `traefik` (and `servicelb` on cloud via `cloudDisableComponents`) and tunes CAPD lease renewal (`dockerLeaderElectionArgs`). |
| k3s.dockerLeaderElectionArgs[0] | string | `"leader-elect-lease-duration=60s"` |  |
| k3s.dockerLeaderElectionArgs[1] | string | `"leader-elect-renew-deadline=40s"` |  |
| k3s.dockerLeaderElectionArgs[2] | string | `"leader-elect-retry-period=10s"` |  |
| namespace | string | `"fleet"` |  |

## Day-2 notes

- `ClusterClass` template changes, k3s bumps, and `1` vs `3` server rollouts: [upgrades](../../docs/runbooks/upgrades.md#1-kubernetes--k3s-and-clusterclass-rollouts-1-vs-3-servers) and [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md).

## Links

- [Cluster API providers](../../docs/providers.md)