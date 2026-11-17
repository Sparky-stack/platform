# kgateway

## Purpose

Wrapper chart for `kgateway-crds` and `kgateway` (`v2.3.1`). Implements Gateway API ingress for OpenChoreo control-plane, observability, and Harbor `Gateway`s on `mgmt` and workload data-plane `Gateway`s on workload clusters.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kgateway-system`).
- **Catalog label:** `addons.platform.koorikla.io/kgateway` (`default: true`, opt-out with `"false"`).

## Key values

- `kgateway.controller.image.tag`: `v2.3.1` pinned by multi-arch index digest.
- `kgateway.controller.resources`: sets CPU/memory requests (`50m` / `128Mi`) and a `512Mi` memory limit.

## Day-2 notes

- Upgrading `kgateway` alongside Gateway API CRDs and OpenChoreo: [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).
- Ingress triage on `mgmt` and workload clusters: [observability first look](../../docs/runbooks/observability-first-look.md).

## Links

- [Networking: Gateway API versions](../../docs/networking.md#gateway-api-versions)
- [OpenChoreo: Local networking](../../docs/openchoreo.md#local-networking)
