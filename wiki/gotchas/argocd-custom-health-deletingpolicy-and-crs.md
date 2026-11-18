---
title: Argo CD Custom Health for Kyverno DeletingPolicy and Unmatched CRS
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [argocd, capi, supply-chain]
confidence: high
---

# Argo CD Custom Health for Kyverno DeletingPolicy and Unmatched CRS

## Symptom
- `kyverno-policies` Argo CD Application stays perpetually `Progressing` even though all policies are applied (#187).
- In the single-cluster local profile (`dev1` only), `cluster-dev1` stays `Progressing` on its peers-only mesh `ClusterResourceSet` (#198).
- Inspecting `.status.resources[].health` on an Argo CD 3.x `Application` returns empty health fields.

## Cause
- Kyverno's controller never populates `.status.conditions` (`Ready`) on `policies.kyverno.io/v1beta1` `DeletingPolicy` resources (unlike `ValidatingPolicy` or `MutatingPolicy`), so Argo CD's built-in condition check waits forever.
- A CAPI `ClusterResourceSet` whose label selector matches zero clusters (such as a peer remote-secret CRS when `prod1` is disabled) has no `ResourcesApplied` condition, which Argo CD treats as `Progressing`.
- Argo CD 3.x moved per-resource health out of `.status.resources[]`; you must run `argocd app get --core <app>` to inspect individual resource health.

## Fix
- Custom Lua health checks in `addons/argo-cd/values.yaml` (`configs.cm.resource.customizations.health.*`):
  - Mark `policies.kyverno.io_DeletingPolicy` immediately `Healthy`.
  - Mark `addons.cluster.x-k8s.io_ClusterResourceSet` `Healthy` when no cluster matches its selector or when `ResourcesApplied=True`.

## Where enforced
- `addons/argo-cd/values.yaml` and contract tests in `hack/tests/test_cluster_sync_order.sh`.

## Links
- Issues #187, #192, #198; PRs #187, #198
- Authoritative docs: [docs/runbooks/incidents.md](../../docs/runbooks/incidents.md)
- Related wiki: [Argo sync-wave ordering and retry -1](argocd-sync-wave-ordering-and-unlimited-retry.md), [PR preview environments design](../decisions/pr-preview-environments.md)
