---
title: Argo CD Server-Side Diff Deadlocks on Immutable Fields
created: 2026-11-21
updated: 2026-11-21
type: gotcha
tags: [argocd]
confidence: high
---

# Argo CD Server-Side Diff Deadlocks on Immutable Fields

## Symptom
- After #279 changed PriorityClass `app-production` to `preemptionPolicy: Never`, `openchoreo-data-plane-dev1` went
  `Unknown` with `ComparisonError: error running server side apply in dryrun mode for resource
  PriorityClass/app-production: ... field is immutable` (#281). The object's `Force=true,Replace=true` never ran.

## Cause
- `controller.diff.server.side: true`: every compare dry-runs a server-side apply of each object. The apiserver rejects
  the immutable field in that dry run, `CompareAppState` fails for the WHOLE Application, so no sync (and no sync
  option) ever starts. gitops-engine `diff.go` `serverSideDiff` returns the error; Argo CD 3.6 decides server-side diff
  per Application only (`controller/state.go` `shouldUseServerSideDiff`), never per resource.

## Fix
- Objects with an immutable spec live in an addon whose catalog entry sets `compareOptions: [ServerSideDiff=false]`
  and that renders nothing else (addon `priority-classes`); there the client-side diff shows OutOfSync and
  `Force=true,Replace=true` deletes + recreates the object. Jobs are hooks or checksum-named; PVCs are never replaced.
- Contract: `hack/tests/test_immutable_fields.sh`; rules in [conventions](../../docs/conventions.md#immutable-fields).
- Break-glass on a stack still running the old layout: delete the object once, Argo CD recreates it.
