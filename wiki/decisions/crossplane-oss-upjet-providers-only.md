---
title: OSS crossplane-contrib Upjet Providers Only
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [data, openchoreo, upstream]
confidence: high
---

# OSS crossplane-contrib Upjet Providers Only

## Context
The platform exposes cloud-agnostic data services (starting with `PostgreSQL` in `addons/crossplane`) via Crossplane v2 XRDs and Compositions that target `CloudNativePG` in-cluster or managed cloud databases (AWS RDS, GCP Cloud SQL, Azure Flexible Server).

## Decision
- Standardize strictly on **open-source `crossplane-contrib` Upjet family providers** (`provider-family-aws` / `provider-aws-rds`, `provider-family-gcp` / `provider-gcp-sql`, `provider-family-azure` / `provider-azure-dbforpostgresql`) alongside `function-patch-and-transform` and `function-auto-ready`.
- Use `CloudNativePG` (`addons/cloudnative-pg`) as the default local and in-cluster backend so the exact same `PostgreSQL` XR works offline on `k3d`/CAPD.

## Alternatives rejected
- **Commercial Upbound Marketplace providers (`xpkg.upbound.io/upbound/...`):** Introduce proprietary licensing/account tiers and commercial Upbound cloud dependencies into an open-source reference platform.
- **Monolithic legacy Crossplane providers:** Deprecated upstream and exceed CRD count/memory budgets on local k3d management clusters.

## Consequences
- Every Composition is tested offline with `crossplane render` and `kubeconform` in `hack/tests/test_crossplane_render.sh`.
- Offline render tests must share a single Docker network and function containers to avoid exhausting Docker's subnet pool ([Docker network pool exhaustion](../gotchas/docker-network-pool-exhaustion-crossplane-render.md)).

## Links
- Date: 2026-11-16 (Issue #91; PRs #111, #211)
- Authoritative docs: [docs/data-services.md](../../docs/data-services.md)
- Related wiki: [Helm, Crossplane, and OpenChoreo building blocks](building-blocks-helm-crossplane-openchoreo.md), [Docker network pool exhaustion from crossplane render](../gotchas/docker-network-pool-exhaustion-crossplane-render.md)
