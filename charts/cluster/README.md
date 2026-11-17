# cluster

## Purpose

Onboards one workload cluster from `installations/<inst>/clusters/<name>.yaml`: renders its Cluster API topology `Cluster` (`k3s-<provider>`), Argo CD cluster secret (via ESO), OpenChoreo per-cluster agent CA/cert + `ClusterDataPlane` + `Environment`s, Falco escalation token, and optional multicluster mesh trust.

## Where it runs

- **Target:** `mgmt` cluster (`fleet`, `argocd`, and `openchoreo.orgNamespace`), rendered by `ApplicationSet/fleet` as `Application/cluster-<name>`.
- **Selection:** `provider: docker | aws | hetzner`, `role: workload` (stamped onto the CAPI `Cluster` and Argo CD cluster secret alongside `addons.platform.koorikla.io/<addon>`, `platform.koorikla.io/cni`, and `mesh.platform.koorikla.io/{group,network}`).

## Key values

- `name`, `provider`, `region`, `environment`, `kubernetesVersion`: cluster identity, `ClusterClass` (`k3s-docker`, `k3s-aws`, `k3s-hetzner`), and k3s version.
- `cni`: `cilium` or `flannel` (fixed at cluster creation; derives `addons.platform.koorikla.io/cilium`).
- `controlPlane.{replicas,machineType}`, `workers[]`, `providerSpec`: server count (odd; `>= 3` for cloud production), node pools, and provider variables.
- `openchoreo.dataPlane.{enabled,gatewayHost,gatewayPort,environments}`: registers the `ClusterDataPlane` and binds environments.
- `addons`, `addonsRevision`, `mesh.group`: per-cluster addon overrides, Git revision pin, and opt-in Istio ambient mesh membership.

## Day-2 notes

- Adding/removing clusters, worker scaling, and `1` vs `3` server HA: [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md) and [upgrades](../../docs/runbooks/upgrades.md).
- Unreachable clusters or disconnected agents: [incidents](../../docs/runbooks/incidents.md#cluster-unreachable) and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md).

## Links

- [Cluster API providers: Adding a cluster](../../docs/providers.md#adding-a-cluster)
- [OpenChoreo: Trust model](../../docs/openchoreo.md#trust-model)
- [Multicluster mesh](../../docs/multicluster.md)
