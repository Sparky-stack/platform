# obi

## Purpose

Wrapper chart for OpenTelemetry eBPF Instrumentation (`0.16.1` / `v1.0.0`) on workload clusters. Captures zero-code L7 RED metrics and traces for OpenChoreo `dp-*` cell namespaces via eBPF and exports OTLP HTTP to the node-local `telemetry` collector.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: obi`).
- **Catalog label:** `addons.platform.koorikla.io/obi` (`default: false`, opt-in with `"true"` per cluster via `addons.obi: true`).

## Key values

- `opentelemetry-ebpf-instrumentation.config.data.extensions.obi.capture.rules`: includes processes in `dp-*` namespaces while excluding collectors and apps already exporting OTLP on `:4317`.
- `opentelemetry-ebpf-instrumentation.config.data.meter_provider.readers`: pushes OTLP HTTP to `http://${HOST_IP}:4318`.
- `opentelemetry-ebpf-instrumentation.image.tag`: `v1.0.0` pinned by multi-arch index digest.

## Day-2 notes

- Verifying L7 metrics and collector ingestion: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Observability: OBI](../../docs/observability.md#obi)
