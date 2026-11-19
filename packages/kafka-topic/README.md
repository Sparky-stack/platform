# kafka-topic: Crossplane Configuration package

**Status: layout** (#241) - not installed on any cluster, not live-tested. The `strimzi` backend renders offline in
CI; cloud backends are skeletons. Enable + live proof: follow-up issue.

The platform's Kafka topic API (`platform.koorikla.io/v1alpha1 KafkaTopic`, namespaced XR): a topic on the cluster's
Kafka plus credentials allowed to use only that topic. Same layout as [`packages/postgresql`](../postgresql/README.md)
and [docs/crossplane.md](../../docs/crossplane.md): XRD + one
Composition `kafka-topic` (environment-configs -> embedded function `compose-kafka-topic` -> auto-ready) reading
`$facts.backend` from the EnvironmentConfig `platform-kafka-topic`. `functions/compose-kafka-topic/` is Helm-style, one
template per composed object: `00-prelude.yaml.gotmpl` (facts, backend check, derived values), shared objects
`1x-*`, per-backend objects `<backend>-<object>.yaml.gotmpl` (render only on that backend), `90-xr-status`.
Render tests pin the upstream Functions like the addon (`tests/render/functions.yaml`); `validate-render.sh`
builds the project and adds the embedded function (package-derived name) for the render.

## Developer contract

| Field | Default | Meaning |
|---|---|---|
| `partitions` | `3` | grows, never shrinks |
| `retentionHours` | `168` | record retention |
| `cleanupPolicy` | `delete` | `compact` keeps the latest record per key |
| `deletionPolicy` | `Retain` | keep the topic when the XR goes |

Topic name on the broker: `<namespace>.<name>` (`status.topic`; Event Hubs: `<name>`). Connection Secret
`<name>-kafka-topic`, same keys on every backend: `bootstrapServers`, `topic`, `securityProtocol`, `saslMechanism`,
`username`, `password`. Locally a SCRAM-SHA-512 user (ACLs: this topic, consumer groups prefixed with it); in cloud
`username` / `password` are empty and the app authenticates with its workload identity (`AWS_MSK_IAM` /
`OAUTHBEARER`).

## Backends

| `backend` | Composes | Facts |
|---|---|---|
| `strimzi` | Strimzi `KafkaTopic` + `KafkaUser` (SCRAM, simple ACLs), ESO `Password` + `ExternalSecret` | `kafkaCluster`, `bootstrapServers`, `replicationFactor` |
| `aws-msk` | Secret only: upjet has no MSK topic kind (VERIFY / follow-up) | `bootstrapServers` |
| `gcp-managedkafka` | Secret only: no upjet Managed Service for Apache Kafka family yet (VERIFY / follow-up) | `bootstrapServers` |
| `azure-eventhubs` | `eventhub.azure.m.upbound.io EventHub` in the cluster's Event Hubs namespace (Kafka endpoint) | `resourceGroupName`, `eventhubNamespace` |

## Local operator choice: Strimzi

Strimzi (CNCF incubating) is already the platform's Kafka operator (`addons/strimzi`, KRaft, `watchAnyNamespace`), so
no new operator. Open design point (VERIFY): Strimzi's Topic and User Operators each watch one namespace, and a
namespaced XR composes into its own namespace - topics in app namespaces need standalone Topic/User Operators per
namespace (or a Kafka cluster per namespace). Decide with the enable issue.

## VERIFY (before enabling)

- Strimzi: watched-namespace design above, SCRAM listener port in `bootstrapServers`, `kafka.strimzi.io/v1` field
  names, aggregated RBAC for `KafkaTopic` / `KafkaUser`.
- Cloud: MSK / GCP topic creation path, Event Hubs role assignment for the app identity, field names.
- OpenChoreo: `openchoreo/cluster-resource-type.yaml` is not deployed (see its header).
- Kyverno only-through-XR (deny raw `KafkaTopic` / `KafkaUser` in app namespaces): with the enable issue.

## Release and developer loop

As [`packages/postgresql`](../postgresql/README.md#release): `.github/workflows/package-kafka-topic.yaml`,
release-please component `kafka-topic`, image `ghcr.io/koorikla/platform/kafka-topic`.

```bash
PACKAGE_ROOT=packages/kafka-topic bash ci/scripts/crossplane/validate-render.sh   # UPDATE_EXPECTED=true to accept
```
