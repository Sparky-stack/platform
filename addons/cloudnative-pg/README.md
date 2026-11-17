# cloudnative-pg

## Purpose

Wrapper chart for CloudNativePG (`0.29.1` / `1.30.1`) and optional `plugin-barman-cloud` (`0.9.0` / `v0.16.0`) on workload clusters. Reconciles PostgreSQL `Cluster`s across all namespaces and publishes a pinned `ClusterImageCatalog` (`postgresql-standard` for PostgreSQL 16, 17, 18).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: cnpg-system`, `serverSideDiff: true`).
- **Catalog label:** `addons.platform.koorikla.io/cloudnative-pg` (`default: false`, opt-in with `"true"` per cluster via `addons.cloudnative-pg: true`).

## Key values

- `namespace.podSecurity`: `restricted` Pod Security admission label on namespace `cnpg-system`.
- `cloudnative-pg.config.clusterWide`: `true` (watches all namespaces, including OpenChoreo `dp-*` cells).
- `imageCatalog.{enabled,name,images}`: `ClusterImageCatalog/postgresql-standard` with digest-pinned PostgreSQL 16/17/18 images.
- `plugin-barman-cloud.enabled`: `false` by default; enables object-storage backups when turned on.

## Day-2 notes

- On-demand Barman backups and restore drills: [backup and restore](../../docs/runbooks/backup-restore.md#6-cloudnativepg-cloudnative-pg).

## Links

- [Data services: PostgreSQL (CloudNativePG)](../../docs/data-services.md#postgresql-cloudnativepg)
