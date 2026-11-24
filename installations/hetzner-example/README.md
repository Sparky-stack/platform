# Installation `hetzner-example`

> **Untested example.** This lab runs on Docker + k3s/CAPD only. This installation renders and passes the schema checks
> in `task test`, but it has never been booted: no Hetzner Cloud account is wired up. Treat it as a reference, not as a
> supported path ([#26](https://github.com/Sparky-stack/platform/issues/26)).

What it shows: CAPH k3s clusters (ClusterClass `k3s-hetzner`), mgmt on any conformant cluster. Only the infrastructure layer differs from `installations/local` (CNI, CSI/StorageClass, cloud
controller manager, load balancer, node image); the developer-facing platform is the same
([portability.md](../../docs/portability.md)).

- Setup and open checks: [providers.md](../../docs/providers.md#hetzner-cloud-caph---untested-example)
- Cluster files: `installations/hetzner-example/clusters/`
- Bring an existing cluster instead of creating one: `provider: byo`
  ([providers.md](../../docs/providers.md#bring-your-own-cluster-byo))
