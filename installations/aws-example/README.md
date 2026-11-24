# Installation `aws-example`

> **Untested example.** This lab runs on Docker + k3s/CAPD only. This installation renders and passes the schema checks
> in `task test`, but it has never been booted: no AWS account is wired up. Treat it as a reference, not as a
> supported path ([#26](https://github.com/Sparky-stack/platform/issues/26)).

What it shows: CAPA k3s clusters (ClusterClass `k3s-aws`) on EC2, mgmt on any conformant cluster in the account (e.g. EKS). Only the infrastructure layer differs from `installations/local` (CNI, CSI/StorageClass, cloud
controller manager, load balancer, node image); the developer-facing platform is the same
([portability.md](../../docs/portability.md)).

- Setup and open checks: [providers.md](../../docs/providers.md#aws-capa---untested-example)
- Cluster files: `installations/aws-example/clusters/`
- Bring an existing cluster instead of creating one: `provider: byo`
  ([providers.md](../../docs/providers.md#bring-your-own-cluster-byo))
