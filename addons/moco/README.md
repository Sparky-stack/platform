# moco

## Purpose

Wrapper chart for MOCO (`0.28.0` / `0.38.0`) on workload clusters: the in-cluster backend of the platform MySQL API (`packages/mysql`, Composition backend `moco`). Reconciles `MySQLCluster`s across all namespaces under Pod Security `restricted` and owns the digest-pinned mysqld image catalog (`mysqlImageCatalog`).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: moco-system`, `serverSideDiff: true`).
- **Catalog label:** `addons.platform.koorikla.io/moco` (`default: false`, opt-in with `"true"` per cluster via `addons.moco: true`); the same label enables the MySQL API in addon crossplane.

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| controller.replicas | int | `1` |  |
| controller.resources.limits.cpu | string | `"500m"` |  |
| controller.resources.limits.memory | string | `"256Mi"` |  |
| controller.resources.requests.cpu | string | `"100m"` |  |
| controller.resources.requests.memory | string | `"20Mi"` |  |
| moco.agent.image.repository | string | `"ghcr.io/cybozu-go/moco-agent"` |  |
| moco.agent.image.tag | string | `"0.17.0@sha256:a6d9cc387a08a5d108ee89fb40e6274c47a435d3bb6fa71d4b822873e26b966b"` |  |
| moco.crds.enabled | bool | `true` |  |
| moco.fluentbit.image.repository | string | `"ghcr.io/cybozu-go/moco/fluent-bit"` |  |
| moco.fluentbit.image.tag | string | `"5.1.4.1@sha256:33895ebd0f7ba3d53d146b42a461ca6c05e51a78bed22cf158151bba059a5881"` |  |
| moco.image.repository | string | `"ghcr.io/cybozu-go/moco"` |  |
| moco.image.tag | string | `"0.38.0@sha256:35f9f4434a0e92b78ef9dc55a518d002dadece576a9094fa638e59574ecedfe3"` |  |
| moco.mysqldExporter.image.repository | string | `"ghcr.io/cybozu-go/moco/mysqld_exporter"` |  |
| moco.mysqldExporter.image.tag | string | `"0.20.0.1@sha256:793f8c94a43d03a2d1a176e80bfa99fa1ba0e4c4a83161f24a511e38da0e57e6"` |  |
| moco.replicaCount | int | `0` |  |
| mysqlImageCatalog | object | `{"8.4":"ghcr.io/cybozu-go/moco/mysql:8.4.10.1@sha256:bdb88ae2023dcba0218bf900c7f39117c7a6e4101de6b5c8f62774c1d897b68a"}` | mysqld image per MySQL version (MOCO ships no image catalog): the single source. Addon crossplane reads it as the EnvironmentConfig fact `mysqlImages` (catalog valuesFromAddons) and addon kyverno-policies admits exactly these in production cells. Multi-arch (amd64, arm64), pinned by digest. Keys = the MySQL XRD's spec.version enum. |
| namespace.ambient | bool | `true` |  |
| namespace.podSecurity | string | `"restricted"` | `restricted` Pod Security admission label on namespace `moco-system`. |

## Day-2 notes

- The upstream Deployment `moco-controller` runs 0 replicas by design; the controller is `moco-controller-restricted` (values.yaml header).

## Links

- [Data services: MySQL as a service](../../docs/data-services.md#mysql-as-a-service)