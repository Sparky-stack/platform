# hcloud-ccm

## Purpose

Wrapper chart for `hcloud-cloud-controller-manager` (`1.39.3`). Initializes Hetzner Cloud nodes, attaches topology metadata, and reconciles Hetzner LoadBalancers using the `kube-system/hcloud` secret populated by CAPH.

## Where it runs

- **Roles / providers:** `roles: [workload]`, `providers: [hetzner]` (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/hcloud-ccm` (`default: true`, opt-out with `"false"`).

## Key values

- `hcloud-cloud-controller-manager.networking.enabled`: `false` (overlay CNI routing by default).
- `hcloud-cloud-controller-manager.image`: `v1.39.3` pinned by multi-arch index digest.

## Day-2 notes

- Hetzner token rotation and cluster scaling: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets), [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md), and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Cluster API providers](../../docs/providers.md)
