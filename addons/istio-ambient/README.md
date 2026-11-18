# istio-ambient

## Purpose

Wrapper chart for Istio Ambient (`1.32.0`: `base`, `istiod`, `cni`, `ztunnel`). Provides sidecarless mTLS (HBONE) and L4 authorization across workload clusters, with optional multi-network multicluster mesh support.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`; layers `values/cni-flannel.yaml` on flannel, `values/provider-gcp-gke.yaml` on GKE and `values/mesh-member.yaml` on mesh members).
- **Catalog label:** `addons.platform.koorikla.io/istio-ambient` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| base | object | `{}` |  |
| cni.cni.resources.limits.memory | string | `"256Mi"` |  |
| cni.cni.resources.requests.cpu | string | `"25m"` |  |
| cni.cni.resources.requests.memory | string | `"64Mi"` |  |
| cni.image | string | `"docker.io/istio/install-cni:1.32.0-distroless@sha256:bf8fa30fe56fc7209941af23999f1463071b9885c22ec81f5998645718698787"` |  |
| cni.profile | string | `"ambient"` |  |
| global.istioNamespace | string | `"istio-system"` | Istio namespace (`global.{multiCluster.clusterName,meshID,network}` are populated from cluster labels; `global.platform` is `k3s` in `values/cni-flannel.yaml` and `gke` in `values/provider-gcp-gke.yaml`). |
| global.proxy.image | string | `"docker.io/istio/proxyv2:1.32.0-distroless@sha256:9cd1f1cc261f3fe250ab483543e7256c39d5871eae5f1817c0809eff09e365d4"` |  |
| istiod.image | string | `"docker.io/istio/pilot:1.32.0-distroless@sha256:219ab7efcf1fd1f883086ad4a4a649c0e70bee3200423d6eef9f435103a79423"` |  |
| istiod.pilot.autoscaleEnabled | bool | `false` |  |
| istiod.pilot.resources.limits.memory | string | `"512Mi"` |  |
| istiod.pilot.resources.requests.cpu | string | `"50m"` |  |
| istiod.pilot.resources.requests.memory | string | `"128Mi"` |  |
| istiod.profile | string | `"ambient"` | `ambient` profile (with `cni.profile` and `ztunnel.profile`, distroless `1.32.0` images pinned by multi-arch index digest; `istiod.env.ENABLE_CA_SERVER` is `"false"` in `values/mesh-member.yaml`). |
| ztunnel.annotations."argocd.argoproj.io/sync-wave" | string | `"1"` |  |
| ztunnel.image | string | `"docker.io/istio/ztunnel:1.32.0-distroless@sha256:953a77fc17379301de4b7c6697b1668471c9c1f6ff912c9c5b78f454ab362180"` |  |
| ztunnel.podAnnotations | object | `{}` |  |
| ztunnel.profile | string | `"ambient"` |  |
| ztunnel.resources.limits.memory | string | `"512Mi"` |  |
| ztunnel.resources.requests.cpu | string | `"50m"` |  |
| ztunnel.resources.requests.memory | string | `"128Mi"` |  |

## Day-2 notes

- Rolling `istiod` and `ztunnel` safely: [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Networking](../../docs/networking.md)
- [Multicluster mesh](../../docs/multicluster.md)