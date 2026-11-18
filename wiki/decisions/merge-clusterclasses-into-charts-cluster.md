---
title: Merge capi-providers and clusterclasses into charts/cluster with Provider Folders
created: 2026-11-18
updated: 2026-11-19
type: decision
tags: [capi, argocd, bootstrap]
confidence: high
---

# Merge capi-providers and clusterclasses into charts/cluster with Provider Folders

## Context
During the #116 simplification, everything Cluster API lived in three charts: provider installs in the `capi-providers` addon, fleet-wide `ClusterClass`es in the `clusterclasses` addon (both deleted), and per-cluster CAPI/Argo/OpenChoreo/CRS objects in `charts/cluster`. Finding everything one provider (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`) needs meant jumping between all three.

## Decision
- One chart, `charts/cluster`, owns everything CAPI except the upstream operator (`addons/capi-operator` stays).
- Folders follow the fleet-file provider names (#116 plan): `templates/<provider>/` (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`) holds that provider's `provider.yaml` (operator CR), `credentials.yaml`, `clusterclass.yaml` (or `byo/access.yaml`); `templates/common/` holds the CAPI core/k3s providers, namespace `fleet`, the topology `Cluster` and every shared per-cluster template (Argo cluster secret, OpenChoreo, mesh, CRS payloads, registries). Earlier drafts said `providers/<provider>/`; the extra level bought nothing.
- `scope` value: `fleet` renders providers + ClusterClasses once per installation on mgmt (catalog entry `cluster-fleet`, Application `cluster-fleet-<mgmt>`, catalog `path: charts/cluster`); `cluster` (default) renders one workload cluster (ApplicationSet `fleet`, Application `cluster-<name>`). Every template is gated on exactly one scope.
- The topology `Cluster` stays one shared template (`common/capi-cluster.yaml`): the shape is identical for every provider; provider differences are ClusterClass variables.

## Alternatives rejected
- **Keeping the addons separate:** cross-chart coordination whenever provider variables or registry/CNI patches change.
- **Rendering a `ClusterClass` per workload cluster:** defeats CAPI's topology reuse where one `ClusterClass` stamps many clusters.

## Consequences
- The move is render-identical (every object of every installation, both scopes, compared before/after), so ClusterClass template hashes are unchanged and no cluster rolls.
- Argo CD names changed: ApplicationSets `addon-capi-providers` + `addon-clusterclasses` -> `addon-cluster-fleet`; label `addons.platform.koorikla.io/{capi-providers,clusterclasses}` -> `addons.platform.koorikla.io/cluster-fleet`; overlays would go to `installations/<inst>/addons/cluster-fleet/` (none exist).

diff `charts/cluster` cleanup lands.

## Links
- Date: 2026-11-18 (Issue #116 comment)
- Authoritative docs: [docs/providers.md](../../docs/providers.md), [docs/conventions.md](../../docs/conventions.md#layout-and-ownership)
- Related wiki: [Local platform lab scope, BYO, and cloud examples](local-lab-scope-byo-and-cloud-examples.md), [Re-bootstrap over long repair and nightly rehearsal](rebootstrap-over-repair-and-nightly-rehearsal.md)
