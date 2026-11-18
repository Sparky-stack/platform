---
title: Helm, Crossplane, and OpenChoreo Building Blocks — No Kustomize or Flux
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [argocd, openchoreo, data, agents]
confidence: high
---

# Helm, Crossplane, and OpenChoreo Building Blocks — No Kustomize or Flux

## Context
Official upstream OpenChoreo GitOps skills (`openchoreo-developer-gitops`, `openchoreo-platform-engineer-gitops`) assume a Flux CD + Kustomize repository layout. Mixing Helm, Kustomize overlays, Flux controllers, and ad-hoc scripts in one platform repository creates abstraction sprawl that fails the 4am SRE readability test.

## Decision
- Restrict platform building blocks strictly (in order of preference) to:
  1. **Helm umbrella and wrapper charts** (`charts/platform`, `charts/cluster`, `charts/tenant`, `charts/preview`, `addons/<addon>/`) with values-only overlays in `installations/<inst>/`.
  2. **Crossplane v2 XRDs and Compositions** for infrastructure/data APIs (`addons/crossplane`).
  3. **OpenChoreo declarative objects** (`ComponentType`, `Trait`, `ResourceType`, `Workflow`, `Environment`, `ReleaseBinding`).
- Reconcile everything through **Argo CD on `mgmt` only** (push mode, label-selected ApplicationSets). Never add Flux CD or Kustomize (`kustomization.yaml`) to this repository.
- Keep templates readable at 4am by a sleepy SRE: obvious names, one place per concern, and comments explaining *why* rather than *what*.

## Alternatives rejected
- **Flux CD + Kustomize (upstream OpenChoreo default):** Duplicates Argo CD's role and splits configuration across patch overlays and Helm values.
- **Imperative scripts or `occ` mutations:** Violates GitOps Invariant 8 (`occ`/MCP is used only for read/verify and E2E checks).

## Consequences
- AI agents loading upstream OpenChoreo skills must read only the OpenChoreo CRD object model and skip Flux/Kustomize references (saving context tokens; see [Gemini transcript ceiling](../gotchas/gemini-transcript-ceiling-for-agents.md)).

## Links
- Date: 2026-11-14 (Owner architecture rule)
- Authoritative docs: [docs/architecture.md](../../docs/architecture.md), [docs/conventions.md](../../docs/conventions.md)
- Related wiki: [OSS crossplane-contrib upjet providers only](crossplane-oss-upjet-providers-only.md), [Gemini transcript ceiling for agents](../gotchas/gemini-transcript-ceiling-for-agents.md)
