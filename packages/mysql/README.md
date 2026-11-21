# mysql: Crossplane Configuration package

**Status: `moco` enabled** (#256) - addon crossplane installs this package (pinned `tag@sha256` + its embedded Function)
on every cluster with addon moco (label `addons.platform.koorikla.io/moco`); ClusterResourceType `mysql` lives in
`addons/openchoreo-platform/files/platform/cluster-resource-types/mysql.yaml`. The cloud backends are skeletons that
render but were never applied (layout).

The platform's MySQL API (`platform.koorikla.io/v1alpha1 MySQL`, namespaced XR), same layout as
[`packages/postgresql`](../postgresql/README.md) and [docs/crossplane.md](../../docs/crossplane.md): XRD + one
Composition `mysql` (environment-configs -> embedded function `compose-mysql` -> auto-ready) reading
`$facts.backend` from the EnvironmentConfig `platform-mysql`. `functions/compose-mysql/` is Helm-style, one
template per composed object: `00-prelude.yaml.gotmpl` (facts, backend check, derived values), shared objects
`1x-*`, per-backend objects `<backend>-<object>.yaml.gotmpl` (render only on that backend), `90-xr-status`.
Render tests pin the upstream Functions like the addon (`tests/render/functions.yaml`); `validate-render.sh`
builds the project and adds the embedded function (package-derived name) for the render.

## Developer contract

| Field | Default | Meaning |
|---|---|---|
| `version` | `8.4` | MySQL LTS |
| `size` | `S` | `S` / `M` / `L` compute per instance |
| `storageGiB` | `10` | grows, never shrinks |
| `highAvailability` | `false` | 3 instances (MOCO semi-sync) / Multi-AZ / REGIONAL / zone-redundant |
| `database` | `app` | database and app user name, immutable |
| `deletionPolicy` | `Retain` | cloud: keep the database when the XR goes |

Connection Secret `<name>-app` (`status.secretName`) in the XR's namespace - the name and keys of the PostgreSQL API -
same keys on every backend: `host`, `port`, `dbname`, `username`, `password`, `uri` (`mysql://user:pass@host:3306/db`, `?tls=true` in cloud).
The password is generated in-cluster (ESO Password generator) or by RDS (Secrets Manager); it never passes through
the Crossplane pipeline.

## Backends

| `backend` | Composes | Facts |
|---|---|---|
| `moco` | MOCO `MySQLCluster` (Pod Security restricted, slow-log off), ESO `Password` + `ExternalSecret`, a `Job` creating database + user | `mysqlImages` (version -> image, from addon moco `mysqlImageCatalog`) |
| `aws-rds` | `rds.aws.m.upbound.io Instance` (engine mysql, managed master password) + ESO from Secrets Manager | `region`, `dbSubnetGroupName`, `securityGroupIds` |
| `gcp-cloudsql` | `sql.gcp.m.upbound.io DatabaseInstance` (MYSQL_8_4, private IP), `Database`, `User` | `project`, `region`, `network` |
| `azure-flexible` | `dbformysql.azure.m.upbound.io FlexibleServer` + `FlexibleDatabase` | `resourceGroupName`, `location`, `delegatedSubnetId`, `privateDnsZoneId` |

Sample facts per backend: `tests/render/environment/`.

## Local operator choice: MOCO

- **Vitess (CNCF graduated) evaluated first, not chosen for the per-app API**: one database means a `VitessCluster`
  with etcd topology, vtctld, vtgate, vttablet (mysqld + agent) and vtorc - five-plus pods and >1.5 GiB before data, too
  heavy per XR on a k3d data plane, and apps connect through vtgate (MySQL protocol, but not every MySQL feature).
  Vitess fits a later shared, sharded "MySQL platform" tier, not one small database per app.
- **MOCO** ([cybozu-go/moco](https://github.com/cybozu-go/moco), Apache-2.0, maintained, production at Cybozu): one
  `MySQLCluster` = 1 / 3 / 5 mysqld with semi-sync GTID replication, MySQL 8.4 images on ghcr.io, small footprint.
  Gap: no database/user CRD, hence the init `Job` (idempotent SQL as `moco-admin`).
- Also considered: Oracle MySQL Operator (InnoDB Cluster + Router, heavier, no user CRD), Percona Operator for MySQL
  (PXC/Galera, 3 nodes + proxy), mariadb-operator (declarative users, but MariaDB is not MySQL 8.4).

## Verified / still open

- MOCO (checked against v0.38.0 source + chart 0.28.0): Secret `moco-<name>` key `ADMIN_PASSWORD`, primary Service
  `moco-<name>-primary`, `Healthy` condition; images pinned by digest in addon moco; MySQL pods meet Pod Security
  `restricted` (pod seccomp, `overwriteContainers` securityContext for agent / copy-moco-init / moco-init); aggregated
  RBAC `crossplane:compose-mysql` for `MySQLCluster` / `Job` / ESO kinds. Upstream images carry no cosign signature:
  production cells admit them as exact digests (addon kyverno-policies).
- Kyverno: `mysql-only-through-the-platform-api` and `mysql-production-ha` (addon crossplane templates/policies.yaml).
- Open: backups (MOCO BackupPolicy jobs are not restricted-compatible, cybozu-go/moco#949); cloud skeletons (field names
  against provider CRDs, networking/IAM, deletion protection, TLS); file mounts for rotating credentials in OpenChoreo.

## Release and developer loop

As [`packages/postgresql`](../postgresql/README.md#release): `.github/workflows/package-mysql.yaml` (PR: validate +
render against `tests/render/expected/`; main / `mysql-v*` tags: build, push `ghcr.io/koorikla/platform/mysql`, cosign
sign), release-please component `mysql`.

```bash
PACKAGE_ROOT=packages/mysql bash ci/scripts/crossplane/validate-render.sh   # UPDATE_EXPECTED=true to accept
cd packages/mysql && crossplane composition render examples/xr-production.yaml apis/mysql/composition.yaml \
  --xrd apis/mysql/definition.yaml --extra-resources tests/render/environment/aws-rds.yaml
```
