# Data services: PostgreSQL, MySQL, Kafka, event-driven autoscaling

Operators for apps on workload clusters, **off by default**: a cluster runs one only after its fleet file opts in
(no Application is generated otherwise), so local docker environments stay lean. Developers reach them through
OpenChoreo types; Crossplane is the workload cluster's control plane behind the `PostgreSQL` and `MySQL` APIs. Catalog
and labels: [conventions.md](conventions.md); addon mechanics: [architecture.md](architecture.md) "Addons".

| Task | How |
|---|---|
| Turn an operator on for a cluster | `addons: { <addon>: true }` in `installations/<inst>/clusters/<name>.yaml` ([Opt in](#opt-in)) |
| Give an app a PostgreSQL database | `Resource` of `ClusterResourceType postgresql` + a `ResourceReleaseBinding` per environment in the app repo ([PostgreSQL from OpenChoreo](#postgresql-from-openchoreo)) |
| Autoscale a component | ClusterTrait `keda-scaler` ([KEDA and OpenChoreo workloads](#keda-and-openchoreo-workloads)) |
| Data-plane agent stuck on a new cluster | `kubectl -n openchoreo-data-plane logs job/capability-gate --all-containers` names the missing CRD ([capability gate](#first-boot-the-capability-gate)) |
| Check a database | `kubectl -n <ns> get postgresql <name>` (BACKEND, ENDPOINT, SECRET, READY); [Verify on a cluster](#verify-on-a-cluster) |

| Addon (catalog) | Namespace | Upstream chart | What |
|---|---|---|---|
| `cloudnative-pg` | cnpg-system | `cloudnative-pg` 0.29.1 (operator 1.30.1) + optional `plugin-barman-cloud` 0.9.0 (v0.16.0) | PostgreSQL clusters (`Cluster`, `Pooler`, `ScheduledBackup`, `Database`); backups to object storage through the Barman Cloud plugin |
| `strimzi` | strimzi | `strimzi-kafka-operator` 1.3.1 | Kafka in KRaft mode (`Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser`, Connect, MirrorMaker 2, Bridge); no ZooKeeper |
| `moco` | moco-system | `moco` 0.28.0 | MySQL 8.4 clusters, semi-sync GTID replication; backend of the [MySQL API](#mysql-as-a-service) |
| `keda` | keda | `keda` 2.21.0 | event-driven autoscaling (`ScaledObject`, `ScaledJob`, `TriggerAuthentication`), scale to zero, external metrics API |
| `crossplane` | crossplane-system | `crossplane` 2.4.3 (v2) | the workload cluster's control plane for in-cluster and cloud resources: Compositions hand a claim to CloudNativePG or MOCO, or cloud providers create RDS / Aurora, Cloud SQL or Azure Flexible Server ([below](#postgresql-as-a-service), [crossplane.md](crossplane.md)) |

All are wrapper charts in `addons/<addon>/`, workload role only; Argo CD applies their CRDs server-side (the Kafka and
CNPG `Cluster` CRDs exceed the client-side annotation limit). Images are multi-arch and digest-pinned, operator
namespaces enforce Pod Security `restricted`, and addon `telemetry`'s Prometheus agent scrapes operator metrics.

## Opt in

The fleet file's `addons` become the label `addons.platform.koorikla.io/<addon>: "true"` on the CAPI `Cluster` and the
Argo CD cluster secret, which the addon ApplicationSet selects on:

```
# installations/<inst>/clusters/<name>.yaml
addons:
  cloudnative-pg: true
  strimzi: true
  keda: true
```

- Values per installation / environment / cluster: `installations/<inst>/addons/<addon>/{values,env-<env>,cluster-<name>}.yaml`
  (values only), e.g. `plugin-barman-cloud.enabled: true` for `cloudnative-pg`.
- Needs `cert-manager` (KEDA serving certs, Barman Cloud plugin) and `telemetry` (prometheus-operator CRDs), both
  default on workload clusters. Without `telemetry` set `monitoring.podMonitor: false` (strimzi),
  `cloudnative-pg.monitoring.podMonitorEnabled: false` and `keda.prometheus.{operator,metricServer,webhooks}.enabled: false`.
- Footprint (requests, operators only): CNPG 20m / 64Mi, Strimzi 50m / 384Mi (JVM), KEDA 50m / 160Mi (three pods);
  every PostgreSQL / Kafka cluster comes on top.
- Turning an addon off removes its Application, not its resources (no resources finalizer): operators, CRDs and managed
  clusters stay until removed deliberately. The CloudNativePG CRDs (and so every PostgreSQL cluster) survive even a
  cascading delete: they carry `helm.sh/resource-policy: keep`, which Argo CD honours (seen live).

## Security and RBAC

- **Pod Security.** Operator namespaces enforce `restricted`; Strimzi also makes its operands restricted
  (`STRIMZI_POD_SECURITY_PROVIDER_CLASS=restricted`); CNPG instance pods and KEDA meet it upstream.
  `hack/tests/test_data_services.sh` checks every rendered pod template.
- **Kyverno.** keda, strimzi and cnpg-system are *not* in the exclusion lists (`addons/kyverno`, `addons/kyverno-policies`
  `platformNamespaces`): the Pod Security policies report on them like on any workload.
- **Watch scope.** All three watch every namespace, because OpenChoreo creates cell namespaces
  (`dp-<org>-<project>-<env>-<hash>`) at runtime:

  | Operator | Grants, in any namespace |
  |---|---|
  | CNPG | ClusterRole `cnpg`: its CRs plus the Pods (incl. `pods/exec`), PVCs, Services, Secrets, ConfigMaps, Jobs, PDBs, Roles/RoleBindings, ServiceAccounts and PodMonitors it creates per PostgreSQL cluster; its own webhook configurations (it patches their `caBundle`; the catalog entry uses ServerSideDiff) |
  | Strimzi | ClusterRoleBindings for `strimzi-cluster-operator-namespaced`, `-watched`, `-global` and the entity operator / broker / client delegation roles: Pods, Services, Secrets, ConfigMaps, PVCs, NetworkPolicies, PDBs, Roles/RoleBindings. Narrow with `watchAnyNamespace: false` + `watchNamespaces` in an overlay |
  | KEDA | `/scale` of every workload kind (`rbac.scaledRefKinds`), HPAs, Secrets referenced by `TriggerAuthentication`s; the metrics apiserver gets `system:auth-delegator` and serves `v1beta1.external.metrics.k8s.io` (one per cluster: nothing else may register it) |

- **Images.** Operators, CNPG's default PostgreSQL (`standard`, no in-tree barman) / PgBouncer images and the Strimzi
  operand images (topic/user operator, Bridge, Connect build tools) are digest-pinned. Strimzi picks the broker image
  per `spec.kafka.version` from tags: pin it with `spec.kafka.image` (example below). Multi-arch check:
  `task images:audit -- --opt-in`.
- **Secrets.** No addon needs one. Operators generate database and Kafka user credentials on the data plane
  (`<cluster>-app`, `KafkaUser` Secret) and they never leave it; external inputs (e.g. object-store keys without
  workload identity) come through ESO from ClusterSecretStore `default`.

## Consuming them from OpenChoreo

Apps reach workload clusters only through OpenChoreo (no Argo CD there), via platform-owned types (addon
openchoreo-platform `files/platform/`, OpenChoreo 1.3.3 API):

| Type | Renders into the cell namespace | Data plane needs |
|---|---|---|
| `ClusterTrait keda-scaler` | KEDA `ScaledObject` for the component's Deployment; removes `/spec/replicas` from it | `keda` |
| `ClusterResourceType postgresql` | `platform.koorikla.io/v1alpha1 PostgreSQL`; never a raw CNPG `Cluster` | `crossplane` (+ `cloudnative-pg` for backend cnpg) |
| `ClusterResourceType mysql` | `platform.koorikla.io/v1alpha1 MySQL` | `crossplane`, `moco` |

`keda-scaler` is allowed on `service`, `web-application` and `worker`, not on `scheduled-task` (CronJob). The cluster
agent may apply these kinds (addon openchoreo-data-plane `templates/cluster-agent-data-services.yaml`; upstream's
ClusterRole knows none of them). Kafka has no type: the event bus as a service (XR across Strimzi / MSK / Managed
Kafka) is [#113](https://github.com/koorikla/platform/issues/113) / [#114](https://github.com/koorikla/platform/issues/114),
and no local cluster runs Strimzi (host RAM).

### Only on data planes that run the operator

The data plane announces what it runs, the type declares what it needs; no cluster names anywhere.

- The fleet file's `addons` reach the `ClusterDataPlane` as annotations `addons.platform.koorikla.io/<addon>: "true"`
  (charts/cluster; same keys as the cluster labels). Each type lists its needs in `platform.koorikla.io/requires-addons`.
- **Traits** check it in CEL: OpenChoreo 1.3.3 exposes `dataplane.annotations` to component and trait templates
  (`DataPlaneData.Annotations`, also for `ClusterDataPlane`s). `keda-scaler`'s first `preRenderValidation` fails the
  ReleaseBinding of an environment whose data plane lacks `keda`, naming the fleet-file switch. An environment can also
  turn the trait off (`traitEnvironmentConfigs.<instance>.enabled: false`).
- **Resource types** cannot: 1.3.3 gives `ResourceType`s no validations, and the resource pipeline's `dataplane.*` has
  only `secretStore`, `gateway` and `observabilityPlaneRef`. So Kyverno `ValidatingPolicy`
  `platform-data-plane-capabilities` on mgmt (addon kyverno-policies) denies a `ResourceReleaseBinding` whose type needs
  an addon the environment's data plane does not announce, shown on the app's Argo CD sync. A binding of a Resource that
  does not exist yet is denied too (apply the Resource in an earlier sync wave; Argo CD retries).
- No environment allow list: 1.3.3's `Environment` has only `dataPlaneRef`, `isProduction` and `gateway`, `allowedTraits`
  is per component type, and a per-type list of environments would restate the fleet file and drift when an
  environment moves. Backstop: without the CRD the apply fails anyway (`no matches for kind`).

#### First boot: the capability gate

The annotation is true from cluster birth; the addon lands minutes later (#246). Addon openchoreo-data-plane therefore
renders a Sync hook `capability-gate` (sync wave -1, before the agent Deployment) that `kubectl wait`s until the CRDs of
every enabled `capabilityGate.addons.<addon>` (switched on per cluster from its label) are Established:

| Addon | CRDs |
|---|---|
| `keda` | `scaledobjects.keda.sh` |
| `crossplane` | `postgresqls.platform.koorikla.io`, the XRD of the Configuration package crossplane pulls once Healthy (~20 min after the agent on a fresh local bootstrap, #255) |
| `moco` | `mysqlclusters.moco.cybozu.com`, `mysqls.platform.koorikla.io` |
| `telemetry` | `podmonitors.monitoring.coreos.com` (ClusterTrait `metrics`; on by default like the addon, #252) |

Without the gate, 1.3.3 applied the ScaledObject first and retried the failed `RenderedRelease` only on
controller-runtime backoff (capped at 1000 s, no watch on the data plane): development served ~17 min after KEDA was
Healthy. `hack/tests/test_openchoreo_types.sh` fails when a type renders an addon kind the gate does not wait for.

Stuck agent: the init container `wait-for-<addon>-crds` of
`kubectl -n openchoreo-data-plane get pod -l app.kubernetes.io/name=capability-gate` names the addon; each wait times out
after `capabilityGate.timeout` (30m) with the CRD name in
`kubectl -n openchoreo-data-plane logs job/capability-gate --all-containers`, and Argo CD retries. A failed crossplane
package (`kubectl get configuration.pkg`) keeps the agent waiting, by design.

### Readiness and replicas

- RenderedRelease health knows Deployments, StatefulSets, Pods and CronJobs; any other kind is healthy once it exists
  (`getUnknownResourceHealth`). So `postgresql` sets `readyWhen` on the XR's `Ready` condition and reads `host` /
  `port` from its status (`applied.postgresql.status.endpoint` / `.port`), so `OutputsResolved` waits for the backend.
  A consumer's ReleaseBinding stays not synced (`ResourceDependenciesReady`) until the `ResourceReleaseBinding` is
  Ready: the workload never starts without its database. A `ScaledObject` is healthy when present (KEDA's `Ready` is
  not consulted).
- The agent server-side-applies every object with `ForceOwnership`, field manager `renderedrelease-controller`.
  `keda-scaler` drops `/spec/replicas` from the Deployment (like upstream's `horizontal-pod-autoscaler` trait), so
  KEDA's HPA owns the field through the scale subresource; no Argo CD on data planes fights over it.

## PostgreSQL as a service

One developer-facing API, `platform.koorikla.io/v1alpha1` `PostgreSQL` (a namespaced Crossplane v2 composite resource,
no claims). The cluster's provider decides the backend: **CloudNativePG** in-cluster where there is no managed database
(local docker, Hetzner, Talos on vSphere), **Amazon RDS / Aurora** on AWS, **Cloud SQL** on GCP, **Azure Database for
PostgreSQL Flexible Server** on Azure. Design and owner decisions: [#91](https://github.com/koorikla/platform/issues/91).

### Developer view

```yaml
apiVersion: platform.koorikla.io/v1alpha1
kind: PostgreSQL
metadata:
  name: orders-db
  namespace: demo
spec:
  version: "17"            # 16 | 17 | 18; can only be raised
  size: S                  # S | M | L (CNPG resources / RDS, Cloud SQL, Flexible Server class)
  storageGiB: 10           # 10..16384; can only grow
  highAvailability: false  # standby in another zone with automatic failover
  backup:
    enabled: false         # automated backups + point-in-time recovery
    retentionDays: 7       # 7..35
  database: orders         # database + owner role (= username); immutable
  deletionPolicy: Retain   # Retain | Delete (cloud backends; see below)
```

`spec: {}` gives PostgreSQL 17, size S, 10 GiB, one instance, no backups, database `app`. `engine: aurora` (aws-rds only,
default `postgres`) picks Aurora instead of an RDS instance.

The app gets Secret **`<name>-app`** in the XR's namespace with keys `host`, `port`, `dbname`, `username`, `password`
and `uri` (`postgresql://...`; cloud backends add `?sslmode=require`). Only these six are the contract (CNPG adds
`jdbc-uri`, `pgpass`, ...). Status: `status.backend`, `.endpoint`, `.port`, `.secretName` (on cloud backends once the
database exists, minutes; bind env vars with `secretKeyRef`), `.backup` (`enabled`, `disabled`, or `unavailable` on a
cluster without a backup target) and `Ready` (all composed resources ready).

Admission rules (Kyverno `ValidatingPolicy`, also emitted as native `ValidatingAdmissionPolicy`):

- **Only through the XR.** Raw CNPG objects (`Cluster`, `Pooler`, `Database`, `Backup`, `ScheduledBackup`,
  `Publication`, `Subscription`, Barman `ObjectStore`) and the RDS / EC2 / KMS / Cloud SQL / Flexible Server managed
  resources are denied outside `crossplane-system` and `cnpg-system`, unless a ServiceAccount of `crossplane-system`,
  `cnpg-system` or `kube-system` asks (Crossplane, providers, the CNPG operator, the garbage collector). Lists: addon
  crossplane `policy.exemptNamespaces`, `policy.exemptServiceAccountNamespaces`.
- **Production is HA and backed up.** XRs in cells labelled `openchoreo.dev/environment: production` must set
  `highAvailability: true` and `backup.enabled: true` (Deny; Audit on local docker clusters, which have neither an
  object store nor a second node).
- **Production cells admit the pinned images.** `openchoreo-trusted-registries-enforce` (addon kyverno-policies) admits
  exactly the operator image and the `imageCatalog` images of `addons/cloudnative-pg/values.yaml` by digest (#327).
  Bump them there only; an installation override is denied in production until kyverno-policies reads it.

### PostgreSQL from OpenChoreo

Apps declare a `Resource` of `ClusterResourceType postgresql` in `deploy/openchoreo/` (synced by the tenant's Argo CD
Application), bind it per environment and wire its outputs into the Workload. OpenChoreo renders the XR into the cell
namespace as `<resource>-<env>-<hash>`, so Secret `<that name>-app` sits next to the workload.

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Resource
metadata:
  name: orders-db
spec:
  owner: { projectName: demo }
  type: { kind: ClusterResourceType, name: postgresql }
  parameters: { database: orders, version: "17" }       # immutable: database; version can only be raised
---
apiVersion: openchoreo.dev/v1alpha1
kind: ResourceReleaseBinding
metadata:
  name: orders-db-development
  annotations:
    argocd.argoproj.io/sync-wave: "1"                    # after the Resource (the admission check reads it)
    platform.koorikla.io/resource-release: latest        # the platform pins spec.resourceRelease (docs/promotion.md)
spec:
  owner: { projectName: demo, resourceName: orders-db }
  environment: development
  retainPolicy: Delete                                   # default (type): Retain - unbinding keeps the database
  resourceTypeEnvironmentConfigs: { size: S, storageGiB: 10 }   # + highAvailability, backup, deletionPolicy
```

```yaml
# workload.yaml
spec:
  dependencies:
    resources:
      - ref: orders-db
        envBindings: { host: PGHOST, port: PGPORT, database: PGDATABASE, username: PGUSER, password: PGPASSWORD, uri: DATABASE_URL }
```

- `host`, `port`, `database` arrive as plain values (XR status); `username`, `password`, `uri` as `secretKeyRef`s to
  `<name>-app`: credentials never leave the data plane.
- **No hash in Git.** 1.3.3 has no auto-deploy for Resources: a binding stays `ResourceReleaseNotSet` until
  `resourceRelease` names a release, whose name hashes the type spec and parameters and changes with every platform
  change to the type. The `resource-release: latest` annotation lets the platform keep the pin on the latest release
  ([promotion.md](promotion.md#resources-no-hand-computed-release)); production pins it in Git.
- **One binding per environment** the component reaches (the Workload's dependency is shared; ReleaseBindings wait for
  it). Production bindings go in `release-bindings/production.yaml` (gated Application, reviewed PR, docs/promotion.md)
  with `highAvailability: true` and `backup: { enabled: true }`.
- PR previews get their own instance automatically ([preview-environments.md](preview-environments.md)).

### Operator view

Opt in per cluster: `addons: { crossplane: true }`, plus `cloudnative-pg: true` where the backend is cnpg.

**Backend selection.** The addon ApplicationSet passes the provider label (`platform.koorikla.io/provider`, from the
fleet file `provider`) as `cluster.provider`; addon crossplane maps it (`postgresql.backendByProvider`) to a backend,
writes it with the cluster's facts into `EnvironmentConfig platform-postgresql`, and installs only the providers that
backend composes. The API (XRD + Composition `postgresql`) is Configuration package `packages/postgresql`, the same on
every cluster ([crossplane.md](crossplane.md): packages, facts, pinning, signature verification).

| Provider fact | Backend | Crossplane providers (xpkg.crossplane.io/crossplane-contrib, pinned by digest) |
|---|---|---|
| `docker`, `hetzner`, `vsphere-talos` | `cnpg` | none |
| `aws`, `aws-eks` | `aws-rds` | `provider-family-aws`, `provider-aws-rds`, `provider-aws-ec2`, `provider-aws-kms` |
| `gcp-gke` | `gcp-cloudsql` | `provider-family-gcp`, `provider-gcp-sql` |
| `azure-aks` | `azure-flexible` | `provider-family-azure`, `provider-azure-dbforpostgresql` |

An unmapped provider fails the render; `postgresql.backend` forces one for a cluster (e.g. cnpg on a cloud cluster). A
`ManagedResourceActivationPolicy` activates only the composed managed resources (`provider.defaultActivations` is
empty), so each provider installs a handful of CRDs.

| Backend | Composed | Connection Secret | HA | Backup |
|---|---|---|---|---|
| cnpg | `Cluster` (image from ClusterImageCatalog `postgresql-standard` of addon cloudnative-pg by major), `PodMonitor` | the operator's `<name>-app` | 3 instances | Barman Cloud `ObjectStore` + daily `ScheduledBackup` under `postgresql.cnpg.backup.destinationPath`/`<cluster>/<ns>/<name>` |
| aws-rds | KMS `Key`, `SecurityGroup` + ingress 5432 from the node security group, `SubnetGroup`, RDS `Instance` (or Aurora `Cluster` + `ClusterInstance`s) | ExternalSecret from the RDS-managed master secret in Secrets Manager (`manageMasterUserPassword`), store `default` | Multi-AZ instance (Aurora: + reader in another AZ) | automated backups, `retentionDays` |
| gcp-cloudsql | `DatabaseInstance` (private IP only, TLS required, IAM DB auth flag), `Database`, `User` | ExternalSecret with an ESO `Password` generator, once the private IP is known | `REGIONAL` | backups + PITR |
| azure-flexible | `FlexibleServer` (delegated subnet, private DNS zone, no public access, Entra + password auth), `FlexibleServerDatabase` | ExternalSecret with an ESO `Password` generator (needed at creation) | zone-redundant | `retentionDays` (Azure keeps >= 7) |

- **Passwords** never pass through Crossplane functions: CNPG and RDS generate them; on GCP / Azure ESO generates one
  into the connection Secret (once; deleting the Secret rotates it) and the provider sets it from there. Cloud
  identifiers: `pg-<namespace>-<name>-<hash of cluster/namespace/name>`. Cloud `username` is the owner/master role;
  per-app least-privilege roles: [#107](https://github.com/koorikla/platform/issues/107).
- **Cluster facts** (values only, `installations/<inst>/addons/crossplane/{values,cluster-<name>}.yaml`; a missing one
  fails the render): [crossplane.md](crossplane.md#cluster-facts-environmentconfig). CNPG backups also need
  `plugin-barman-cloud.enabled: true` in addon cloudnative-pg.
- **Credentials: workload identity only.** A family's providers share ServiceAccount `crossplane-system/provider-<cloud>`
  (DeploymentRuntimeConfig `provider-<cloud>`): IRSA annotation or EKS Pod Identity, GKE Workload Identity, Entra
  workload identity (`azure.workload.identity/use` + client id); `ClusterProviderConfig/default` uses it (`IRSA` /
  `PodIdentity`, `InjectedIdentity`, `OIDCTokenFile`). No static key anywhere. On AWS `ClusterSecretStore/default`'s
  identity must read the RDS-managed secrets (`rds!*`), which lets every tenant on that cluster reference them.
- **Deletion.** `deletionPolicy: Retain` (default) gives the cloud resources `managementPolicies` without `Delete`
  (Crossplane v2 managed resources have no `deletionPolicy`) and turns on the cloud's deletion protection: deleting the
  XR keeps the database. `Delete` removes it (final snapshot when backups are on). CNPG data lives in PVCs owned by the
  `Cluster` and goes with the XR either way: keep backups on.
- Packaging, Pod Security of Functions / Providers (PSS `restricted`), offline render tests and the one-off
  `compositionRef` patch when upgrading from the Helm-templated API: [crossplane.md](crossplane.md). Live checks:
  [#107](https://github.com/koorikla/platform/issues/107).

## MySQL as a service

API `platform.koorikla.io/v1alpha1 MySQL` (package [`packages/mysql`](../packages/mysql/README.md)), one backend:
[MOCO](https://github.com/cybozu-go/moco) (addon [`moco`](../addons/moco/README.md)). The package's cloud Compositions
are layout only, not installed.

- **Opt in:** `addons: { crossplane: true, moco: true }`. The label `addons.platform.koorikla.io/moco` installs the
  operator, makes addon crossplane install Configuration `platform-mysql` (pinned `tag@sha256` with its embedded
  Function) and EnvironmentConfig `platform-mysql` (backend `moco`, addon moco's mysqld image catalog), turns on the
  capability gate's CRD wait, and announces what ClusterResourceType `mysql` (`requires-addons: crossplane,moco`) needs.
- **Developer view:** a Resource of type `mysql` (parameters `version` 8.4, `database`; per environment `size`,
  `storageGiB`, `highAvailability`). Outputs and Secret `<name>-app` match PostgreSQL (keys `host`, `port`, `dbname`,
  `username`, `password`, `uri`). The password comes from an ESO `Password` generator; an init Job creates database +
  user.
- **Production:** `highAvailability: true` (3 mysqld, semi-sync GTID) is required (Kyverno `mysql-production-ha`; Audit
  on docker). No backups yet: MOCO's BackupPolicy jobs cannot meet Pod Security restricted (cybozu-go/moco#949).
- **Security:** tenants cannot create `MySQLCluster` / `BackupPolicy` (Kyverno `mysql-only-through-the-platform-api`).
  MySQL pods meet restricted (pod seccomp + `overwriteContainers` dropping capabilities on agent, copy-moco-init,
  moco-init; slow-log off). Production cells admit exactly addon moco's mysqld catalog image(s) and moco-agent image
  (`openchoreo-trusted-registries-enforce`). The controller (`moco-system/sa/moco-controller-manager`, ambient) is a
  platform peer of the cell AuthorizationPolicy: it dials the agent (gRPC 9080) and mysqld (3306).
- **Footprint:** operator 100m / 20Mi (upstream defaults, limit 256Mi); each XR adds 1 (or 3) mysqld pods (size S:
  512Mi request). Locally `dev1` runs the operator and the API, no MySQL XR.

## PostgreSQL (CloudNativePG)

A raw CNPG `Cluster`, for platform namespaces and dev clusters (tenants go through the XR). `instances: 3` gives a
primary + two streaming replicas with automated failover.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders-db
  namespace: demo
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: orders
      owner: orders
  resources:
    requests: { cpu: 50m, memory: 256Mi }
    limits: { memory: 512Mi }
```

Services: `orders-db-rw` (primary), `orders-db-ro` (replicas), `orders-db-r` (any). Instance metrics (port `metrics`,
9187, queries from ConfigMap `cnpg-default-monitoring`) need a PodMonitor per cluster (`spec.monitoring.enablePodMonitor`
is deprecated upstream):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: orders-db
  namespace: demo
spec:
  selector:
    matchLabels:
      cnpg.io/cluster: orders-db
  podMetricsEndpoints:
    - port: metrics
```

### Backups

Use the **Barman Cloud plugin** (CNPG-I), not the deprecated in-tree `spec.backup.barmanObjectStore`. Enable it per
installation (`installations/<inst>/addons/cloudnative-pg/values.yaml`: `plugin-barman-cloud: { enabled: true }`); it
runs next to the operator with cert-manager certificates. The backup sidecar runs as the cluster's ServiceAccount (same
name as the `Cluster`): bind that **workload identity** to a role that may write the bucket prefix (EKS Pod Identity or
IRSA via `spec.serviceAccountTemplate` annotation `eks.amazonaws.com/role-arn`, GKE or Azure Workload Identity). No
static keys.

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: orders-db-backups
  namespace: demo
spec:
  retentionPolicy: 30d
  configuration:
    destinationPath: s3://example-pg-backups/orders-db
    s3Credentials:
      inheritFromIAMRole: true
    wal:
      compression: gzip
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: orders-db
  namespace: demo
spec:
  instances: 3
  storage:
    size: 10Gi
  serviceAccountTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/orders-db-backup   # IRSA; none with Pod Identity
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: orders-db-backups
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: orders-db-daily
  namespace: demo
spec:
  schedule: "0 0 3 * * *"
  backupOwnerReference: self
  cluster:
    name: orders-db
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Hetzner object storage has no workload identity: its S3 key pair is the one exception, from an ExternalSecret on
ClusterSecretStore `default`, referenced from `s3Credentials.accessKeyId`/`secretAccessKey`. Local docker clusters keep
no backups. Restore: a new `Cluster` with `bootstrap.recovery.source` pointing at an `externalClusters` entry using the
same plugin and ObjectStore.

## Kafka (Strimzi)

Strimzi 1.x is KRaft only: node pools carry `controller` and/or `broker` roles, no ZooKeeper section, and
`kafka.strimzi.io/v1` needs no feature annotations. Smallest useful cluster (one combined node, development):

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: demo
  labels:
    strimzi.io/cluster: events
spec:
  replicas: 1
  roles: [controller, broker]
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 1Gi
        kraftMetadata: shared
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: events
  namespace: demo
spec:
  kafka:
    version: 4.3.2
    image: quay.io/strimzi/kafka:1.3.1-kafka-4.3.2@sha256:9cea505e434a53cea40941d2c6e9aa5896792fe9c9380feb1d7adea3867a3a0b
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: orders
  namespace: demo
  labels:
    strimzi.io/cluster: events
spec:
  partitions: 3
  replicas: 1
```

Production: separate `controller` (3) and `broker` (3+) pools, replication factor 3, `min.insync.replicas: 2`, TLS or
SCRAM listeners with `KafkaUser`s. Broker metrics: `spec.kafka.metricsConfig` (Strimzi metrics reporter or JMX
exporter) plus a PodMonitor selecting `strimzi.io/cluster: <name>`.

**NetworkPolicies (#210).** In an ambient cell the operator's own per-listener policies would drop HBONE (`15008/tcp`),
so addon `strimzi` sets `STRIMZI_NETWORK_POLICY_GENERATION=false` and addon `kyverno-policies` generates
`platform-strimzi` instead ([networking.md](networking.md#strict-mtls-in-cell-namespaces)). A Kafka outside an ambient
cell (a plain namespace like `demo`, or a cell with `istio.io/dataplane-mode=none`) gets no policy: write one, including
`15008/tcp` if the namespace is in the mesh. `hack/tests/test_mesh_contracts.sh` fails when the operator's generation is
back on or a policy selecting Kafka pods would drop 15008 from the cell, the operator or KEDA.

## KEDA and OpenChoreo workloads

A `ScaledObject` targets a Deployment; KEDA owns an HPA `keda-hpa-<name>` and scales 0 <-> 1 itself. Outside OpenChoreo
(platform namespaces, a dev cluster) write one directly:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: orders-worker
  namespace: demo
spec:
  scaleTargetRef:
    name: orders-worker
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: events-kafka-bootstrap.demo.svc:9092
        consumerGroup: orders-worker
        topic: orders
        lagThreshold: "50"
```

On OpenChoreo components use the trait:

```yaml
# component.yaml (app repo)
spec:
  traits:
    - kind: ClusterTrait
      name: keda-scaler
      instanceName: scaler
      parameters:
        minReplicas: 1
        maxReplicas: 4
        triggers:
          - type: cpu
            metricType: Utilization
            metadata: { value: "75" }
          - type: cron
            metadata: { timezone: Europe/Tallinn, start: "0 8 * * 1-5", end: "0 18 * * 1-5", desiredReplicas: "2" }
# release-bindings/<env>.yaml: per-environment bounds, or off where the data plane has no KEDA
spec:
  traitEnvironmentConfigs:
    scaler: { minReplicas: 2, maxReplicas: 8 }   # or { enabled: false }
```

It renders ScaledObject `<component>-<env>-<hash>-<instanceName>` next to the Deployment (HPA `keda-hpa-<that name>`).

- **Trait, not a hand-written ScaledObject:** app repos cannot sync KEDA objects (tenant AppProject), and only the
  trait drops `spec.replicas`; otherwise the agent re-applies `replicas: ${environmentConfigs.replicas}` and resets
  KEDA ([above](#readiness-and-replicas)).
- **One autoscaler per Deployment:** `keda-scaler` refuses to render next to `horizontal-pod-autoscaler`
  (`postRenderValidation`); KEDA's webhook would reject it anyway.
- **Triggers** are KEDA scalers (`type`, `metadata` strings, optional `name`, `metricType`, `authenticationRef`).
  `authenticationRef` names a `TriggerAuthentication` in the cell namespace; tenants get no
  `ClusterTriggerAuthentication` (it would hand them platform credentials).
- **Istio ambient.** The operator namespaces `keda`, `strimzi` and `cnpg-system` are mesh clients of the STRICT cells
  ([networking.md](networking.md#strict-mtls-in-cell-namespaces)): KEDA reaches its scaler endpoints (Kafka bootstrap,
  Prometheus, an app's metrics URL) over HBONE mTLS. Verified live with CNPG; Strimzi and KEDA follow the same path
  (VERIFY). An app's metrics URL is also behind OpenChoreo's per-component NetworkPolicy (same cell and system
  components only). CPU/memory targets are exact in ambient (no sidecar).
- **Scaled to zero**, requests fail until KEDA scales up (no HTTP activator; the KEDA HTTP add-on is not installed).

## Verify on a cluster

```
kubectl --context <dev1> -n cnpg-system get deploy cnpg                      # operator Ready
kubectl --context <dev1> -n demo get clusters.postgresql.cnpg.io orders-db   # STATUS "Cluster in healthy state"
kubectl --context <dev1> -n strimzi get deploy strimzi-cluster-operator
kubectl --context <dev1> -n demo get kafka events                            # READY True
# Kafka in an ambient cell (#210): platform-strimzi present, no operator-generated <name>-network-policy-*, broker Ready
kubectl --context <dev1> -n <cell ns> get networkpolicy platform-strimzi,platform-mesh-hbone
kubectl --context <dev1> -n <cell ns> get networkpolicy -l strimzi.io/cluster            # none
kubectl --context <dev1> -n <cell ns> get kafka <name>                                   # READY True
kubectl --context <dev1> -n keda get apiservice v1beta1.external.metrics.k8s.io
kubectl --context <dev1> get providers.pkg.crossplane.io,functions.pkg.crossplane.io   # INSTALLED/HEALTHY True
kubectl --context <dev1> get xrd postgresqls.platform.koorikla.io                       # ESTABLISHED True
kubectl --context <dev1> -n demo get postgresql orders-db                               # READY True, SECRET orders-db-app
# OpenChoreo types (mgmt) and what they rendered (dev1 cell namespace)
kubectl --context k3d-platform-mgmt get clustertrait keda-scaler; kubectl --context k3d-platform-mgmt get clusterresourcetype postgresql
kubectl --context k3d-platform-mgmt get clusterdataplane <dev1> -o jsonpath='{.metadata.annotations}'   # addons.platform.koorikla.io/*
kubectl --context k3d-platform-mgmt -n default get resourcereleasebinding <resource>-<env>              # Ready True, status.outputs
kubectl --context <dev1> -n <cell ns> get scaledobject,hpa,postgresql
```
