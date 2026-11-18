# Data services: PostgreSQL, Kafka, event-driven autoscaling

Three operators for workloads on workload clusters, **off by default** everywhere: a cluster runs them only after it
opts in, so local docker environments stay lean (no Application is generated for a cluster that does not opt in).
Catalog and labels: [conventions.md](conventions.md); addon mechanics: [architecture.md](architecture.md) "Addons".

| Addon (catalog) | Namespace | Upstream chart | What |
|---|---|---|---|
| `cloudnative-pg` | cnpg-system | `cloudnative-pg` 0.29.1 (operator 1.30.1) + optional `plugin-barman-cloud` 0.9.0 (v0.16.0) | PostgreSQL clusters (`Cluster`, `Pooler`, `ScheduledBackup`, `Database`); backups to object storage through the Barman Cloud plugin |
| `strimzi` | strimzi | `strimzi-kafka-operator` 1.3.1 | Apache Kafka in KRaft mode (`Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser`, Connect, MirrorMaker 2, Bridge); no ZooKeeper |
| `keda` | keda | `keda` 2.21.0 | event-driven autoscaling (`ScaledObject`, `ScaledJob`, `TriggerAuthentication`), scale to zero, external metrics API |
| `crossplane` | crossplane-system | `crossplane` 2.4.3 (Crossplane v2) | PostgreSQL as a service: one `PostgreSQL` API, fulfilled per cluster by CloudNativePG, RDS / Aurora, Cloud SQL or Azure Flexible Server ([below](#postgresql-as-a-service)) |

The three operators: wrapper charts in `addons/<addon>/`, workload role only, CRDs from the chart applied server-side by Argo CD
(the Kafka and CNPG `Cluster` CRDs exceed the client-side apply annotation limit), images multi-arch (amd64 + arm64)
pinned by digest, Pod Security `restricted` enforced on the operator namespace, operator metrics scraped by the
Prometheus agent of addon `telemetry`.

## Opt in

Per cluster, in its fleet file (the label `addons.platform.koorikla.io/<addon>: "true"` flows to the CAPI `Cluster` and
the Argo CD cluster secret; the addon ApplicationSet selects on it):

```
# installations/<inst>/clusters/<name>.yaml
addons:
  cloudnative-pg: true
  strimzi: true
  keda: true
```

For a whole installation, set it in every cluster file that should run them. Values per installation / environment /
cluster go into `installations/<inst>/addons/<addon>/{values,env-<env>,cluster-<name>}.yaml` (values only), e.g.
`plugin-barman-cloud.enabled: true` for `cloudnative-pg`.

Needs on the same cluster: `cert-manager` (KEDA serving certificates, Barman Cloud plugin) and `telemetry`
(prometheus-operator CRDs for the ServiceMonitors/PodMonitors) - both default addons on workload clusters. A cluster
without `telemetry` sets `monitoring.podMonitor: false` (strimzi), `cloudnative-pg.monitoring.podMonitorEnabled: false`
and `keda.prometheus.{operator,metricServer,webhooks}.enabled: false`.

Footprint (requests, operators only): CNPG 20m / 64Mi, Strimzi 50m / 384Mi (JVM), KEDA 50m / 160Mi (three pods).
Every PostgreSQL / Kafka cluster you create comes on top.

Turning an addon off removes its Application but no resources (the generated Applications carry no resources
finalizer): operators, CRDs and the clusters they manage stay until removed deliberately. Even a cascading delete keeps
the CloudNativePG CRDs (and with them every PostgreSQL cluster): they carry `helm.sh/resource-policy: keep`, which
Argo CD honours (seen live).

## Security and RBAC

- **Pod Security.** The operator namespaces carry `pod-security.kubernetes.io/enforce: restricted`. Strimzi also makes
  every operand it creates restricted (`STRIMZI_POD_SECURITY_PROVIDER_CLASS=restricted`); CNPG instance pods and KEDA
  meet restricted upstream. `hack/tests/test_data_services.sh` checks every rendered pod template.
- **Kyverno.** keda, strimzi and cnpg-system are *not* in the Kyverno exclusion lists (`addons/kyverno`,
  `addons/kyverno-policies` `platformNamespaces`): the Pod Security policies report on them like on any workload.
- **Watch scope.** All three watch every namespace, because OpenChoreo creates the cell namespaces
  (`dp-<org>-<project>-<env>-<hash>`) at runtime. What that grants:
  - CNPG: ClusterRole `cnpg` - its CRs plus the Pods (incl. `pods/exec`), PVCs, Services, Secrets, ConfigMaps, Jobs,
    PDBs, Roles/RoleBindings, ServiceAccounts and PodMonitors it creates for each PostgreSQL cluster, in any namespace,
    and its own webhook configurations (it patches their `caBundle`; the catalog entry uses ServerSideDiff).
  - Strimzi: ClusterRoleBindings for `strimzi-cluster-operator-namespaced`, `-watched`, `-global` and the entity
    operator / broker / client delegation roles - Pods, Services, Secrets, ConfigMaps, PVCs, NetworkPolicies, PDBs and
    Roles/RoleBindings in any namespace. Narrow it with `watchAnyNamespace: false` + `watchNamespaces` in an overlay
    when Kafka clusters live only in known namespaces.
  - KEDA: reads `/scale` of every workload kind (`rbac.scaledRefKinds`), manages HPAs, reads Secrets referenced by
    `TriggerAuthentication`s; the metrics apiserver gets `system:auth-delegator` and serves
    `v1beta1.external.metrics.k8s.io` (one per cluster: nothing else may register it).
- **Images.** Operators, CNPG's default PostgreSQL (`standard`, no in-tree barman) / PgBouncer images and the Strimzi
  operand images it launches (topic/user operator, Bridge, Connect build tools) are pinned by digest. Strimzi picks the
  broker image per `spec.kafka.version` from tags; pin it with `spec.kafka.image` (example below). Multi-arch check:
  `task images:audit -- --opt-in` (renders opt-in addons too).
- **Secrets.** No addon needs one. Database and Kafka user credentials are generated on the data plane by the
  operators (`<cluster>-app` Secret, `KafkaUser` Secret) and never leave it; anything supplied from outside (e.g.
  object-store keys where no workload identity exists) comes through ESO from ClusterSecretStore `default`.

## Consuming them from OpenChoreo

Apps reach workload clusters only through OpenChoreo (no Argo CD there), so developers use the operators through
platform-owned OpenChoreo types (addon openchoreo-platform `files/platform/`, OpenChoreo 1.3.3 API):

| Type | Renders into the cell namespace | Data plane needs |
|---|---|---|
| `ClusterTrait keda-scaler` | KEDA `ScaledObject` for the component's Deployment; removes `/spec/replicas` from it | `keda` |
| `ClusterResourceType postgresql` | `platform.koorikla.io/v1alpha1 PostgreSQL` ([below](#postgresql-as-a-service)); never a raw CNPG `Cluster` | `crossplane` (+ `cloudnative-pg` where the backend is cnpg) |

Kafka has no type: the event bus as a service (Crossplane XR across Strimzi / MSK / Managed Kafka) is
[#113](https://github.com/koorikla/platform/issues/113) / [#114](https://github.com/koorikla/platform/issues/114),
and no local cluster runs Strimzi (host RAM). `keda-scaler` is in the `allowedTraits` of the Deployment-based component
types (`service`, `web-application`, `worker`); `scheduled-task` (CronJob) does not get it. The data-plane cluster agent
may apply and observe both kinds (addon openchoreo-data-plane `templates/cluster-agent-data-services.yaml`; upstream's
ClusterRole knows neither).

### Only on data planes that run the operator

Declarative, no cluster names: the **data plane announces** what it runs, the **type declares** what it needs.

- The fleet file's `addons` reach the cluster's `ClusterDataPlane` as annotations `addons.platform.koorikla.io/<addon>:
  "true"` (charts/cluster, same keys as the CAPI / Argo CD cluster labels the addon ApplicationSet selects on).
- Each type lists its needs in `platform.koorikla.io/requires-addons` (`keda`, `crossplane`).
- **Traits** check it themselves. OpenChoreo 1.3.3 exposes a data plane's annotations to component and trait CEL as
  `dataplane.annotations` (`internal/pipeline/component/context/types.go` `DataPlaneData.Annotations`; carried over for
  `ClusterDataPlane`s in `internal/controller/reference.go`), so `keda-scaler`'s first `preRenderValidation` fails the
  ReleaseBinding of an environment whose data plane lacks `keda` with a message naming the fleet-file switch. An
  environment can also turn the trait off (`traitEnvironmentConfigs.<instance>.enabled: false`).
- **Resource types** cannot: 1.3.3 gives `ResourceType`s no validations, and the resource pipeline's `dataplane.*` has
  only `secretStore`, `gateway` and `observabilityPlaneRef` (`internal/pipeline/resource/types.go`). The Kyverno
  `ValidatingPolicy` `platform-data-plane-capabilities` on mgmt (addon kyverno-policies) denies a
  `ResourceReleaseBinding` whose Resource's type requires an addon the environment's data plane does not announce;
  Argo CD shows the denial on the app's sync. A binding of a Resource that does not exist yet is denied too (apply the
  Resource in an earlier sync wave; Argo CD retries).
- Why not an environment allow list: 1.3.3's `Environment` has only `dataPlaneRef`, `isProduction` and `gateway`, and
  `allowedTraits` is per component type, cluster-wide. A list of environment names per type would restate what the fleet
  file already says about the cluster, and drift when an environment moves. The capability belongs to the data plane.
- Backstop: on a data plane without the CRD the apply fails anyway (`no matches for kind`).

### Readiness and replicas

- OpenChoreo's RenderedRelease health knows Deployments, StatefulSets, Pods and CronJobs; any other kind is healthy as
  soon as it exists (`internal/controller/renderedrelease/controller_status.go`, `getUnknownResourceHealth`). The
  `postgresql` type therefore sets `readyWhen` on the XR's `Ready` condition, and its `host` / `port` outputs read the
  XR status (`applied.postgresql.status.endpoint` / `.port`), so `OutputsResolved` waits for the backend too. A
  consumer's ReleaseBinding stays not synced (`ResourceDependenciesReady`) until the `ResourceReleaseBinding` is Ready:
  the workload never starts without its database. A `ScaledObject` counts as healthy when present (KEDA's own `Ready`
  condition is not consulted).
- The cluster agent applies every rendered object with server-side apply, `ForceOwnership`, field manager
  `renderedrelease-controller` (`internal/controller/renderedrelease/controller.go`). `keda-scaler` removes
  `/spec/replicas` from the rendered Deployment (like upstream's `horizontal-pod-autoscaler` trait), so that manager no
  longer owns the field; KEDA's HPA writes it through the scale subresource and later applies leave it alone. Argo CD
  does not run on data planes, so nothing else fights over it.

## PostgreSQL as a service

One developer-facing API, `platform.koorikla.io/v1alpha1` `PostgreSQL` (a namespaced Crossplane v2 composite resource,
no claims), fulfilled by whatever the cluster has: **CloudNativePG** in-cluster where there is no managed database
(local docker, Hetzner, Talos on vSphere), **Amazon RDS / Aurora** on AWS, **Cloud SQL** on GCP, **Azure Database for
PostgreSQL Flexible Server** on Azure. Developers ask for "a Postgres"; the cluster's provider decides how. Design and
owner decisions: [#91](https://github.com/koorikla/platform/issues/91).

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

Every field has a default: `spec: {}` gives PostgreSQL 17, size S, 10 GiB, one instance, no backups, database `app`.
`engine: aurora` (aws-rds only, default `postgres`) picks Aurora PostgreSQL instead of an RDS instance; other backends
ignore it.

What the app gets, on every backend: Secret **`<name>-app`** in the XR's namespace with the keys `host`, `port`,
`dbname`, `username`, `password` and `uri` (`postgresql://...`; the cloud backends add `?sslmode=require`). CNPG's
operator Secret has a few more (`jdbc-uri`, `pgpass`, ...); only the six are the contract. The XR reports it:

```
kubectl -n demo get postgresql orders-db     # BACKEND, ENDPOINT, SECRET, READY
```

`status.backend`, `status.endpoint`, `status.port`, `status.secretName`, `status.backup` (`enabled`, `disabled`, or
`unavailable` when asked for on a cluster without a backup target) and the `Ready` condition (all composed resources
ready). On cloud backends `secretName` appears once the database exists (minutes); bind env vars with `secretKeyRef`.
Apps on OpenChoreo get the XR through the resource type `postgresql` ([below](#postgresql-from-openchoreo)).

Rules enforced at admission (Kyverno `ValidatingPolicy`, also emitted as native `ValidatingAdmissionPolicy`):

- **Only through the XR.** Raw CNPG objects (`Cluster`, `Pooler`, `Database`, `Backup`, `ScheduledBackup`,
  `Publication`, `Subscription`, Barman `ObjectStore`) and the RDS / EC2 / KMS / Cloud SQL / Flexible Server managed
  resources are denied outside `crossplane-system` and `cnpg-system` unless a ServiceAccount of `crossplane-system`,
  `cnpg-system` or `kube-system` makes the request (Crossplane composing, providers, the CNPG operator, the garbage
  collector). Lists: addon crossplane `policy.exemptNamespaces`, `policy.exemptServiceAccountNamespaces`.
- **Production is HA and backed up.** XRs in OpenChoreo cells labelled `openchoreo.dev/environment: production` must
  set `highAvailability: true` and `backup.enabled: true` (Deny; Audit on local docker clusters, which have neither an
  object store nor more than one node).

### PostgreSQL from OpenChoreo

Apps on OpenChoreo do not write the XR: they declare a `Resource` of `ClusterResourceType postgresql` in their app repo
(`deploy/openchoreo/`, synced by the tenant's Argo CD Application), bind it per environment and wire its outputs into
the Workload. OpenChoreo renders the XR into the environment's cell namespace (name `<resource>-<env>-<hash>`), so the
connection Secret `<that name>-app` sits next to the workload.

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
spec:
  owner: { projectName: demo, resourceName: orders-db }
  environment: development
  resourceRelease: orders-db-6c9d7b8f4                   # from: kubectl get resource orders-db -o jsonpath='{.status.latestRelease.name}'
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

`host`, `port` and `database` arrive as plain env values (from the XR status), `username`, `password` and `uri` as
`secretKeyRef`s to `<name>-app`: the credentials never leave the data plane. OpenChoreo 1.3.3 has no auto-deploy for
Resources: a binding stays `ResourceReleaseNotSet` until `resourceRelease` names a release. The release name is a
deterministic hash of the type's spec and the parameters (stable across a clean bootstrap); a platform change to the
type cuts a new release, which an app adopts by bumping the pin. Every environment the component is promoted to needs
its own binding (the Workload's dependency is shared): ReleaseBindings there wait for it. Production bindings belong in
`release-bindings/production.yaml` (gated Application, reviewed pull request, docs/promotion.md) and must ask for
`highAvailability: true` and `backup: { enabled: true }` (policy above).

### Operator view

Opt in per cluster (fleet file); CNPG clusters also need the operator:

```
# installations/<inst>/clusters/<name>.yaml
addons:
  crossplane: true
  cloudnative-pg: true      # only where the backend is cnpg
```

**Backend selection, no developer input.** The addon ApplicationSet passes the cluster's provider label
(`platform.koorikla.io/provider`, from the fleet file `provider`) as `cluster.provider`; addon crossplane maps it
(`postgresql.backendByProvider`) and installs only that backend's Composition, `postgresql-<backend>`, as the XRD's
`defaultCompositionRef`, plus only the provider family members it composes:

| Provider fact | Backend / Composition | Crossplane providers (xpkg.crossplane.io/crossplane-contrib, pinned by digest) |
|---|---|---|
| `docker`, `hetzner`, `vsphere-talos` | `postgresql-cnpg` | none |
| `aws`, `aws-eks` | `postgresql-aws-rds` | `provider-family-aws`, `provider-aws-rds`, `provider-aws-ec2`, `provider-aws-kms` |
| `gcp-gke` | `postgresql-gcp-cloudsql` | `provider-family-gcp`, `provider-gcp-sql` |
| `azure-aks` | `postgresql-azure-flexible` | `provider-family-azure`, `provider-azure-dbforpostgresql` |

A provider missing from the map fails the render. `postgresql.backend` forces a backend for one cluster (e.g. cnpg on a
cloud cluster). A `ManagedResourceActivationPolicy` activates only the managed resources the Composition composes
(`provider.defaultActivations` is empty), so each provider installs a handful of CRDs, not its whole family.

What each Composition creates (pipeline: function-go-templating, then function-auto-ready):

| Backend | Composed | Connection Secret | HA | Backup |
|---|---|---|---|---|
| cnpg | `Cluster` (image from ClusterImageCatalog `postgresql-standard` of addon cloudnative-pg by major), `PodMonitor` | the operator's `<name>-app` | 3 instances | Barman Cloud `ObjectStore` + daily `ScheduledBackup` under `postgresql.cnpg.backup.destinationPath`/`<cluster>/<ns>/<name>` |
| aws-rds | KMS `Key`, `SecurityGroup` + ingress 5432 from the node security group, `SubnetGroup`, RDS `Instance` (or Aurora `Cluster` + `ClusterInstance`s) | ExternalSecret from the RDS-managed master secret in Secrets Manager (`manageMasterUserPassword`), store `default` | Multi-AZ instance (Aurora: + reader in another AZ) | automated backups, `retentionDays` |
| gcp-cloudsql | `DatabaseInstance` (private IP only, TLS required, IAM DB auth flag), `Database`, `User` | ExternalSecret with an ESO `Password` generator, once the private IP is known | `REGIONAL` | backups + PITR |
| azure-flexible | `FlexibleServer` (delegated subnet, private DNS zone, no public access, Entra + password auth), `FlexibleServerDatabase` | ExternalSecret with an ESO `Password` generator (the server needs the password at creation) | zone-redundant | `retentionDays` (Azure keeps >= 7) |

Passwords never pass through Crossplane's function pipeline: CNPG and RDS generate them; on GCP / Azure ESO generates
one into the connection Secret (generated once; deleting the Secret rotates it) and the provider reads it from there to
set it on the user. Cloud identifiers are `pg-<namespace>-<name>-<hash of cluster/namespace/name>`. The cloud backends'
`username` is the owner/master role; least-privilege per-app roles: [#107](https://github.com/koorikla/platform/issues/107).

**Cluster facts** (values only, `installations/<inst>/addons/crossplane/{values,cluster-<name>}.yaml`; a missing
required fact fails the render): `postgresql.aws` (`vpcId`, two or more private `subnetIds`, `nodeSecurityGroupId`,
`identity.source` IRSA with `roleArn` or PodIdentity), `postgresql.gcp` (`project`, `privateNetwork` with private
services access, optional `allocatedIpRange`, `identity.serviceAccount`), `postgresql.azure` (`subscriptionID`,
`tenantID`, `clientID`, `resourceGroupName`, `delegatedSubnetId`, `privateDnsZoneId`), `postgresql.cnpg.backup`
(object store prefix, credentials, ServiceAccount annotations; needs `plugin-barman-cloud.enabled: true` in addon
cloudnative-pg). Example: `installations/aws-example/addons/crossplane/values.yaml`.

**Credentials: workload identity only.** Each family's providers share ServiceAccount `crossplane-system/provider-<cloud>`
(DeploymentRuntimeConfig `provider-<cloud>`): IRSA role annotation or an EKS Pod Identity association, GKE Workload
Identity, Entra workload identity (`azure.workload.identity/use` + client id). `ClusterProviderConfig/default` uses that
identity (`IRSA` / `PodIdentity`, `InjectedIdentity`, `OIDCTokenFile`); there is no static key anywhere. On AWS the
identity of `ClusterSecretStore/default` must be allowed to read the RDS-managed secrets (`rds!*`); as the tenant store,
every tenant on that cluster can then reference them.

**Deletion.** `deletionPolicy: Retain` (default) gives the cloud resources `managementPolicies` without `Delete`
(Crossplane v2 managed resources have no `deletionPolicy`) and turns on the cloud's deletion protection: deleting the XR
leaves the database. `Delete` removes it (with a final snapshot when backups are on). CNPG data lives in PVCs owned by
the `Cluster` and goes with the XR either way: keep backups on.

**Packaging.** XRD, Compositions, Functions and providers are templates of the wrapper chart, not a Crossplane
Configuration package: the Composition embeds per-cluster facts and the XRD's default Composition depends on the
cluster's provider, which one immutable OCI package cannot express without its own build / sign / promote pipeline; the
chart renders per cluster through the addon ApplicationSet and is tested like every addon. Crossplane runs on each
workload cluster (owner decision in #91): the XR lives next to the app, uses that cluster's workload identity, and needs
no cross-cluster Secret delivery.

**Pod Security.** crossplane-system enforces `restricted`. Crossplane's default package runtime sets neither a seccomp
profile nor a capability drop, so every Function and Provider runs under DeploymentRuntimeConfig `restricted` /
`provider-<cloud>` (seccomp `RuntimeDefault`, drop `ALL`, non-root, read-only root filesystem). Core and RBAC manager
get the same through the chart values. Metrics: PodMonitor for core + RBAC manager. Footprint (requests): core 50m /
128Mi, RBAC manager 10m / 64Mi, each Function 10m / 64Mi, each provider 50m / 256Mi.

**Tests (offline).** `hack/tests/test_crossplane_render.sh`: the ApplicationSet render for dev1 selects
`postgresql-cnpg`; every backend's addon render passes kubeconform with the Crossplane and provider CRD schemas and pins
every package; `crossplane render` (CLI from `mise.toml`, the addon's own Crossplane image and Function packages, needs
Docker) of each Composition with the XRs and observed states in `hack/tests/crossplane/` checks the composed resources
(kubeconform), HA / backup / deletion / Aurora mapping, the identical Secret shape and that no composed object carries a
password. The renders share one Docker network and one container per Function per run (removed on exit, or by the next
run when a run was killed), so concurrent runs on one Docker host do not exhaust its network address pools; at most
`XP_RENDER_JOBS` (default 4) render at once. Admission: `hack/tests/test_kyverno_policies.sh`. Chart:
`addons/crossplane/tests`. Live checks: [#107](https://github.com/koorikla/platform/issues/107).

## PostgreSQL (CloudNativePG)

One instance (development); `instances: 3` gives a primary + two streaming replicas with automated failover.

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
9187, queries from ConfigMap `cnpg-default-monitoring`) need a PodMonitor per cluster (the operator's own
`spec.monitoring.enablePodMonitor` is deprecated upstream):

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

Current upstream path: the **Barman Cloud plugin** (CNPG-I), not the deprecated in-tree `spec.backup.barmanObjectStore`.
Switch it on per installation (`installations/<inst>/addons/cloudnative-pg/values.yaml`:
`plugin-barman-cloud: { enabled: true }`); it runs next to the operator in cnpg-system with cert-manager certificates.
Credentials come from **workload identity**, never static keys: the backup sidecar runs under the PostgreSQL cluster's
ServiceAccount (same name as the `Cluster`), so bind that identity to a role that may write the bucket prefix - EKS
Pod Identity association or IRSA (`spec.serviceAccountTemplate` annotation `eks.amazonaws.com/role-arn`), GKE Workload
Identity, Azure Workload Identity.

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

Hetzner object storage has no workload identity: there the S3 key pair is the one exception, delivered by an
ExternalSecret from ClusterSecretStore `default` and referenced from `s3Credentials.accessKeyId`/`secretAccessKey`.
Local docker clusters keep no backups. Restores bootstrap a new `Cluster` with `bootstrap.recovery.source` pointing at
an `externalClusters` entry that uses the same plugin and ObjectStore.

## Kafka (Strimzi)

Strimzi 1.x runs Kafka in KRaft mode only: node pools carry the `controller` and/or `broker` roles, there is no
ZooKeeper section, and the `kafka.strimzi.io/v1` API needs no feature annotations. Smallest useful cluster (one
combined node, development):

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
exporter) plus a PodMonitor selecting `strimzi.io/cluster: <name>`. The operator generates a NetworkPolicy per listener
(enforced by Cilium, and by k3s's embedded policy controller on flannel clusters).

## KEDA and OpenChoreo workloads

A `ScaledObject` targets a Deployment; KEDA then owns an HPA `keda-hpa-<name>` and scales 0 <-> 1 itself. Outside
OpenChoreo (platform namespaces, a dev cluster) write one directly:

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

Ownership rules on OpenChoreo-rendered Deployments:

- **Use the `keda-scaler` trait**, not a hand-written ScaledObject: app repos cannot sync KEDA objects (tenant
  AppProject), and the trait also removes `spec.replicas` from the rendered Deployment. Without that, the component
  types' `replicas: ${environmentConfigs.replicas}` would be re-applied by the cluster agent and reset what KEDA scaled
  to ([above](#readiness-and-replicas)).
- **One autoscaler per Deployment.** `keda-scaler` refuses to render next to the `horizontal-pod-autoscaler` trait (a
  `postRenderValidation`); KEDA's admission webhook would reject the ScaledObject anyway.
- **Triggers** are KEDA scalers as in the KEDA docs (`type`, `metadata` strings, optional `name`, `metricType`,
  `authenticationRef`). `authenticationRef` names a `TriggerAuthentication` in the cell namespace; the platform offers
  no `ClusterTriggerAuthentication` to tenants (it would hand them platform credentials).

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

The rendered ScaledObject is `<component>-<env>-<hash>-<instanceName>` next to the Deployment; KEDA owns an HPA
`keda-hpa-<that name>`.

- **Istio ambient.** Cell namespaces are ambient-enrolled and refuse plaintext (`STRICT`,
  [networking.md](networking.md#strict-mtls-in-cell-namespaces)), so the operator namespaces `keda`, `strimzi` and
  `cnpg-system` are mesh clients too (namespace label `istio.io/dataplane-mode: ambient`, `namespace.ambient` in each
  addon): the CNPG operator reaches instance pods (`:8000`), the Strimzi operator the brokers, KEDA its scaler
  endpoints (Kafka bootstrap, Prometheus, an app's metrics URL) over HBONE mTLS. Verified live with CNPG; Strimzi and
  KEDA follow the same path (VERIFY). The Prometheus agent stays outside the mesh, so a PostgreSQL cluster's
  per-cluster PodMonitor (`:9187`) in a STRICT cell is refused
  ([networking.md](networking.md#strict-mtls-in-cell-namespaces), exceptions). An app's metrics URL on a component pod is also behind OpenChoreo's per-component NetworkPolicy (same cell
  and system components only). Pod CPU/memory targets are exact in ambient (no sidecar inflating the pod's usage).
  The kube-apiserver -> KEDA metrics apiserver and admission webhook paths come from outside the mesh and stay
  accepted (no `PeerAuthentication` in the operator namespaces). Scaled to zero, requests to the component fail until
  KEDA scales it up (no HTTP activator; the KEDA HTTP add-on is not installed).

## Verify on a cluster

```
kubectl --context <dev1> -n cnpg-system get deploy cnpg                      # operator Ready
kubectl --context <dev1> -n demo get clusters.postgresql.cnpg.io orders-db   # STATUS "Cluster in healthy state"
kubectl --context <dev1> -n strimzi get deploy strimzi-cluster-operator
kubectl --context <dev1> -n demo get kafka events                            # READY True
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
