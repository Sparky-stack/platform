# Portability

This repo is a local platform lab: Docker + k3s, workload clusters by Cluster API's Docker provider (CAPD). The
developer-facing platform is meant to run on any conformant Kubernetes. What changes from one infrastructure to another
is a thin layer underneath, and developers never see it. This page is the contract between the two.

## Two layers

| | Same everywhere (developer-facing) | Per provider (infrastructure) |
|---|---|---|
| What | OpenChoreo (control plane on mgmt, data plane agent per cluster), Argo CD (mgmt only), ESO + secret stores, Kyverno + policies, Backstage, build plane + Harbor, promotion gates, preview environments, cert-manager, kgateway (Gateway API), Falco, telemetry | node image / OS, CNI, CSI + default StorageClass, cloud controller manager, `Service type=LoadBalancer`, how nodes pull from the registry, cluster DNS, API endpoint + credentials |
| Defined by | the same charts and values for every cluster, selected by labels | the ClusterClass (CAPI clusters) or the cluster's owner (`provider: byo`), plus a few `values/provider-*.yaml` |
| Developers see | Components, Environments, ReleaseBindings, URLs | nothing |

Rule of thumb: if a developer or an app repo would have to know the provider, it belongs in the lower layer or in a
provider values file - never in a Component, a template or a tenant file.

## The infrastructure layer per provider

| Concern | `docker` (CAPD, tested) | `byo` (tested with k3d) | `aws`, `hetzner`, `gcp-gke` (untested examples) |
|---|---|---|---|
| Created by | mgmt, ClusterClass `k3s-docker` | its owner; mgmt only registers it | mgmt, ClusterClass `k3s-aws` / `k3s-hetzner` / `gke-managed` |
| Node image | `kindest/node` + k3s | anything conformant | Ubuntu + k3s / GKE node images |
| CNI | Cilium or flannel, chosen at birth | whatever it runs (fleet file `cni` is only a label) | Cilium or flannel / GKE VPC-native |
| CCM, load balancer | CAPD + k3s klipper | the owner's | `aws-ccm`, `hcloud-ccm` / Google |
| CSI / StorageClass | k3s local-path | the owner's default StorageClass | none yet (see [providers.md](providers.md)) |
| Registry pulls | k3s `registries.yaml` from the ClusterClass | the owner configures node trust/auth | ClusterClass / GKE node SA |
| Platform secrets and CAs | ClusterResourceSet payloads | PushSecrets (same objects) | ClusterResourceSet payloads |

Two backends are pluggable per installation rather than per cluster:

- **Secret backend** (`secrets.backend`): `kubernetes` + per-tenant OpenBao stores locally; AWS Secrets Manager or
  Vault/OpenBao in the examples. Everything consumes it through ESO, so apps never see the difference.
- **Mesh CA** (`mesh.ca`): locally OpenBao on mgmt signs each cluster's intermediate, and istio-csr on the workload
  cluster requests certificates through a cert-manager `Issuer` of type `vault`. Any cert-manager issuer can take that
  place - e.g. [aws-privateca-issuer](https://github.com/cert-manager/aws-privateca-issuer) (AWS Private CA),
  [google-cas-issuer](https://github.com/jetstack/google-cas-issuer) (Google CAS), or an existing Vault - without
  changing istio-csr, Istio or the apps. Only the OpenBao/Vault path is implemented and tested here; the istio-csr addon
  renders the `vault` Issuer today, so another backend means adding an issuer option to that one template.

Details and setup: [providers.md](providers.md) ([byo](providers.md#bring-your-own-cluster-byo)).

## How addons adapt

Every Argo CD cluster secret carries `platform.koorikla.io/{role,provider,cni,environment}` (labels flow from the
fleet file, [conventions.md](conventions.md#labels-and-annotations)). The addon ApplicationSets layer value files by
those labels - `values/role-<role>.yaml`, `values/provider-<provider>.yaml`, `values/cni-<cni>.yaml` - and the catalog
(`charts/platform/values.yaml`) can limit an addon to `providers: [...]`. The addons that differ today:

| Addon | Adapts by |
|---|---|
| `cilium` | only where the cluster was born with `cni: cilium` (never on byo, never on GKE) |
| `aws-ccm`, `hcloud-ccm` | catalog `providers: [aws]` / `[hetzner]` |
| `coredns-local` | catalog `providers: [docker, byo]`; off on byo except in `installations/local` (k3d on network `kind`) |
| `istio-ambient` | `values/provider-gcp-gke.yaml` (GKE profile), `values/cni-flannel.yaml` |
| `istio-eastwest` | `values/provider-aws.yaml` (NLB) |
| `crossplane` | `values/provider-docker.yaml` (production rule audits locally) |
| `external-secrets`, `secret-stores`, `openchoreo-data-plane`, `kyverno` | `values/provider-byo.yaml`: rebuild the ConfigMaps that CRS payloads deliver on CAPI clusters from the Secrets mgmt pushes |

Everything else renders identically on every workload cluster.

## Not portable yet

- byo clusters as mesh members, and with them per-tenant OpenBao secrets on byo
  ([#174](https://github.com/koorikla/platform/issues/174)).
- CSI drivers for the cloud examples (an addon per provider when one is booted).
- Cloud paths are untested: AWS and Hetzner ([#26](https://github.com/koorikla/platform/issues/26)), GKE
  ([#87](https://github.com/koorikla/platform/issues/87)).
