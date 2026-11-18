# aws-ccm

## Purpose

Wrapper chart for `aws-cloud-controller-manager` (`0.0.12` / `v1.35.0`). Initializes AWS EC2 nodes, populates provider IDs and topology labels, and reconciles AWS LoadBalancers on `k3s-aws` workload clusters.

## Where it runs

- **Roles / providers:** `roles: [workload]`, `providers: [aws]` (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/aws-ccm` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| aws-cloud-controller-manager.args | list | `["--v=2","--cloud-provider=aws","--configure-cloud-routes=false"]` | Passes `--cloud-provider=aws` and `--configure-cloud-routes=false` (pod networking uses overlay VXLAN rather than VPC route tables). |
| aws-cloud-controller-manager.hostNetworking | bool | `true` |  |
| aws-cloud-controller-manager.image | object | `{"repository":"registry.k8s.io/provider-aws/cloud-controller-manager","tag":"v1.35.0@sha256:bf5a41be5f0dd5049cc1f69e1a23ff2691f2f46483546204676cea78796e75cd"}` | `v1.35.0` pinned by multi-arch index digest. |
| aws-cloud-controller-manager.nodeSelector | object | `{"node-role.kubernetes.io/control-plane":"true"}` | Schedules on `node-role.kubernetes.io/control-plane: "true"` with `hostNetworking: true`. |

## Day-2 notes

- Node readiness and cluster scaling on AWS: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Cluster API providers](../../docs/providers.md)