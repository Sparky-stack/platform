# istio-ambient

## Purpose

Wrapper chart for Istio Ambient (`1.32.0`: `base`, `istiod`, `cni`, `ztunnel`). Provides sidecarless mTLS (HBONE) and L4 authorization across workload clusters, with optional multi-network multicluster mesh support.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`; layers `values/cni-flannel.yaml` on flannel, `values/provider-gcp-gke.yaml` on GKE and `values/mesh-member.yaml` on mesh members).
- **Catalog label:** `addons.platform.koorikla.io/istio-ambient` (`default: true`, opt-out with `"false"`).

## Key values

- `istiod.profile`, `cni.profile`, `ztunnel.profile`: `ambient`, with distroless `1.32.0` images pinned by multi-arch index digest.
- `global.{multiCluster.clusterName,meshID,network}`: populated from cluster name and `mesh.platform.koorikla.io/{group,network}` labels.
- `istiod.env.ENABLE_CA_SERVER` (`values/mesh-member.yaml`): `"false"` on mesh members (`istio-csr` + OpenBao sign certs instead).
- `global.platform` (`values/cni-flannel.yaml`): `k3s` so `istio-cni` chains into k3s's flannel CNI paths; `gke` on `gcp-gke` (`values/provider-gcp-gke.yaml`).

## Day-2 notes

- Rolling `istiod` and `ztunnel` safely: [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Networking](../../docs/networking.md)
- [Multicluster mesh](../../docs/multicluster.md)
