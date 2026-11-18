---
title: Re-Bootstrap Over Long Live Repair and Nightly Rehearsal
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [bootstrap, argocd, ci]
confidence: high
---

# Re-Bootstrap Over Long Live Repair and Nightly Rehearsal

## Context
Offline rendering and contract tests (`./hack/test.sh`) validate chart schemas and policies in ~8 minutes, but cannot catch first-boot controller races: CRD installation order, CAPI webhook leader-election blips, empty stack-local Harbor registries, or Argo CD sync-wave deadlocks (#192, #200). Hand-patching a degraded local cluster with `kubectl` hides broken bootstrap paths and fights Argo CD server-side apply.

## Decision
- **Prefer clean re-bootstrap (`task down` then `task up`) over long live repair:** Whenever cluster state is wedged or a core ordering change lands, fix the declarative chart in Git and prove it by re-bootstrapping from scratch.
- **Zero manual steps invariant (Invariant 8):** A clean `task up` must converge all ~45 Argo CD Applications to `Synced`/`Healthy` and serve `hello-world` (~31 minutes locally) with zero human intervention, verified by regular clean-bootstrap rehearsals and `task demo:check`.

## Alternatives rejected
- **Imperative `kubectl apply` / manual unsticking in runbooks for first-boot bugs:** Masks race conditions that immediately break the next person or fork running `task up`.
- **Relying solely on offline `helm template` + `kubeconform`:** Missed 5+ live boot race conditions in CAPI, OpenBao, and OpenChoreo (#191-#205).

## Consequences
- Every first-boot race uncovered during rehearsal becomes an automated sync-wave, retry, or custom-health fix guarded by a contract test in `hack/tests/` ([Argo sync-wave ordering and retry -1](../gotchas/argocd-sync-wave-ordering-and-unlimited-retry.md)).

## Links
- Date: 2026-11-17 to 2026-11-18 (Issues #97, #192, #200; PRs #106, #195, #198, #199, #201)
- Authoritative docs: [docs/demo.md](../../docs/demo.md), [docs/operations.md](../../docs/operations.md)
- Related wiki: [Argo sync-wave ordering and retry -1](../gotchas/argocd-sync-wave-ordering-and-unlimited-retry.md), [OpenChoreo ReleaseBinding and fresh registry](../gotchas/openchoreo-releasebinding-and-fresh-registry.md)
