# Installation `gcp-example`

> **Untested example.** This lab runs on Docker + k3s/CAPD only. This installation renders and passes the schema checks
> in `task test`, but it has never been booted: no GCP account is wired up. Treat it as a reference, not as a
> supported path ([#87](https://github.com/koorikla/platform/issues/87)).

What it shows: GKE clusters created by CAPG (provider `gcp-gke`, ClusterClass `gke-managed`), Workload Identity Federation only. Only the infrastructure layer differs from `installations/local` (CNI, CSI/StorageClass, cloud
controller manager, load balancer, node image); the developer-facing platform is the same
([portability.md](../../docs/portability.md)).

- Setup and open checks: [providers.md](../../docs/providers.md#gke-capg---untested-example)
- Cluster files: `installations/gcp-example/clusters/`
- Bring an existing cluster instead of creating one: `provider: byo`
  ([providers.md](../../docs/providers.md#bring-your-own-cluster-byo))
