---
title: Merge clusterclasses into charts/cluster with Provider Folders
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [capi, argocd, bootstrap]
confidence: high
---

# Merge clusterclasses into charts/cluster with Provider Folders

## Context
During the #116 repo-wide simplification scan, CAPI cluster templates were split across two places: fleet-wide `ClusterClass` definitions in `addons/clusterclasses` and per-cluster CAPI/Argo/OpenChoreo/CRS objects in `charts/cluster`. Finding every template affecting a provider (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`) required jumping between both charts.

## Decision
- Fold `addons/clusterclasses` into `charts/cluster` so one chart owns everything cluster-related (#116 owner comment).
- Organize provider-specific templates under `charts/cluster/templates/providers/{docker,aws,hetzner,gcp-gke,byo}/` (holding each provider's `ClusterClass` and per-cluster templates) while keeping shared templates (Argo cluster secret, OpenChoreo data plane, mesh, CRS payloads) at the top level of `charts/cluster/templates/`.
- Render `ClusterClass` objects once fleet-wide via a `classes` mode on `charts/cluster` (used by the existing `mgmt` Application) rather than duplicating `ClusterClass` objects per cluster.

## Alternatives rejected
- **Keeping `addons/clusterclasses` separate:** Forces cross-chart coordination whenever provider variables or registry/CNI patches change.
- **Rendering a separate `ClusterClass` per workload cluster:** Defeats CAPI's topology reuse where one `ClusterClass` stamps many clusters.

## Consequences
- Extracting shared CNI/registry patch blocks changes template content hashes once, rolling `dev1` nodes on upgrade; this migration will be verified with a clean bootstrap rehearsal (`task down` + `task up`) after the zero-diff `charts/cluster` cleanup lands.

## Links
- Date: 2026-11-18 (Issue #116 comment)
- Authoritative docs: [docs/providers.md](../../docs/providers.md), [docs/conventions.md](../../docs/conventions.md#layout-and-ownership)
- Related wiki: [Local platform lab scope, BYO, and cloud examples](local-lab-scope-byo-and-cloud-examples.md), [Re-bootstrap over long repair and nightly rehearsal](rebootstrap-over-repair-and-nightly-rehearsal.md)
