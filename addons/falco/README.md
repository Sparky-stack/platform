# falco

## Purpose

Wrapper chart for Falco (`9.2.2` / `0.45.2`, modern eBPF), `falcosidekick` (`2.35.1`), and `falco-talon` (`0.5.0` / `0.3.0`). Detects runtime threats across `mgmt` and workload clusters, ships alerts to the telemetry collector on workload clusters, escalates `critical` alerts to `argo-events`, and runs Talon pod-level response actions in `dp-*` app namespaces.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: falco`; layers `values/role-mgmt.yaml` on `mgmt`).
- **Catalog label:** `addons.platform.koorikla.io/falco` (`default: true`, opt-out with `"false"`).

## Key values

- `falco.driver.kind`: `modern_ebpf` (`loader.enabled: false`).
- `falco.falcosidekick.config`: tags events with `cluster:<name>` (`clusterNameFormats`), forwards to `telemetry-collector` and `falco-talon`, and escalates `critical` events via `falcosidekick-escalation`.
- `escalation.{enabled,remoteKey}` and `slack.{enabled,remoteKey}`: pulls webhook secrets (`falco-webhook`, `falco-slack`) via ESO.
- `falco-talon.{enabled,config.rulesOverride}`: labels suspicious pods on app container shells and terminates pods matching crypto-miner rules.

## Day-2 notes

- Responding to critical Falco alerts and rotating webhook tokens: [incidents](../../docs/runbooks/incidents.md#falco-critical-alert) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

## Links

- [Observability: Falco](../../docs/observability.md#falco)
