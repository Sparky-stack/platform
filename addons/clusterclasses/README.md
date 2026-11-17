# clusterclasses

## Purpose

Creates namespace `fleet`, CAPI `ClusterClass`es (`k3s-docker`, `k3s-aws`, `k3s-hetzner`) with their bootstrap/machine templates, and the Hetzner token `ExternalSecret` (`fleet/hetzner`) for enabled `capi.providers`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: fleet`, `serverSideDiff: true`).
- **Catalog label:** `addons.platform.koorikla.io/clusterclasses` (`default: true`, opt-out with `"false"`).

## Key values

- `capi.providers.{docker,aws,hetzner}`: renders only the `ClusterClass`es enabled for the installation.
- `k3s.{disableComponents,cloudDisableComponents,dockerLeaderElectionArgs}`: disables `traefik` (and `servicelb` on cloud) and tunes CAPD lease renewal.
- `docker.kindImage`: `kindest/node` container image pinned by multi-arch index digest.
- `aws.{controlPlaneMachineType,workerMachineType,iamInstanceProfiles}`: EC2 defaults and IAM instance profiles.
- `hetzner.{controlPlaneMachineType,workerMachineType,image,networkZone,loadBalancerType,secretName}`: Hetzner Cloud machine, LB, and secret defaults.

## Day-2 notes

- `ClusterClass` template changes, k3s bumps, and `1` vs `3` server rollouts: [upgrades](../../docs/runbooks/upgrades.md#1-kubernetes--k3s-and-clusterclass-rollouts-1-vs-3-servers) and [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md).

## Links

- [Cluster API providers](../../docs/providers.md)
