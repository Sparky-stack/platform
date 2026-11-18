# cloudnative-pg

## Purpose

Wrapper chart for CloudNativePG (`0.29.1` / `1.30.1`) and optional `plugin-barman-cloud` (`0.9.0` / `v0.16.0`) on workload clusters. Reconciles PostgreSQL `Cluster`s across all namespaces and publishes a pinned `ClusterImageCatalog` (`postgresql-standard` for PostgreSQL 16, 17, 18).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: cnpg-system`, `serverSideDiff: true`).
- **Catalog label:** `addons.platform.koorikla.io/cloudnative-pg` (`default: false`, opt-in with `"true"` per cluster via `addons.cloudnative-pg: true`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cloudnative-pg.config.clusterWide | bool | `true` | `true` (watches all namespaces, including OpenChoreo `dp-*` cells). |
| cloudnative-pg.config.data.PGBOUNCER_IMAGE_NAME | string | `"ghcr.io/cloudnative-pg/pgbouncer:1.25.2@sha256:b15c428057d1ffbc19fb70496911a5f1a47066dcc1315bf794f4e85ade29e2e5"` |  |
| cloudnative-pg.config.data.POSTGRES_IMAGE_NAME | string | `"ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:de572898499fab9406f0da51929da562f96f3be40ca79fafea8ec1a8d5b42065"` |  |
| cloudnative-pg.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| cloudnative-pg.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| cloudnative-pg.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| cloudnative-pg.containerSecurityContext.runAsGroup | int | `10001` |  |
| cloudnative-pg.containerSecurityContext.runAsUser | int | `10001` |  |
| cloudnative-pg.containerSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| cloudnative-pg.crds.create | bool | `true` |  |
| cloudnative-pg.fullnameOverride | string | `"cnpg"` |  |
| cloudnative-pg.image.repository | string | `"ghcr.io/cloudnative-pg/cloudnative-pg"` |  |
| cloudnative-pg.image.tag | string | `"1.30.1@sha256:923c267ec29636db3bee20f993d0ec4973fa22998e1adad37da79e4d32b5bc07"` |  |
| cloudnative-pg.monitoring.podMonitorEnabled | bool | `true` |  |
| cloudnative-pg.podSecurityContext.runAsNonRoot | bool | `true` |  |
| cloudnative-pg.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| cloudnative-pg.resources.limits.cpu | string | `"500m"` |  |
| cloudnative-pg.resources.limits.memory | string | `"512Mi"` |  |
| cloudnative-pg.resources.requests.cpu | string | `"20m"` |  |
| cloudnative-pg.resources.requests.memory | string | `"64Mi"` |  |
| imageCatalog.enabled | bool | `true` | `ClusterImageCatalog/postgresql-standard` (`imageCatalog.{enabled,name,images}`) with digest-pinned PostgreSQL 16/17/18 images. |
| imageCatalog.images.16 | string | `"ghcr.io/cloudnative-pg/postgresql:16.16-standard-trixie@sha256:0848a2f80eb48d9bff76857ce988a6053b4120e7ecbdc4414e24cb1cd2df0754"` |  |
| imageCatalog.images.17 | string | `"ghcr.io/cloudnative-pg/postgresql:17.12-standard-trixie@sha256:b6d31545fc2c500cc56af2cff91bbc37408deff6815b84446da0a2c9a54b3d1c"` |  |
| imageCatalog.images.18 | string | `"ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie@sha256:de572898499fab9406f0da51929da562f96f3be40ca79fafea8ec1a8d5b42065"` |  |
| imageCatalog.name | string | `"postgresql-standard"` |  |
| namespace.ambient | bool | `true` |  |
| namespace.podSecurity | string | `"restricted"` | `restricted` Pod Security admission label on namespace `cnpg-system`. |
| plugin-barman-cloud.enabled | bool | `false` | `false` by default; enables object-storage backups when turned on. |
| plugin-barman-cloud.image.registry | string | `"ghcr.io"` |  |
| plugin-barman-cloud.image.repository | string | `"cloudnative-pg/plugin-barman-cloud"` |  |
| plugin-barman-cloud.image.tag | string | `"v0.16.0@sha256:6404a416718bd7aad943c67a25a7bb20d0558b43edfeab0bf167f013ca435882"` |  |
| plugin-barman-cloud.resources.limits.cpu | string | `"200m"` |  |
| plugin-barman-cloud.resources.limits.memory | string | `"256Mi"` |  |
| plugin-barman-cloud.resources.requests.cpu | string | `"10m"` |  |
| plugin-barman-cloud.resources.requests.memory | string | `"64Mi"` |  |
| plugin-barman-cloud.sidecarImage.registry | string | `"ghcr.io"` |  |
| plugin-barman-cloud.sidecarImage.repository | string | `"cloudnative-pg/plugin-barman-cloud-sidecar"` |  |
| plugin-barman-cloud.sidecarImage.tag | string | `"v0.16.0@sha256:c669259e20ed1e11fad821f735c396c19d929985aa05b9544b13ecc8b5a386d0"` |  |

## Day-2 notes

- On-demand Barman backups and restore drills: [backup and restore](../../docs/runbooks/backup-restore.md#6-cloudnativepg-cloudnative-pg).

## Links

- [Data services: PostgreSQL (CloudNativePG)](../../docs/data-services.md#postgresql-cloudnativepg)