# Data services: PostgreSQL, Kafka, event-driven autoscaling

Three operators for workloads on workload clusters, **off by default** everywhere: a cluster runs them only after it
opts in, so local docker environments stay lean (no Application is generated for a cluster that does not opt in).
Catalog and labels: [conventions.md](conventions.md); addon mechanics: [architecture.md](architecture.md) "Addons".

| Addon (catalog) | Namespace | Upstream chart | What |
|---|---|---|---|
| `cloudnative-pg` | cnpg-system | `cloudnative-pg` 0.29.1 (operator 1.30.1) + optional `plugin-barman-cloud` 0.9.0 (v0.16.0) | PostgreSQL clusters (`Cluster`, `Pooler`, `ScheduledBackup`, `Database`); backups to object storage through the Barman Cloud plugin |
| `strimzi` | strimzi | `strimzi-kafka-operator` 1.3.1 | Apache Kafka in KRaft mode (`Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser`, Connect, MirrorMaker 2, Bridge); no ZooKeeper |
| `keda` | keda | `keda` 2.21.0 | event-driven autoscaling (`ScaledObject`, `ScaledJob`, `TriggerAuthentication`), scale to zero, external metrics API |

All three: wrapper charts in `addons/<addon>/`, workload role only, CRDs from the chart applied server-side by Argo CD
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
finalizer): CRDs, operators' data and the clusters they manage stay until removed deliberately.

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

Apps reach workload clusters only through OpenChoreo (no Argo CD there), so the native path is an OpenChoreo
`ClusterResourceType` that renders the operator CR into the cell namespace; components bind its outputs with
`Workload.spec.dependencies.resources[].envBindings`, as upstream's sample `postgres` resource type does with a plain
StatefulSet. A CNPG-backed type (sketch; not installed - it only works on data planes that opted in to the addon,
follow-up [#70](https://github.com/koorikla/platform/issues/70)):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterResourceType
metadata:
  name: cnpg-postgres
spec:
  parameters:
    openAPIV3Schema:
      type: object
      properties:
        database: { type: string, default: appdb }
  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        instances: { type: integer, default: 1, minimum: 1 }
        storageSize: { type: string, default: 1Gi }
  retainPolicy: Retain
  outputs:
    - name: host
      value: "${metadata.name}-rw.${metadata.namespace}.svc.cluster.local"
    - name: port
      value: "5432"
    - name: database
      value: "${parameters.database}"
    - name: username
      secretKeyRef: { name: "${metadata.name}-app", key: username }
    - name: password
      secretKeyRef: { name: "${metadata.name}-app", key: password }
    - name: url
      secretKeyRef: { name: "${metadata.name}-app", key: uri }
  resources:
    - id: cluster
      template:
        apiVersion: postgresql.cnpg.io/v1
        kind: Cluster
        metadata:
          name: ${metadata.name}
          namespace: ${metadata.namespace}
          labels: ${metadata.labels}
        spec:
          instances: ${environmentConfigs.instances}
          storage:
            size: ${environmentConfigs.storageSize}
          bootstrap:
            initdb:
              database: ${parameters.database}
              owner: ${parameters.database}
```

CNPG writes `<cluster>-app` (keys `username`, `password`, `host`, `port`, `dbname`, `uri`, `jdbc-uri`) next to the
cluster, so the password is generated on the data plane and never reaches the control plane. A Kafka type works the
same way (renders `KafkaNodePool` + `Kafka`, outputs `<name>-kafka-bootstrap.<ns>.svc:9092`; `KafkaUser` Secrets for
authenticated listeners). The examples below are what such types render; on a dev cluster you can also apply them
directly to try the operators.

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

A `ScaledObject` targets the Deployment OpenChoreo renders for a component (same name as the component, in its cell
namespace). KEDA then owns an HPA `keda-hpa-<name>` and scales 0 <-> 1 itself:

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

- **One autoscaler per Deployment.** Do not combine with the `horizontal-pod-autoscaler` trait: KEDA's admission
  webhook rejects a ScaledObject whose target already has an HPA (and two HPAs would fight).
- **`spec.replicas` must not be rendered.** OpenChoreo's component types render `replicas:
  ${environmentConfigs.replicas}` and the cluster agent re-applies it, resetting whatever KEDA scaled to. The
  `horizontal-pod-autoscaler` trait solves this with a patch that removes `/spec/replicas`; a KEDA trait needs the same.
  Sketch (not installed, [#70](https://github.com/koorikla/platform/issues/70)):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterTrait
metadata:
  name: keda-scaler
spec:
  parameters:
    openAPIV3Schema:
      type: object
      properties:
        minReplicas: { type: integer, default: 0, minimum: 0 }
        maxReplicas: { type: integer, default: 5, minimum: 1 }
        triggers:
          type: array
          items: { type: object, x-kubernetes-preserve-unknown-fields: true }
  creates:
    - template:
        apiVersion: keda.sh/v1alpha1
        kind: ScaledObject
        metadata:
          name: ${metadata.name}-${trait.instanceName}
          namespace: ${metadata.namespace}
          labels: ${metadata.labels}
        spec:
          scaleTargetRef:
            name: ${metadata.name}
          minReplicaCount: ${parameters.minReplicas}
          maxReplicaCount: ${parameters.maxReplicas}
          triggers: ${parameters.triggers}
  patches:
    - target:
        group: apps
        version: v1
        kind: Deployment
      operations:
        - op: remove
          path: /spec/replicas
```

- **Istio ambient.** Cell namespaces are ambient-enrolled; keda, strimzi and cnpg-system are not. Pod CPU/memory
  targets are exact in ambient (no sidecar inflating the pod's usage). The KEDA operator queries scaler endpoints
  (Kafka bootstrap, Prometheus, an app's metrics URL) as a non-mesh client: that works while the target accepts
  plaintext (ambient's default `PERMISSIVE`); with a `STRICT` PeerAuthentication enroll namespace keda in ambient
  (`istio.io/dataplane-mode: ambient`) or scale on a source outside the mesh. The same applies to the CNPG / Strimzi
  operators reaching instance pods in enrolled namespaces (VERIFY with STRICT). The kube-apiserver -> KEDA metrics
  apiserver and admission webhook paths are outside the mesh. Scaled to zero, requests to the component fail until
  KEDA scales it up (no HTTP activator; the KEDA HTTP add-on is not installed).

## Verify on a cluster

```
kubectl --context <dev1> -n cnpg-system get deploy cnpg                      # operator Ready
kubectl --context <dev1> -n demo get clusters.postgresql.cnpg.io orders-db   # STATUS "Cluster in healthy state"
kubectl --context <dev1> -n strimzi get deploy strimzi-cluster-operator
kubectl --context <dev1> -n demo get kafka events                            # READY True
kubectl --context <dev1> -n keda get apiservice v1beta1.external.metrics.k8s.io
```
