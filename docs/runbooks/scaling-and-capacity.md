# Runbook: Scaling and capacity

## When to use

Use this runbook to add or decommission a workload cluster, scale `MachineDeployment` worker pools, switch a workload cluster's control plane between `1` and `3` servers (HA mode), or shed memory and `inotify` pressure on a local host.

## Symptoms

- Workload pods sit `Pending` with `Insufficient cpu` or `Insufficient memory`, or node `kubectl top nodes` approaches capacity.
- A cloud or rollout-test cluster runs `controlPlane.replicas: 1` and needs `3`-voter `etcd` quorum safety.
- On a local developer host, `free -g` shows < 3 GiB available, swap I/O rises, `k3s` logs `leaderelection lost`, or kubelets fail with `too many open files` / `failed to create fsnotify watcher`.
- A new environment or region needs an isolated workload cluster, or an unused cluster needs clean decommissioning.

## Steps

### 1. Add a workload cluster

Adding a cluster is adding one fleet file `installations/<inst>/clusters/<name>.yaml` (schema: `charts/cluster/values.yaml`; [providers.md](../providers.md#adding-a-cluster)). Choose `cni` (`cilium` or `flannel`) before first boot: the CNI is fixed for the life of the cluster ([networking.md](../networking.md#cni-is-fixed-when-the-cluster-is-created)).

```bash
# 1. Validate the new fleet file offline (templates, kubeconform, label/secret contracts)
task lint
task test

# 2. Commit, open a PR to main, and merge; watch Argo CD and CAPI provision the cluster
kubectl --context k3d-platform-mgmt -n argocd get application cluster-<name>
kubectl --context k3d-platform-mgmt -n fleet get cluster,kthreescontrolplane,machines -l cluster.x-k8s.io/cluster-name=<name>

# 3. Once Provisioned, fetch its kubeconfig and check OpenChoreo registration
task kubeconfig CLUSTER=<name>
kubectl --kubeconfig <name>.kubeconfig get nodes
kubectl --context k3d-platform-mgmt get clusterdataplane <name>
```

### 2. Remove (decommission) a workload cluster

1. Move or remove any `openchoreo.dataPlane.environments` bound to `<name>` in a PR first so active tenant `ReleaseBinding`s are not stranded.
2. Delete `installations/<inst>/clusters/<name>.yaml` (or rename it to `*.yaml.disabled`, Invariant 7), run `task lint` and `task test`, and merge. Argo CD prunes `cluster-<name>`, CAPI drains and deletes the nodes, and deleting `<name>-agent-ca` revokes the plane's agent identity.
3. If `<name>` belonged to an Istio `mesh.group`, clean up the `ClusterResourceSet` objects that CAPI leaves behind ([multicluster.md](../multicluster.md#removing-a-member-decommissioning)):

```bash
# On each remaining member of the mesh group
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig -n istio-system delete secret istio-remote-secret-<name> --ignore-not-found

# On mgmt
kubectl --context k3d-platform-mgmt -n fleet delete secret <name>-mesh-reader --ignore-not-found
```

For tearing down the **entire** local stack (`dev1`, `prod1`, and `k3d-platform-mgmt`), run `task down` (it freezes Argo CD first so `selfHeal` cannot recreate `Cluster`s while CAPD deletes them).

### 3. Scale worker nodes (`MachineDeployment`)

Edit `workers[].replicas` (and `machineType` on `aws`/`hetzner`) in `installations/<inst>/clusters/<name>.yaml` (`replicas: 0` is valid because k3s control-plane servers schedule workloads by default).

```yaml
# installations/<inst>/clusters/<name>.yaml
workers:
  - name: md-0
    replicas: 2
```

Validate with `task lint`, merge to `main`, and watch CAPI scale the `MachineDeployment`:

```bash
kubectl --context k3d-platform-mgmt -n fleet get machinedeployment,machines -l cluster.x-k8s.io/cluster-name=dev1
```

### 4. Switch control-plane HA mode (`1` vs `3` servers)

`controlPlane.replicas` sets the number of k3s servers = embedded `etcd` voters (odd numbers only: `1`, `3`, `5`; cloud `production` clusters enforce `>= 3`; [providers.md](../providers.md#control-plane-size-and-rollouts)).

- **Scale `1 -> 3` (enable HA)**: set `controlPlane.replicas: 3` in `installations/<inst>/clusters/<name>.yaml` and merge. Two new servers join as `etcd` learners and promote to voters (~`1.6–2.5 GiB` host RAM per extra CAPD server). Subsequent rollouts proceed `3 -> 4 -> 3` with `KThreesControlPlane` auto-remediation active.
- **Scale `3 -> 1` (shed RAM locally)**: take a workload `etcd` snapshot first ([backup-restore.md](backup-restore.md)): shrinking `3 -> 2 -> 1` finishes with the unsafe `2 -> 1` `etcd` member removal.

```bash
kubectl --context k3d-platform-mgmt -n fleet get kthreescontrolplane dev1
kubectl --context k3d-platform-mgmt -n fleet get machines -l cluster.x-k8s.io/cluster-name=dev1,cluster.x-k8s.io/control-plane
```

### 5. Local RAM profiles and host limits

On a local host, `k3d-platform-mgmt` (~`8.3 GiB` RSS; observability plane ~`2.2 GiB` requests / ~`5 GiB` limits) plus two single-node CAPD clusters (`dev1` + `prod1`, ~`1.6–2.5 GiB` each; [observability.md](../observability.md#resource-budget-requests-local), [networking.md](../networking.md#footprint-per-workload-cluster-requests-1-node)) totals ~`16 GiB` RSS ([dev-environment.md](../dev-environment.md#local-stack-load-and-the-mgmt-datastore)).

```bash
# Check host memory/swap, container RSS, and Linux inotify limits
free -g
docker stats --no-stream --format 'table {{.Name}}	{{.CPUPerc}}	{{.MemUsage}}'
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
```

- **Raise `inotify` limits on Linux** (prevents kubelet/containerd `too many open files` across multiple `k3s` nodes; [forking.md](../forking.md#5-troubleshooting)):
  ```bash
  sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512
  ```
- **Single-workload-cluster lean profile ([#115](https://github.com/koorikla/platform/issues/115))** `(not yet verified live)`: to save ~`2 GiB` RAM in a fork while keeping all three environments (`development`, `staging`, `production`) and their Kyverno `Audit`/`Deny` policies (which match namespace label `openchoreo.dev/environment`, not cluster name), rename `installations/<inst>/clusters/prod1.yaml` to `prod1.yaml.disabled`, drop `mesh.group` from `dev1.yaml` (or keep `openbao` off), and move `production` to `installations/local/clusters/dev1.yaml` (`environments: [development, staging, production]`).

## Verify

```bash
# 1. Fleet clusters, control planes, and worker MachineDeployments match desired replicas and Ready state
task status
kubectl --context k3d-platform-mgmt -n fleet get clusters,kthreescontrolplanes,machinedeployments,machines

# 2. Node readiness and resource headroom inside the target workload cluster
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig get nodes -o wide
kubectl --kubeconfig dev1.kubeconfig top nodes
```

## Rollback

- **Worker or HA scale-out**: `git revert <commit>` to return `workers[].replicas` or `controlPlane.replicas` to its prior value (snapshot `etcd` before shrinking `3 -> 1`).
- **Decommissioned cluster**: `git revert <commit>` restores the fleet file so CAPI provisions a fresh cluster of the same name (stateful workload PVs are not restored unless backed up; kick stale `RenderedRelease`s if needed per [break-glass.md](break-glass.md)).
- **Single-server `etcd` quorum lost on `3 -> 1` shrink**: recover the surviving server with `--cluster-reset` ([break-glass.md](break-glass.md#single-server-etcd-quorum-loss)).

## Related links

- [Operations handbook](../operations.md)
- [Adding a cluster and control-plane rollouts](../providers.md#adding-a-cluster)
- [Networking and per-cluster footprint](../networking.md#footprint-per-workload-cluster-requests-1-node)
- [Observability resource budget](../observability.md#resource-budget-requests-local)
- [Local stack load and datastore](../dev-environment.md#local-stack-load-and-the-mgmt-datastore)
- [Removing a mesh member](../multicluster.md#removing-a-member-decommissioning)
- [Host troubleshooting](../forking.md#5-troubleshooting)
- [Backup and restore](backup-restore.md)
- [Break-glass](break-glass.md)
