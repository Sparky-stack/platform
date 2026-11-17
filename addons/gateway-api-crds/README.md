# gateway-api-crds

## Purpose

Wrapper chart for `gateway-crds-helm` (`1.8.2`), installing Gateway API `v1.5.1` `standard`-channel CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`) required by `kgateway`, `cert-manager`, and OpenChoreo.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/gateway-api-crds` (`default: true`, opt-out with `"false"`).

## Key values

- `gateway-crds-helm.crds.gatewayAPI.{enabled,channel}`: `true` on the `standard` channel.
- `gateway-crds-helm.crds.envoyGateway.enabled`: `false` (Envoy Gateway CRDs are omitted; `kgateway` provides the Gateway controller).

## Day-2 notes

- Coordinating Gateway API CRD bumps with `kgateway` and OpenChoreo: [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Networking: Gateway API versions](../../docs/networking.md#gateway-api-versions)
