---
title: GitOps Catalog and Cluster Onboarding Flow
created: 2026-11-18
updated: 2026-11-18
type: concept
tags: [argocd, capi, openchoreo, secrets]
confidence: high
---

# GitOps Catalog and Cluster Onboarding Flow

## Overview
Every cluster in `koorikla/platform` is declared by a single fleet file: `installations/<inst>/clusters/<name>.yaml`. No addon or ApplicationSet hardcodes cluster names; labels derived from the fleet file drive provisioning, addon delivery, secret distribution, and OpenChoreo data-plane registration.

## End-to-End Flow
1. **Fleet declaration (`charts/platform` -> `charts/cluster`):**
   Adding `installations/<inst>/clusters/<name>.yaml` causes the `fleet` ApplicationSet on `mgmt` to instantiate `charts/cluster` for `<name>`.
2. **Provisioning or registration:**
   - For CAPI providers (`docker`, `aws`, `hetzner`, `gcp-gke`), `charts/cluster` renders a CAPI `Cluster` referencing the provider's `ClusterClass` (`k3s-docker`, `k3s-aws`, `k3s-hetzner`, `gke-managed`).
   - For `provider: byo`, no CAPI object is created; `charts/cluster` reads the `byo-<name>` kubeconfig from the `platform` secret store and pushes bootstrap public CAs via ESO `PushSecret`s.
3. **Addon catalog (`charts/platform`):**
   `charts/cluster` stamps `platform.koorikla.io/*` and `addons.platform.koorikla.io/*` labels onto the Argo CD cluster secret. One matrix ApplicationSet per catalog addon selects matching cluster secrets and pushes the wrapper chart from `addons/<addon>/` with layered values (`values.yaml` -> `values/role-*.yaml` -> `values/provider-*.yaml` -> `values/cni-*.yaml` -> installation overrides).
4. **Zero-key-export trust & OpenChoreo connection:**
   `mgmt` mints a per-cluster OpenChoreo agent client certificate and delivers it (plus public gateway and mesh CAs) via `ClusterResourceSet` or `PushSecret`. Once `addons/openchoreo-data-plane` boots on the workload cluster, its `cluster-agent` dials out over mTLS WebSocket to `mgmt` and reconciles `ClusterDataPlane/<name>`.

## Authoritative Docs & Related Wiki
- Authoritative docs: [docs/architecture.md](../../docs/architecture.md), [docs/conventions.md](../../docs/conventions.md), [docs/providers.md](../../docs/providers.md)
- Related wiki: [Local platform lab scope, BYO, and cloud examples](../decisions/local-lab-scope-byo-and-cloud-examples.md), [Merge clusterclasses into charts/cluster](../decisions/merge-clusterclasses-into-charts-cluster.md), [Argo sync-wave ordering and retry -1](../gotchas/argocd-sync-wave-ordering-and-unlimited-retry.md)
