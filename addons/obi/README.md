# obi

## Purpose

Wrapper chart for OpenTelemetry eBPF Instrumentation (`0.16.1` / `v1.0.0`) on workload clusters. Captures zero-code L7 RED metrics and traces for OpenChoreo `dp-*` cell namespaces via eBPF and exports OTLP HTTP to the node-local `telemetry` collector.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: obi`).
- **Catalog label:** `addons.platform.koorikla.io/obi` (`default: false`, opt-in with `"true"` per cluster via `addons.obi: true`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| opentelemetry-ebpf-instrumentation.config.data.extensions.obi.capture.rules | list | `[{"action":"exclude","match":{"process":{"exe_path_glob":["{*/obi,obi,*ebpf-instrument*,*otelcol*,*otelcol-contrib*,*fluent-bit*}"]}},"name":"exclude-obi-and-collectors"},{"action":"exclude","match":{"process":{"exports_otlp":{"port":4317,"protocol":"protobuf"}}},"name":"exclude-otlp-exporters"},{"action":"include","match":{"kubernetes":{"namespace_glob":["dp-*"]},"process":{"exe_path_glob":["*"]}},"name":"include-openchoreo-app-namespaces"}]` | Includes processes in `dp-*` namespaces while excluding collectors and apps already exporting OTLP on `:4317`. |
| opentelemetry-ebpf-instrumentation.config.data.extensions.obi.version | string | `"2.0"` |  |
| opentelemetry-ebpf-instrumentation.config.data.meter_provider.readers | list | `[{"periodic":{"exporter":{"otlp_http":{"default_histogram_aggregation":"explicit_bucket_histogram","encoding":"protobuf","endpoint":"http://${HOST_IP}:4318"}},"interval":60000}}]` | Pushes OTLP HTTP to `http://${HOST_IP}:4318`. |
| opentelemetry-ebpf-instrumentation.fullnameOverride | string | `"obi"` |  |
| opentelemetry-ebpf-instrumentation.image.registry | string | `"ghcr.io"` |  |
| opentelemetry-ebpf-instrumentation.image.tag | string | `"v1.0.0@sha256:a68d70e934260f72540f157ccf4fb4adfa38f11de060d7d905696dad6a3fca02"` | `v1.0.0` pinned by multi-arch index digest. |
| opentelemetry-ebpf-instrumentation.preset | string | `"application"` |  |
| opentelemetry-ebpf-instrumentation.resources.limits.cpu | string | `"500m"` |  |
| opentelemetry-ebpf-instrumentation.resources.limits.memory | string | `"512Mi"` |  |
| opentelemetry-ebpf-instrumentation.resources.requests.cpu | string | `"50m"` |  |
| opentelemetry-ebpf-instrumentation.resources.requests.memory | string | `"128Mi"` |  |

## Day-2 notes

- Verifying L7 metrics and collector ingestion: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Observability: OBI](../../docs/observability.md#obi)