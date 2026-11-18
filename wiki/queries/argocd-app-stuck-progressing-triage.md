---
title: Why Is an Argo CD Application Stuck Progressing on First Boot?
created: 2026-11-18
updated: 2026-11-18
type: query
tags: [argocd, capi, openchoreo, bootstrap]
confidence: high
---

# Why Is an Argo CD Application Stuck Progressing on First Boot?

## Question
During `task up`, one or more Argo CD Applications remain `Progressing` or `OutOfSync` past the 20-minute mark. How do you triage the root cause without imperative `kubectl` workarounds?

## Triage Checklist
1. **Inspect per-resource health with `--core`:**
   Argo CD 3.x does not populate `.status.resources[].health` on the `Application` CR. Run:
   `kubectl -n argocd exec deploy/argocd-server -- argocd app get --core <app>`
2. **Check for same-wave producer/consumer deadlock:**
   If an Application has both a failed webhook apply (e.g. CAPI `Cluster`) and a `Progressing` consumer in the same sync wave (`ClusterResourceSet` or `ExternalSecret`), move the consumer to a higher sync wave ([Argo sync-wave ordering and retry -1](../gotchas/argocd-sync-wave-ordering-and-unlimited-retry.md)).
3. **Check custom Lua health rules:**
   - Kyverno `DeletingPolicy` never populates `.status.conditions`.
   - Peers-only `ClusterResourceSet`s match zero clusters in the single-cluster local profile (`dev1` only).
   Verify `addons/argo-cd/values.yaml` covers the resource kind ([Argo DeletingPolicy and CRS health](../gotchas/argocd-custom-health-deletingpolicy-and-crs.md)).
4. **Check OpenBao seal key or policy reconciliation:**
   If `openbao` or tenant `ExternalSecret`s are stuck, confirm `openbao-unseal` is in wave `-1` and the policy reconciler job ran ([OpenBao policies init and reconciler](../gotchas/openbao-policies-init-and-reconciler.md)).
5. **Check fresh Harbor digest for tenant workloads:**
   If `hello-world` pods fail to pull after `task down` + `task up`, check the registry-aware auto-build trigger on `mgmt` ([OpenChoreo ReleaseBinding and fresh registry](../gotchas/openchoreo-releasebinding-and-fresh-registry.md)).

## Links
- Authoritative docs: [docs/runbooks/incidents.md](../../docs/runbooks/incidents.md), [docs/operations.md](../../docs/operations.md)
- Related wiki: [Re-bootstrap over long live repair](../decisions/rebootstrap-over-repair-and-nightly-rehearsal.md), [Argo sync-wave ordering and retry -1](../gotchas/argocd-sync-wave-ordering-and-unlimited-retry.md)
