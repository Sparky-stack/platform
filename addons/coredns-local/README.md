# coredns-local

## Purpose

Renders k3s `coredns-custom` `ConfigMap` rules so pods inside local Docker (`k3d` and CAPD) clusters resolve `*.openchoreo.localhost` (and local observability/Harbor hosts on `mgmt`) to in-cluster Gateway Services or `k3d-platform-mgmt-serverlb`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, `providers: [docker]` (`namespace: kube-system`; layers `values/role-<role>.yaml`).
- **Catalog label:** `addons.platform.koorikla.io/coredns-local` (`default: true`, opt-out with `"false"`).

## Key values

- `openchoreo.controlPlane.host`: control-plane base domain (`openchoreo.localhost`).
- `rewrite.target`: `gateway-default.openchoreo-control-plane.svc.cluster.local` on `mgmt`; `k3d-platform-mgmt-serverlb` on CAPD workload clusters.
- `observabilityRewrite.target` and `registryRewrite.target`: optional `mgmt` CNAME rewrites for observability and Harbor (`registry.type: harbor`).

## Day-2 notes

- Debugging local agent or gateway DNS resolution: [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected).

## Links

- [OpenChoreo: Local networking](../../docs/openchoreo.md#local-networking)
