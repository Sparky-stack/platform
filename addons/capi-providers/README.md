# capi-providers

## Purpose

Declares `cluster-api-operator` provider CRs on `mgmt`: CAPI `core` (`v1.13.8`), `k3s` bootstrap and control-plane providers (`v0.5.0`), and the installation's enabled infrastructure providers (`docker`, `aws`, `hetzner`, `gcp`), plus CAPA's `capa-variables` `ExternalSecret` and CAPG's `capg-variables` (Workload Identity Federation credential config, no key).

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: capi-system`).
- **Catalog label:** `addons.platform.koorikla.io/capi-providers` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| capi.gcp.serviceAccount | string | `""` |  |
| capi.gcp.workloadIdentityProvider | string | `""` | WIF pool provider (`capi.gcp.{workloadIdentityProvider,serviceAccount}` from `installation.yaml`) that CAPG impersonates. |
| capi.providers | object | `{"aws":false,"docker":true,"gcp":false,"hetzner":false}` | Installation toggles (`capi.providers.{docker,aws,hetzner,gcp}`) selecting which `InfrastructureProvider` CRs render. |
| core.featureGates.ClusterTopology | bool | `true` |  |
| core.leaseFlags | bool | `true` |  |
| core.version | string | `"v1.13.8"` | `v1.13.8` with `core.featureGates.ClusterTopology: true` (`ClusterClass` managed topologies). |
| externalSecrets.refreshInterval | string | `"1h"` |  |
| externalSecrets.store | string | `"platform"` |  |
| infrastructure.aws.configSecret | string | `"capa-variables"` |  |
| infrastructure.aws.credentialsFromStore | bool | `true` |  |
| infrastructure.aws.featureGates | object | `{}` |  |
| infrastructure.aws.leaseFlags | bool | `true` |  |
| infrastructure.aws.version | string | `"v2.13.1"` | CAPA `v2.13.1` (`configSecret`, `credentialsFromStore`) and CAPH `infrastructure.hetzner.version` (`v1.1.12`). |
| infrastructure.docker.featureGates.ClusterTopology | bool | `true` |  |
| infrastructure.docker.leaseFlags | bool | `true` |  |
| infrastructure.docker.version | string | `"v1.13.8"` | CAPD `v1.13.8` (`ClusterTopology: true`). |
| infrastructure.gcp.configSecret | string | `"capg-variables"` |  |
| infrastructure.gcp.featureGates.GKE | bool | `true` |  |
| infrastructure.gcp.featureGates.MachinePool | bool | `true` |  |
| infrastructure.gcp.image | string | `"registry.k8s.io/cluster-api-gcp/cluster-api-gcp-controller:v1.13.1@sha256:4432fe0b984a99810f139029a62f16dd23eeeb8f0a31037f8c5c5ef89ddfcba5"` |  |
| infrastructure.gcp.leaseFlags | bool | `true` |  |
| infrastructure.gcp.tokenPath | string | `"/var/run/secrets/tokens/gcp"` |  |
| infrastructure.gcp.version | string | `"v1.13.1"` | CAPG `v1.13.1`, manager `image` pinned by digest, `GKE` + `MachinePool` `featureGates`. |
| infrastructure.hetzner.version | string | `"v1.1.12"` |  |
| k3s.releaseURL | string | `"https://github.com/k3s-io/cluster-api-k3s/releases"` |  |
| k3s.version | string | `"v0.5.0"` | `v0.5.0` from `cluster-api-k3s` releases (`k3s.releaseURL`). |
| leaderElection.leaseDuration | string | `"60s"` |  |
| leaderElection.renewDeadline | string | `"40s"` |  |
| leaderElection.retryPeriod | string | `"10s"` |  |

## Day-2 notes

- Provider upgrades and rollout verification: [upgrades](../../docs/runbooks/upgrades.md#2-capi-operator-and-providers).
- Workload cluster provisioning or connectivity issues: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable).

## Links

- [Cluster API providers](../../docs/providers.md)