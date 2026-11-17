# strimzi

## Purpose

Wrapper chart for `strimzi-kafka-operator` (`1.3.1`) on workload clusters. Manages Apache Kafka (KRaft) clusters, `KafkaTopic`s, and `KafkaUser`s across all namespaces, with Prometheus `PodMonitor` scraping.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: strimzi`).
- **Catalog label:** `addons.platform.koorikla.io/strimzi` (`default: false`, opt-in with `"true"` per cluster via `addons.strimzi: true`).

## Key values

- `namespace.podSecurity`: `restricted` Pod Security admission label on namespace `strimzi`.
- `strimzi-kafka-operator.watchAnyNamespace`: `true` so dynamically created OpenChoreo cell namespaces are reconciled.
- `monitoring.podMonitor`: `true` (scrapes operator metrics via `addons/telemetry`).
- `strimzi-kafka-operator.{image,topicOperator.image,userOperator.image,kafkaInit.image}`: `1.3.1` pinned by multi-arch index digest.

## Day-2 notes

- Operator upgrades and workload cluster sizing: [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision) and [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md).

## Links

- [Data services: Kafka (Strimzi)](../../docs/data-services.md#kafka-strimzi)
