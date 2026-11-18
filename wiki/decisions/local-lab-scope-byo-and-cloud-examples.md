---
title: Local Platform Lab Scope, Single-Cluster Profile, BYO, and Cloud Examples
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [capi, bootstrap, docs]
confidence: high
---

# Local Platform Lab Scope, Single-Cluster Profile, BYO, and Cloud Examples

## Context
Running a management cluster (`mgmt`) plus two CAPD workload clusters (`dev1` and `prod1`) with Istio ambient, OpenSearch, Harbor, OpenBao, and OpenChoreo consumed >16 GiB RAM and caused k3s leader-election restarts on a single laptop/host (#82, #115). At the same time, readers needed clear expectations about cloud CAPI providers and non-CAPI clusters.

## Decision
- **Frame the repo as a local platform lab:** Everything is built and proven live on Docker (`k3d` mgmt + CAPD workload cluster).
- **Single-cluster default local profile (#115):** Run one workload cluster (`dev1`) by default and map `development`, `staging`, and `production` environments to isolated cell namespaces on `dev1`. Keep `installations/local/clusters/prod1.yaml.disabled` as a one-file rename switch when demonstrating cross-cluster mesh or multi-cluster placement.
- **Bring-your-own cluster (`provider: byo`, #173):** Any conformant Kubernetes cluster can join without CAPI via a seeded `byo-<name>` kubeconfig and ESO `PushSecret` delivery.
- **Cloud CAPI ClusterClasses as untested examples:** Ship AWS (`k3s-aws`), Hetzner (`k3s-hetzner`), and GKE (`gke-managed`) templates rendered and schema-validated in CI, explicitly marked as **untested examples** in docs.

## Alternatives rejected
- **Always booting `prod1` locally:** Starved host memory and made clean bootstrap rehearsals flaky on 16-32 GiB machines.
- **Claiming full production cloud validation without live cloud CI:** Dishonest; marking cloud providers as rendered examples keeps claims truthful.

## Consequences
- Local bootstrap converges in ~31 minutes with healthy RAM headroom.
- Peers-only mesh `ClusterResourceSet`s must report `Healthy` in Argo CD even when only `dev1` exists ([Argo custom health checks](../gotchas/argocd-custom-health-deletingpolicy-and-crs.md)).

## Links
- Date: 2026-11-16 to 2026-11-18 (Issues #87-#90, #115, #173; PRs #120, #163, #178, #186)
- Authoritative docs: [README.md](../../README.md), [docs/portability.md](../../docs/portability.md), [docs/providers.md](../../docs/providers.md)
- Related wiki: [Talos on Hetzner waits for upstream](talos-on-hetzner-waits-for-upstream.md), [Argo DeletingPolicy and CRS health](../gotchas/argocd-custom-health-deletingpolicy-and-crs.md)
