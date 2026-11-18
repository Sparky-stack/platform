---
title: OpenChoreo SDLC, Supply Chain, and Promotion Flow
created: 2026-11-18
updated: 2026-11-18
type: concept
tags: [openchoreo, supply-chain, mesh, observability]
confidence: high
---

# OpenChoreo SDLC, Supply Chain, and Promotion Flow

## Overview
Tenant applications (such as `koorikla/hello-world`) live in their own repositories with declarative OpenChoreo manifests under `deploy/openchoreo/`, while tenant projects and environment pipelines are registered in `installations/<inst>/tenants/<project>.yaml` (`charts/tenant`).

## End-to-End Lifecycle
1. **Scaffold or push:**
   A developer scaffolds a repo from a Backstage golden-path template (`templates/`) or pushes a commit. The platform auto-build trigger on `mgmt` detects the commit (via local polling or cloud GitHub App webhook) or notices that stack-local Harbor lacks the pinned digest.
2. **In-cluster build & signing (`addons/openchoreo-workflow-plane`):**
   Rootless BuildKit builds the multi-arch container image (pulling base images through Harbor proxy caches), generates SBOM and SLSA provenance, pushes to Harbor, signs with Cosign (`cosign-platform` key in-cluster or keyless Sigstore in GitHub Actions), and commits the new digest and `ComponentRelease` back to the app repo using a short-lived GitHub App token.
3. **Cell deployment (`development` -> `staging`):**
   Argo CD syncs the updated `ComponentRelease` and `ReleaseBinding`. OpenChoreo renders the workload into the cell namespace (`dp-<ns>-<project>-<env>-<hash>`) on the target `ClusterDataPlane`, wired into Istio ambient mesh (`STRICT` mTLS) and `kgateway` ingress.
4. **Gated promotion to `production`:**
   Promoting to `production` triggers the `promotion-gate` workflow via Argo Events: it verifies deployment readiness, queries the observability plane for HTTP traffic and 5xx error-rate SLOs, checks freeze windows, and opens/merges a reviewed Git promotion PR. Kyverno on the workload cluster enforces image signature and attestation verification before admitting pods.

## Authoritative Docs & Related Wiki
- Authoritative docs: [docs/openchoreo.md](../../docs/openchoreo.md), [docs/build-plane.md](../../docs/build-plane.md), [docs/promotion.md](../../docs/promotion.md), [docs/supply-chain.md](../../docs/supply-chain.md)
- Related wiki: [Build trigger polling and GitHub App tokens](../decisions/build-trigger-polling-and-github-app-tokens.md), [PR preview environments design](../decisions/pr-preview-environments.md), [OpenChoreo ReleaseBinding and fresh registry](../gotchas/openchoreo-releasebinding-and-fresh-registry.md)
