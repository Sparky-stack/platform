# telemetry

## Purpose

Wrapper chart for workload data-plane telemetry: node-local OpenTelemetry Collector (`0.163.2`), Fluent Bit logs (`0.7.0`), Prometheus agent metrics (`0.8.0`), and Kubernetes events (`0.1.2`), shipping signals to `mgmt`'s observability plane (and optionally Datadog).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: telemetry`).
- **Catalog label:** `addons.platform.koorikla.io/telemetry` (`default: true`, opt-out with `"false"`).

## Key values

- `openchoreo.observability.{httpPort,tlsPort}` and `openchoreo.controlPlane.host`: `mgmt` ingestion endpoints for remote-write, OTLP, and OpenSearch.
- `secrets.{store,remoteKey}`: pulls `openchoreo-observability` credentials from workload `ClusterSecretStore/default`.
- `opentelemetry-collector.{mode,service.internalTrafficPolicy}`: `daemonset` with `Local` traffic policy on OTLP port `4317`.
- `datadog.{enabled,remoteKey,property}`: optional dual-shipping to Datadog (`false` by default).

## Day-2 notes

- Checking shipper readiness and the Prometheus agent active-series budget: [observability first look](../../docs/runbooks/observability-first-look.md#1-first-5-minute-triage-order-where-to-look-first).

## Links

- [Observability and runtime security](../../docs/observability.md)
