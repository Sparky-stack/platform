# capi-providers

## Purpose

Declares `cluster-api-operator` provider CRs on `mgmt`: CAPI `core` (`v1.13.8`), `k3s` bootstrap and control-plane providers (`v0.5.0`), and the installation's enabled infrastructure providers (`docker`, `aws`, `hetzner`), plus CAPA's `capa-variables` `ExternalSecret`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: capi-system`).
- **Catalog label:** `addons.platform.koorikla.io/capi-providers` (`default: true`, opt-out with `"false"`).

## Key values

- `capi.providers.{docker,aws,hetzner}`: installation toggles selecting which `InfrastructureProvider` CRs render.
- `core.{version,featureGates}`: `v1.13.8` with `ClusterTopology: true` (`ClusterClass` managed topologies).
- `k3s.{version,releaseURL}`: `v0.5.0` from `cluster-api-k3s` releases.
- `infrastructure.docker`: `v1.13.8` (`ClusterTopology: true`).
- `infrastructure.aws.{version,configSecret,credentialsFromStore}` (`v2.13.1`) and `infrastructure.hetzner.version` (`v1.1.12`).

## Day-2 notes

- Provider upgrades and rollout verification: [upgrades](../../docs/runbooks/upgrades.md#2-capi-operator-and-providers).
- Workload cluster provisioning or connectivity issues: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable).

## Links

- [Cluster API providers](../../docs/providers.md)
