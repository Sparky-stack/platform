---
title: Argo CD Sync-Wave Ordering for CAPI Outputs and Unlimited Retry
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [argocd, capi, bootstrap]
confidence: high
---

# Argo CD Sync-Wave Ordering for CAPI Outputs and Unlimited Retry

## Symptom
During a cold `task up` bootstrap rehearsal, `cluster-dev1` or addon Applications hang indefinitely on a sync wave health wait after a transient CAPI webhook failure or CRD registration race (#192).

## Cause
1. **Same-wave webhook vs health wait deadlock:** When a webhook-validated object (like a CAPI `Cluster`) fails to apply in the same sync wave as another resource that stays `Progressing` until that `Cluster` exists (like a `ClusterResourceSet` or an `ExternalSecret` reading `<cluster>-kubeconfig`), Argo CD waits forever for the wave's applied resources to become `Healthy` before retrying the failed apply (#195, #198).
2. **Finite retry limit + sync timeouts:** A finite `retry.limit` exhausts during first-boot CRD/webhook startup, and setting `controller.sync.timeout.seconds` in Argo CD 3.6 terminates a timed-out operation *without* scheduling a retry (#199).

## Fix
- **Strict sync-wave separation:** Any resource that consumes another controller's output (or depends on a CAPI `Cluster`) must sit at least one sync wave later than the producer; `ClusterResourceSet`s sit after both their payload `Secret`/`ConfigMap` and the `Cluster` (#195, #198), and OpenBao's seal-key `ExternalSecret` sits in wave `-1` before the `StatefulSet` (#191).
- **Unlimited retries (`retry.limit: -1`):** Configure `retry.limit: -1` with exponential backoff and `refresh: true` on generated Applications in `charts/platform` and `charts/tenant` (#199). Never set `controller.sync.timeout.seconds`.

## Where enforced
- `charts/cluster/templates/`, `charts/platform/templates/`, and `hack/tests/test_cluster_sync_order.sh`.

## Links
- Issues #191, #192; PRs #191, #195, #198, #199
- Authoritative docs: [docs/architecture.md](../../docs/architecture.md), [docs/runbooks/incidents.md](../../docs/runbooks/incidents.md)
- Related wiki: [Re-bootstrap over long repair and nightly rehearsal](../decisions/rebootstrap-over-repair-and-nightly-rehearsal.md), [Argo DeletingPolicy and CRS health](argocd-custom-health-deletingpolicy-and-crs.md)
