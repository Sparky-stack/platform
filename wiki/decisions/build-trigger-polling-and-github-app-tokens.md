---
title: Build Trigger Polling Locally, Webhook in Cloud, and GitHub App Tokens
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [openchoreo, supply-chain, secrets]
confidence: high
---

# Build Trigger Polling Locally, Webhook in Cloud, and GitHub App Tokens

## Context
OpenChoreo's built-in auto-build webhook names `WorkflowRun`s randomly and requires public webhook ingress. Meanwhile, static personal access tokens (PATs) violated least-privilege repository scoping (#34), and fresh local bootstraps had no image in stack-local Harbor for the digest committed in `koorikla/hello-world` (#200).

## Decision
- **Platform-owned auto-build trigger (#164, #200):** Poll tenant repositories on `mgmt` in local installations (no external tunnel required) and accept HMAC-verified GitHub App push webhooks (`github-webhook` via `addons/argo-events`) in cloud installations. Name runs deterministically (`<component>-<sha12>`) and trigger a rebuild automatically whenever the stack-local Harbor registry is missing the digest pinned in GitOps.
- **GitHub App installation tokens, no PATs (#10, #34):** Eliminate static build PATs. Use the platform GitHub App (`promotion-gate-github`) and ESO generators to mint short-lived, per-repository installation tokens (`contents: read` for polling, `contents: write` scoped to the single target repo for builds and promotion gate PRs).

## Alternatives rejected
- **OpenChoreo built-in auto-build webhook:** Random run names prevented idempotent deduplication across restarts and required a public tunnel locally.
- **Long-lived GitHub PATs:** Account-wide blast radius and manual rotation burden.

## Consequences
- A clean `task up` automatically builds `hello-world` into local Harbor when the pinned digest is absent, converging without manual triggers ([ReleaseBinding and fresh registry gotcha](../gotchas/openchoreo-releasebinding-and-fresh-registry.md)).

## Links
- Date: 2026-11-17 to 2026-11-18 (Issues #10, #34, #164, #200; PRs #167, #177, #197, #201)
- Authoritative docs: [docs/build-plane.md](../../docs/build-plane.md), [docs/conventions.md](../../docs/conventions.md#secret-keys)
- Related wiki: [OpenChoreo ReleaseBinding and fresh registry](../gotchas/openchoreo-releasebinding-and-fresh-registry.md), [OpenChoreo SDLC and promotion flow](../concepts/openchoreo-sdlc-and-promotion-flow.md)
