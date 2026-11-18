# cilium

## Purpose

Wrapper chart for Cilium (`1.20.4`). Provides eBPF CNI networking, `kube-proxy` replacement, WireGuard node-to-node encryption, and Hubble flow telemetry on workload clusters created with `cni: cilium`.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/cilium` (`default: false`, set to `"true"` by `charts/cluster` when the fleet file sets `cni: cilium`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cilium.bpf.masquerade | bool | `false` |  |
| cilium.cni.exclusive | bool | `false` | `false` (with `socketLB.hostNamespaceOnly: true` and `bpf.masquerade: false`) for Istio ambient compatibility. |
| cilium.encryption.enabled | bool | `true` | Enables WireGuard (`type: wireguard`) node-to-node encryption. |
| cilium.encryption.type | string | `"wireguard"` |  |
| cilium.envoy.enabled | bool | `false` |  |
| cilium.gatewayAPI.enabled | bool | `false` |  |
| cilium.hubble.enabled | bool | `true` | Hubble Relay and OpenMetrics enabled. |
| cilium.hubble.metrics.enableOpenMetrics | bool | `true` |  |
| cilium.hubble.metrics.enabled[0] | string | `"dns"` |  |
| cilium.hubble.metrics.enabled[1] | string | `"drop"` |  |
| cilium.hubble.metrics.enabled[2] | string | `"tcp"` |  |
| cilium.hubble.metrics.enabled[3] | string | `"flow"` |  |
| cilium.hubble.metrics.enabled[4] | string | `"port-distribution"` |  |
| cilium.hubble.metrics.enabled[5] | string | `"icmp"` |  |
| cilium.hubble.metrics.enabled[6] | string | `"httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,source_pod,destination_ip,destination_namespace,destination_workload,destination_pod,traffic_direction"` |  |
| cilium.hubble.metrics.serviceMonitor.enabled | bool | `false` |  |
| cilium.hubble.relay.enabled | bool | `true` |  |
| cilium.hubble.relay.resources.limits.memory | string | `"128Mi"` |  |
| cilium.hubble.relay.resources.requests.cpu | string | `"25m"` |  |
| cilium.hubble.relay.resources.requests.memory | string | `"64Mi"` |  |
| cilium.hubble.tls.auto.enabled | bool | `true` |  |
| cilium.hubble.tls.auto.method | string | `"cronJob"` |  |
| cilium.hubble.tls.enabled | bool | `true` |  |
| cilium.hubble.ui.enabled | bool | `false` |  |
| cilium.ipam.mode | string | `"cluster-pool"` |  |
| cilium.ipam.operator.clusterPoolIPv4MaskSize | int | `24` |  |
| cilium.ipam.operator.clusterPoolIPv4PodCIDRList[0] | string | `"10.42.0.0/16"` |  |
| cilium.k8sServiceHost | string | `""` |  |
| cilium.k8sServicePort | int | `6443` |  |
| cilium.kubeProxyReplacement | bool | `true` | `true`, with `k8sServiceHost` and `k8sServicePort` populated per cluster from the Argo CD cluster secret (`clusterServerParameters`). |
| cilium.operator.prometheus.enabled | bool | `true` |  |
| cilium.operator.prometheus.serviceMonitor.enabled | bool | `false` |  |
| cilium.operator.replicas | int | `1` |  |
| cilium.operator.resources.limits.memory | string | `"256Mi"` |  |
| cilium.operator.resources.requests.cpu | string | `"50m"` |  |
| cilium.operator.resources.requests.memory | string | `"64Mi"` |  |
| cilium.prometheus.enabled | bool | `true` |  |
| cilium.prometheus.serviceMonitor.enabled | bool | `false` |  |
| cilium.resources.limits.memory | string | `"512Mi"` |  |
| cilium.resources.requests.cpu | string | `"100m"` |  |
| cilium.resources.requests.memory | string | `"128Mi"` |  |
| cilium.rollOutCiliumPods | bool | `true` |  |
| cilium.routingMode | string | `"tunnel"` | `tunnel` (`tunnelProtocol: vxlan`) with `ipam.mode: cluster-pool` (`10.42.0.0/16`). |
| cilium.socketLB.hostNamespaceOnly | bool | `true` |  |
| cilium.tunnelProtocol | string | `"vxlan"` |  |
| l7Visibility.enabled | bool | `false` | Optional L7 Envoy visibility (`l7Visibility.{enabled,httpPorts}`; `false` by default). |
| l7Visibility.httpPorts[0] | string | `"8080"` |  |

## Day-2 notes

- Inspecting dropped packets with Hubble and upgrading Cilium: [observability first look](../../docs/runbooks/observability-first-look.md#2-querying-prometheus-logs-and-hubble-directly) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Networking](../../docs/networking.md)