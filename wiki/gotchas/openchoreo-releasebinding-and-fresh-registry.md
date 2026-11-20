---
title: OpenChoreo ReleaseBinding Ordering and Fresh Local Harbor Digests
created: 2026-11-18
updated: 2026-11-20
type: gotcha
tags: [openchoreo, supply-chain, bootstrap]
confidence: high
---

# OpenChoreo ReleaseBinding Ordering and Fresh Local Harbor Digests

## Symptom
1. After a fresh `task up`, `koorikla/hello-world` Applications are `Synced` in Argo CD, yet either no `RenderedRelease` / workload is created or pods fail with `ImagePullBackOff` / Kyverno admission errors against `registry.harbor.localhost` (#200).
2. A promotion gate checks `ReleaseBinding` status and advances before the new workload pods are actually ready (#103).
3. After a clean bootstrap development stays `ImagePullBackOff` on the Git-pinned digest: the missing-digest rebuild
   `<component>-<sha12>-<digest8>` failed at `check` with `main: Unknown (exit code 255)` and was never retried.
4. After a clean bootstrap the development ReleaseBinding stays `ResourceApplyFailed` (`scaledobjects.keda.sh "..." not found`) for ~17 min although `keda-<cluster>` is Healthy (#246).

## Cause
- **ReleaseBinding created before ComponentRelease:** OpenChoreo 1.3.3 does not re-reconcile a `ReleaseBinding` when its referenced `ComponentRelease` is created *after* the binding.
- **Ephemeral local Harbor vs Git-pinned digest:** `koorikla/hello-world` commits the `ComponentRelease` with an image digest built into a previous local Harbor instance. After `task down` + `task up`, the fresh Harbor database is empty, and a commit-only polling trigger sees no new Git SHA.
- **Failed apply waits on a capped backoff:** the `RenderedRelease` controller returns apply errors to controller-runtime (default rate limiter: 5 ms doubling, max 1000 s) and watches nothing on the data plane. First-boot failures (agent 502s, then a ScaledObject before addon keda exists) push the next retry to 16m40s after the last failure; the binding mirrors the release.
- **One rebuild per digest, killed mid-bootstrap:** bootstrap disk load stalled etcd (10-14 s applies), k3s lost its
  leader lease and exited (`leaderelection lost for k3s`); docker restarted the server container and every pod,
  including the build's `check`, ended with exit 255 "Unknown". The rebuild name existed, so auto-build never retried.
  Not the app: a later run of the same code passed `check` on the same stack. Read `docker inspect
  k3d-<cluster>-server-0 -f '{{.RestartCount}}'` before blaming a step.
- **Optimistic ReleaseBinding status:** OpenChoreo marks `ReleaseBinding` healthy before the underlying data-plane `Deployment` finishes rolling out.

## Fix
- Order `ComponentRelease` before `ReleaseBinding` (or touch/annotate the `ReleaseBinding` after creating the release).
- Make the auto-build trigger **registry-aware** (PR #201): query Harbor for the pinned digest and trigger an idempotent `<component>-<sha12>` build whenever the digest is missing.
- Build steps retry an infra-killed pod (exit 255 / Argo error, `retryStrategy`); auto-build retries a failed rebuild
  as `-r2`/`-r3` 5 min apart, then logs `FAILED 3 times` and exits non-zero once per head.
- Gate the data plane's cluster agent on its capabilities: addon openchoreo-data-plane `capabilityGate` Sync hook (wave -1) waits for the CRDs of every opted-in addon a ClusterTrait or ClusterResourceType renders (#246; #255 added the PostgreSQL XRD, which arrives with crossplane's Configuration package minutes after crossplane is Healthy). No binding touches, no polling of OpenChoreo objects.
- Promotion gates check data-plane workload readiness and live HTTP traffic directly rather than trusting `ReleaseBinding` status (#103, #104).

## Where enforced
- `addons/openchoreo-platform`, `addons/openchoreo-data-plane/templates/capability-gate.yaml`, `hack/tests/test_openchoreo_types.sh`, `hack/tests/test_demo_check.sh`, and `task demo:check`.

## Links
- Issues #103, #164, #200, #246; PRs #167, #201
- Authoritative docs: [docs/build-plane.md](../../docs/build-plane.md), [docs/openchoreo.md](../../docs/openchoreo.md)
- Related wiki: [Build trigger polling and GitHub App tokens](../decisions/build-trigger-polling-and-github-app-tokens.md), [Re-bootstrap over long repair](../decisions/rebootstrap-over-repair-and-nightly-rehearsal.md)
