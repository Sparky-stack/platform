---
title: Talos on Hetzner Waits for Upstream CACPPT Release
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [capi, upstream]
confidence: high
---

# Talos on Hetzner Waits for Upstream CACPPT Release

## Context
The owner decided that the (untested) Hetzner Cloud CAPI example should use immutable **Talos Linux** (`talos-hetzner`) instead of `k3s-hetzner`. Every CAPI provider in this repo uses CAPI `v1beta2` `ClusterClass` topology ([docs/conventions.md](../../docs/conventions.md#current-practice-only)).

## Decision
- Wait for Sidero Labs' `cluster-api-control-plane-provider-talos` (CACPPT) to cut a release (`v0.6.0-alpha.1+` or `v0.6.0`) containing `TalosControlPlaneTemplate` (merged upstream in `siderolabs/cluster-api-control-plane-provider-talos#284` on 2026-11-05) before replacing `k3s-hetzner` with `talos-hetzner` (#189).
- Keep `k3s-hetzner` until that upstream tag exists.

## Alternatives rejected
- **Pinning an unreleased `main` commit image of CACPPT:** Violates our pinned-release and supply-chain standards and couples `addons/capi-providers` to an unstable CAPI `v1.14` development branch.
- **Dropping `ClusterClass` on Hetzner:** Breaks the repo contract that every CAPI cluster is stamped from a `ClusterClass` via `charts/cluster`.
- **Flatcar Linux + kubeadm Ignition:** Still behind an experimental feature gate upstream (`flatcar#2166`).

## Consequences
- Tracked in open issue #189 with full implementation notes (CABPT `v0.7.x` + CACPPT `v0.6.x`, CNI mapping, Harbor mirror config, `hcloud-ccm`, and note that Sidero marks the CAPI providers community-maintained in favor of Omni).

## Links
- Date: 2026-11-17 (Issue #189)
- Authoritative docs: [docs/providers.md](../../docs/providers.md)
- Related wiki: [Local platform lab scope, BYO, and cloud examples](local-lab-scope-byo-and-cloud-examples.md), [Merge clusterclasses into charts/cluster](merge-clusterclasses-into-charts-cluster.md)
