# crossplane

## Purpose

Wrapper chart for Crossplane v2 (`2.4.3`) on workload clusters. Exposes a single namespaced `PostgreSQL` XRD (`database.platform.koorikla.io`) fulfilled by provider-selected `Composition`s: CloudNativePG (`docker`, `hetzner`), AWS RDS (`aws`), Cloud SQL, or Azure Flexible Server, guarded by ValidatingAdmissionPolicies.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: crossplane-system`, `serverSideDiff: true`; layers `values/provider-docker.yaml` on `docker`).
- **Catalog label:** `addons.platform.koorikla.io/crossplane` (`default: false`, opt-in with `"true"` per cluster via `addons.crossplane: true`).

## Key values

- `crossplane.provider.defaultActivations`: `[]` (`templates/activation-policy.yaml` activates only the APIs used by the active `Composition`).
- `postgresql.{backend,backendByProvider}`: maps `cluster.provider` to `cnpg`, `aws-rds`, `gcp-cloudsql`, or `azure-flexible`.
- `postgresql.{cnpg,aws,gcp,azure}`: backend-specific image catalog (`postgresql-standard`), subnet/VPC, and workload-identity settings.
- `policy.production.{environments,action}`: `Deny` on cloud (`Audit` in `values/provider-docker.yaml`) for non-HA or unbacked `production` instances.

## Day-2 notes

- Backing up composed CloudNativePG databases and upgrading Crossplane: [backup and restore](../../docs/runbooks/backup-restore.md#6-cloudnativepg-cloudnative-pg) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Data services: PostgreSQL as a service](../../docs/data-services.md#postgresql-as-a-service)
