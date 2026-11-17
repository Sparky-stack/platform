# cilium

## Purpose

Wrapper chart for Cilium (`1.20.4`). Provides eBPF CNI networking, `kube-proxy` replacement, WireGuard node-to-node encryption, and Hubble flow telemetry on workload clusters created with `cni: cilium`.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: kube-system`).
- **Catalog label:** `addons.platform.koorikla.io/cilium` (`default: false`, set to `"true"` by `charts/cluster` when the fleet file sets `cni: cilium`).

## Key values

- `cilium.{kubeProxyReplacement,k8sServiceHost,k8sServicePort}`: `true`, populated per cluster from the Argo CD cluster secret (`clusterServerParameters`).
- `cilium.{routingMode,tunnelProtocol,ipam.mode}`: `tunnel` (`vxlan`) with `cluster-pool` IPAM (`10.42.0.0/16`).
- `cilium.encryption`: `enabled: true`, `type: wireguard`.
- `cilium.{cni.exclusive,socketLB.hostNamespaceOnly,bpf.masquerade}`: `false` / `true` / `false` for Istio ambient compatibility.
- `cilium.hubble` and `l7Visibility.{enabled,httpPorts}`: Hubble Relay + OpenMetrics enabled; optional L7 Envoy visibility (`false` by default).

## Day-2 notes

- Inspecting dropped packets with Hubble and upgrading Cilium: [observability first look](../../docs/runbooks/observability-first-look.md#2-querying-prometheus-logs-and-hubble-directly) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Networking](../../docs/networking.md)
