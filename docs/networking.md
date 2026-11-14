# Networking: Cilium CNI + Istio Ambient + Gateway API

Workload clusters run **Cilium 1.20.4** (eBPF CNI + kube-proxy replacement + WireGuard + Hubble), **Istio 1.30.6 Ambient** (sidecar-free L4 mTLS via `ztunnel` + `istio-cni`), and **kgateway v2.3.1** (Gateway API `v1.5.1` north-south ingress).

## Component division of responsibility
| Layer | Component | Scope | Addon / Wave |
|---|---|---|---|
| CNI, kube-proxy replacement, WireGuard, Hubble | Cilium `1.20.4` | Workload clusters (`kube-system`) | `addons/cilium` (`-15`) |
| Gateway API CRDs | Gateway API `v1.5.1` (standard) | mgmt + workload (`kube-system`) | `addons/gateway-api-crds` (`-6`) |
| Ingress controller (`GatewayClass/kgateway`) | kgateway `v2.3.1` | mgmt + workload (`kgateway-system`) | `addons/kgateway` (`-2`) |
| Service mesh (`istiod`, `istio-cni`, `ztunnel`) | Istio Ambient `1.30.6` | Workload clusters (`istio-system`) | `addons/istio-ambient` (`-3`) |

`mgmt` keeps its host CNI (k3d flannel locally; EKS/provider CNI in prod) and does not run Cilium or Istio.

## Cilium + k3s + Istio Ambient contracts
1. **k3s ClusterClass flags** (`addons/clusterclasses/templates/k3s-{docker,aws,hetzner}.yaml`):
   - `flannelBackend: none`, `disableNetworkPolicy: true`, `disableKubeProxy: true`.
   - `k3s-docker` cleans pre-baked `/etc/cni/net.d/*` and ensures `/sys/fs/bpf` is mounted `bpffs` with shared propagation.
   - `k3s-aws` opens node-to-node SG rules: `10250/tcp` (kubelet), `8472/udp` (VXLAN), `4240/tcp` (Cilium health), `4244/tcp` (Hubble peer), `51871/udp` (WireGuard).
   - `k3s-hetzner` leaves `MTU: 0` on Cilium so Cilium auto-detects the 1450-byte private network MTU minus VXLAN/WireGuard overhead.
2. **k3s embedded apiserver LB (`127.0.0.1:6444`)**:
   - Every k3s server and agent node runs k3s's local apiserver load balancer on `127.0.0.1:6444`.
   - `addons/cilium` sets `k8sServiceHost: "127.0.0.1"` and `k8sServicePort: 6444` so host-networked `cilium-agent` / `cilium-operator` bootstrap without kube-proxy or per-cluster VIP overrides.
3. **k3s CNI paths** (aligned across Cilium and Istio CNI):
   - CNI conf dir: `/var/lib/rancher/k3s/agent/etc/cni/net.d`
   - CNI bin dir: `/var/lib/rancher/k3s/data/cni`
   - Configured via `cilium.cni.{confPath,binPath}` and `istio-ambient.global.platform: k3s`.
4. **Cilium + Istio Ambient coexistence**:
   - `cilium.cni.exclusive: false` prevents Cilium from deleting `istio-cni` configs.
   - `cilium.socketLB.hostNamespaceOnly: true` limits Cilium socket-level LB to the host netns so pod traffic still traverses pod netns interception into `ztunnel`.
   - `cilium.bpf.masquerade` stays `false` (default) for clean compatibility with WireGuard + `ztunnel`.
   - `cilium.gatewayAPI.enabled: false` and `cilium.envoy.enabled: false` keep Cilium out of Gateway API (`kgateway` owns `GatewayClass/kgateway` and OpenChoreo's `Gateway/gateway-default`).
5. **Argo CD cleanliness**:
   - Cilium Hubble TLS uses `hubble.tls.auto.method: cronJob` (avoids random Helm-generated cert diffs on sync and works at wave `-15` before `cert-manager`).
   - Istio Ambient is pinned to `1.30.6` (supports Kubernetes `1.32-1.35`; `1.31.4`/`1.32.0` ship duplicate `inferencepools.inference.networking.k8s.io` CRDs in `base`) and sets `global.omitDefaultServiceAccountImporter: true` so `base` and `istiod` do not emit duplicate `ClusterRole/istio-reader-clusterrole-istio-system`.

## Observability
- `cilium` exposes Prometheus metrics on `cilium-agent` (`:9962`), `cilium-operator` (`:9963`), and Hubble OpenMetrics (`:9965`: `dns`, `drop`, `tcp`, `flow`, `port-distribution`, `icmp`, `httpV2`). `serviceMonitor.enabled` stays `false` so wave `-15` does not require Prometheus Operator CRDs.

## OpenChoreo ambient enrollment
- `addons/openchoreo-platform` keeps upstream `ClusterProjectType/default` verbatim and adds `ClusterProjectType/ambient`, which labels OpenChoreo-managed data-plane namespaces (`dp-<org>-<project>-<env>-*`) with `istio.io/dataplane-mode: ambient`.
- Tenants opt in by setting `clusterProjectType: ambient` in `installations/<inst>/tenants/<project>.yaml`.
- `kgateway-system` and `openchoreo-data-plane` (`Gateway/gateway-default`) stay outside ambient mode; `ztunnel` accepts traffic from `gateway-default` under Istio's default `PERMISSIVE` mTLS while enforcing HBONE mTLS between ambient workload pods.
