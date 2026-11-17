# aws-ccm

## Purpose

Wrapper chart for `aws-cloud-controller-manager` (`0.0.12` / `v1.35.0`). Initializes AWS EC2 nodes, populates provider IDs and topology labels, and reconciles AWS LoadBalancers on `k3s-aws` workload clusters.

## Where it runs

- **Roles / providers:** `roles: [workload]`, `providers: [aws]` (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/aws-ccm` (`default: true`, opt-out with `"false"`).

## Key values

- `aws-cloud-controller-manager.args`: passes `--cloud-provider=aws` and `--configure-cloud-routes=false` (pod networking uses overlay VXLAN rather than VPC route tables).
- `aws-cloud-controller-manager.nodeSelector`: schedules on `node-role.kubernetes.io/control-plane: "true"` with `hostNetworking: true`.
- `aws-cloud-controller-manager.image`: `v1.35.0` pinned by multi-arch index digest.

## Day-2 notes

- Node readiness and cluster scaling on AWS: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Cluster API providers](../../docs/providers.md)
