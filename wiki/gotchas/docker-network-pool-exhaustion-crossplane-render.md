---
title: Docker Network Pool Exhaustion from crossplane render
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [data, ci, bootstrap]
confidence: high
---

# Docker Network Pool Exhaustion from crossplane render

## Symptom
Running `hack/tests/test_crossplane_render.sh` (or full `./hack/test.sh` while `k3d` and CAPD clusters are running on the same host) fails mid-suite with Docker error: `all predefined address pools have been fully subnetted` (PR #181).

## Cause
- By default, each invocation of `crossplane render` starts new ephemeral function containers (`function-patch-and-transform`, `function-auto-ready`) on a freshly allocated Docker bridge network.
- Across dozens of positive and negative Composition test cases, concurrent or rapid sequential runs exhaust Docker's default ~31 bridge network address pools before cleanup completes, especially when `k3d` and CAPD bridge networks already occupy several subnets.

## Fix
- Start one shared Docker network and one set of long-lived Crossplane function containers per test script invocation (`hack/tests/test_crossplane_render.sh`), pass their runtime addresses to `crossplane render`, and tear them down in an `EXIT` trap (PR #181).

## Where enforced
- `hack/tests/test_crossplane_render.sh`.

## Links
- PR #181
- Authoritative docs: [docs/data-services.md](../../docs/data-services.md), [docs/dev-environment.md](../../docs/dev-environment.md)
- Related wiki: [OSS crossplane-contrib upjet providers only](../decisions/crossplane-oss-upjet-providers-only.md), [mise global vs repo tool versions](mise-global-vs-repo-tool-versions.md)
