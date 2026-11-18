---
title: OpenChoreo ReleaseBinding Ordering and Fresh Local Harbor Digests
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [openchoreo, supply-chain, bootstrap]
confidence: high
---

# OpenChoreo ReleaseBinding Ordering and Fresh Local Harbor Digests

## Symptom
1. After a fresh `task up`, `koorikla/hello-world` Applications are `Synced` in Argo CD, yet either no `RenderedRelease` / workload is created or pods fail with `ImagePullBackOff` / Kyverno admission errors against `registry.harbor.localhost` (#200).
2. A promotion gate checks `ReleaseBinding` status and advances before the new workload pods are actually ready (#103).

## Cause
- **ReleaseBinding created before ComponentRelease:** OpenChoreo 1.3.3 does not re-reconcile a `ReleaseBinding` when its referenced `ComponentRelease` is created *after* the binding.
- **Ephemeral local Harbor vs Git-pinned digest:** `koorikla/hello-world` commits the `ComponentRelease` with an image digest built into a previous local Harbor instance. After `task down` + `task up`, the fresh Harbor database is empty, and a commit-only polling trigger sees no new Git SHA.
- **Optimistic ReleaseBinding status:** OpenChoreo marks `ReleaseBinding` healthy before the underlying data-plane `Deployment` finishes rolling out.

## Fix
- Order `ComponentRelease` before `ReleaseBinding` (or touch/annotate the `ReleaseBinding` after creating the release).
- Make the auto-build trigger **registry-aware** (PR #201): query Harbor for the pinned digest and trigger an idempotent `<component>-<sha12>` build whenever the digest is missing.
- Promotion gates check data-plane workload readiness and live HTTP traffic directly rather than trusting `ReleaseBinding` status (#103, #104).

## Where enforced
- `addons/openchoreo-platform`, `hack/tests/test_demo_check.sh`, and `task demo:check`.

## Links
- Issues #103, #164, #200; PRs #167, #201
- Authoritative docs: [docs/build-plane.md](../../docs/build-plane.md), [docs/openchoreo.md](../../docs/openchoreo.md)
- Related wiki: [Build trigger polling and GitHub App tokens](../decisions/build-trigger-polling-and-github-app-tokens.md), [Re-bootstrap over long repair](../decisions/rebootstrap-over-repair-and-nightly-rehearsal.md)
