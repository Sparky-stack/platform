---
title: PR Preview Environments Design
created: 2026-11-18
updated: 2026-11-23
type: decision
tags: [openchoreo, argocd, mesh]
confidence: high
---

# PR Preview Environments Design

## Context
OpenChoreo 1.3.3 allows only one active `ReleaseBinding` per component per `Environment` (upstream `openchoreo#4994` tracks native ephemeral environments). Developers still need isolated per-PR preview URLs and a fast inner loop.

## Decision
- Model each open PR on an opt-in component (`platform.koorikla.io/preview-environments: enabled`) as a dedicated ephemeral OpenChoreo `Environment` (`pr-<N>`) + `ProjectReleaseBinding` + `ReleaseBinding`, rendered by `charts/preview` from a `charts/tenant` Argo CD `PullRequest` generator ApplicationSet (#168).
- Stamp a 48-hour TTL via a Kyverno `MutatingPolicy` (`platform.koorikla.io/expires-at`) and clean up automatically when the PR closes or expires via a Kyverno `DeletingPolicy`.
- Pair PR previews with `occ remote` for rapid inner-loop development before opening a PR.

## Alternatives rejected
- **Multiple `ReleaseBinding`s in the shared `development` Environment:** Rejected by OpenChoreo 1.3.3 admission/controller invariants.
- **Bypassing OpenChoreo with raw Deployment/HTTPRoute preview charts:** Would skip cell NetworkPolicies, ambient mTLS, and secret-store isolation.

- Per-tenant cap (#385): default = no preview. The auto-build pass, serial behind its mutex, is the only place that decides: it grants a slot by labelling the PR `preview-granted` (existing Environments first, then oldest PRs, at most `previews.maxPerTenant` per tenant) and the generated Application renders resources only for granted PRs; the rest get `preview-waiting` + a failed commit status. Rejected: creating the Application at once and holding over-cap PRs afterwards (#406), because three PRs opened together all got Environments before the pass ran, and Kyverno `platform-preview-cap` admitted every concurrent create (each sees the old count). Kyverno stays the backstop. Bot PRs need the `preview` label and a grant.

## Consequences
- Kyverno's `reports-controller` needs RBAC to read OpenChoreo `Environment` objects so the preview `MutatingPolicy` reports `Ready` (PR #176), and Argo CD needs a custom health check for `DeletingPolicy` ([Argo DeletingPolicy health](../gotchas/argocd-custom-health-deletingpolicy-and-crs.md)).

## Links
- Date: 2026-11-17 (Issue #168; PRs #172, #176)
- Authoritative docs: [docs/preview-environments.md](../../docs/preview-environments.md)
- Related wiki: [Argo DeletingPolicy and CRS health](../gotchas/argocd-custom-health-deletingpolicy-and-crs.md), [OpenChoreo ReleaseBinding and fresh registry](../gotchas/openchoreo-releasebinding-and-fresh-registry.md)
