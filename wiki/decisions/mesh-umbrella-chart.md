---
title: One Mesh Umbrella Chart (addons/mesh)
created: 2026-11-19
updated: 2026-11-19
type: decision
tags: [mesh, argocd]
confidence: high
---

# One Mesh Umbrella Chart (addons/mesh)

## Context
The mesh was three addons and three Argo apps per member cluster: `istio-ambient` (base/istiod/cni/ztunnel),
`istio-csr` (cert-manager istio-csr + Vault Issuer to OpenBao) and `istio-eastwest` (east-west gateway + reader RBAC).
The last two followed the fleet file's `mesh.group` through derived `addons.platform.koorikla.io/*` labels, and the
ambient chart read those labels again to flip multi-network. Three places to look at 4am for one concern (#116).

## Decision
- One wrapper chart `addons/mesh`, one Argo app `mesh-<cluster>` per workload cluster (catalog `default: true`).
- Ambient always. `values/mesh-member.yaml` (layered by the ApplicationSet when the cluster has the
  `mesh.platform.koorikla.io/group` label) turns on `mesh.csr.enabled` (istio-csr subchart condition + Issuer +
  admission templates), `mesh.eastwest.enabled` (gateway + reader RBAC) and istiod multi-network / CA off.
- Ordering lives in one app: Issuer prerequisites wave -2, Issuer -1 (Ready = OpenBao login), istio-csr + istiod 0,
  ztunnel 1. Consequence: on a member the whole mesh app waits for the OpenBao login before istiod changes; the
  running istiod keeps serving meanwhile.
- The dependency-digest pin (`platform.koorikla.io/dependency-digests`) now covers the istio-csr tarball too.

## Consequences
- Rendered objects are identical to the three old addons except the Helm release labels (`release`,
  `app.kubernetes.io/instance` = `mesh`), which roll the pods once. No selector changes.
- Old apps `istio-ambient-<c>`, `istio-csr-<c>`, `istio-eastwest-<c>` disappear; ApplicationSet Applications carry no
  resources finalizer, so their objects are adopted by `mesh-<c>`, not deleted.

## Related
- [OpenBao as Local Mesh CA](openbao-mesh-ca-and-pluggable-cloud-ca.md), docs/multicluster.md, docs/networking.md.
