# coredns-local

## Purpose

Renders k3s `coredns-custom` `ConfigMap` rules so pods inside local Docker (`k3d` and CAPD) clusters resolve `*.openchoreo.localhost` (and local observability/Harbor hosts on `mgmt`) to in-cluster Gateway Services or `k3d-platform-mgmt-serverlb`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, `providers: [docker, byo]` (`namespace: kube-system`; layers `values/role-<role>.yaml`). On byo clusters `enabled: false` (`values/provider-byo.yaml`) unless the installation turns it on: `installations/local/addons/coredns-local/values.yaml` does, its byo k3d clusters share network `kind`.
- **Catalog label:** `addons.platform.koorikla.io/coredns-local` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| enabled | bool | `true` |  |
| observabilityRewrite.target | string | `""` | Optional `mgmt` CNAME rewrite for observability (alongside `registryRewrite.target` for Harbor when `registry.type: harbor`). |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` | Control-plane base domain (`openchoreo.localhost`). |
| openchoreo.observability.enabled | bool | `false` |  |
| registry.host | string | `""` |  |
| registry.type | string | `"external"` |  |
| registryRewrite.target | string | `""` |  |
| rewrite.target | string | `"k3d-platform-mgmt-serverlb"` | `gateway-default.openchoreo-control-plane.svc.cluster.local` on `mgmt`; `k3d-platform-mgmt-serverlb` on CAPD workload clusters. |

## Day-2 notes

- Debugging local agent or gateway DNS resolution: [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected).

## Links

- [OpenChoreo: Local networking](../../docs/openchoreo.md#local-networking)