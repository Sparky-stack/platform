# Day-2 operations handbook

Operational index and runbooks for running, upgrading, backing up, and recovering the platform after `task up`. Design rationale lives in [architecture.md](architecture.md); contracts and naming rules live in [conventions.md](conventions.md).
Day-2 diagrams: [cluster lifecycle](diagrams/cluster-lifecycle.svg), [trust & certificates](diagrams/trust.svg),
[backup & restore](diagrams/backup.svg), [upgrade flow](diagrams/upgrade.svg) (steps: [diagrams/](diagrams/README.md)).

## Operating rules

- **Explicit cluster context on every command.** Pass `--context k3d-platform-mgmt` for the management cluster, or write a workload cluster kubeconfig and pass `--kubeconfig <cluster>.kubeconfig`. Never target the homelab context or rely on an ambient `current-context`.
- **Git is the source of truth ([conventions.md](conventions.md#invariants)).** Configuration, cluster topology, addon versions, and promotion bindings change through reviewed pull requests to `main` and Argo CD. Imperative commands are restricted to read-only inspection, local secret seeding (`task secrets`), and documented [break-glass](runbooks/break-glass.md) procedures.
- **Never print secrets or tokens.** Inspect `ExternalSecret` readiness, key names, or byte lengths rather than decoding secret values to stdout.
- **Live verification status.** Steps that match upstream or rendered contracts but have not yet been exercised against a live cluster carry `(not yet verified live)`.

## Cluster access

```bash
# Management cluster status, live readiness table, and Argo CD UI (never prints the admin password)
task status
task demo:check
task ui

# Workload cluster kubeconfig (writes <cluster>.kubeconfig, mode 0600, gitignored)
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig get nodes
```

## Runbooks

| Topic | Runbook | When to use |
|---|---|---|
| Upgrades | [runbooks/upgrades.md](runbooks/upgrades.md) | Upgrading k3s, CAPI and infrastructure providers, ClusterClass templates (1 vs 3 control-plane servers), Renovate addon chart and image digest bumps, OpenChoreo, Istio ambient, or Kyverno policies |
| Backup and restore | [runbooks/backup-restore.md](runbooks/backup-restore.md) | Taking or restoring mgmt and workload etcd snapshots, converting legacy SQLite mgmt to embedded etcd, backing up or recovering OpenBao (raft + unseal key), Thunder PVCs, Harbor, or CloudNativePG, and running restore drills |
| Certificates and secrets | [runbooks/certificates-and-secrets.md](runbooks/certificates-and-secrets.md) | Inspecting or rotating cert-manager CAs and leaves, the OpenBao mesh CA, OpenChoreo data-plane agent certificates, GitHub App keys and PATs, the platform `cosign` signing key, or ESO-backed secrets |
| Scaling and capacity | [runbooks/scaling-and-capacity.md](runbooks/scaling-and-capacity.md) | Adding or decommissioning a workload cluster, scaling `MachineDeployment` workers, switching control-plane HA mode (`1` vs `3` servers), or tuning local host RAM and inotify capacity |
| Incidents | [runbooks/incidents.md](runbooks/incidents.md) | Responding to [Argo app stuck / OutOfSync](runbooks/incidents.md#argo-app-stuck-or-outofsync), [cluster unreachable](runbooks/incidents.md#cluster-unreachable), [promotion gate failing closed](runbooks/incidents.md#promotion-gate-failing-closed), [Kyverno denying an image](runbooks/incidents.md#kyverno-denying-an-image), [Falco critical alert](runbooks/incidents.md#falco-critical-alert), [Workflows controller crash loop](runbooks/incidents.md#workflows-controller-crash-loop), [OpenBao sealed](runbooks/incidents.md#openbao-sealed), or [data plane agent disconnected](runbooks/incidents.md#data-plane-agent-disconnected) |
| Observability first look | [runbooks/observability-first-look.md](runbooks/observability-first-look.md) | Triaging an unfamiliar issue across Backstage, the observer API, OpenSearch logs/events/traces, Prometheus metrics, Hubble flows, and checking active gates and runtime alerts |
| Break-glass | [runbooks/break-glass.md](runbooks/break-glass.md) | Freezing Argo CD `selfHeal`, bypassing a blocked admission or sync gate during an emergency, recovering single-server etcd quorum, resetting OpenBao locally, and preserving the audit trail |
