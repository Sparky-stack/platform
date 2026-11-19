---
title: Argo CD Server-Side Diff Hides Changes to Argo Workflows Objects
created: 2026-11-19
updated: 2026-11-19
type: gotcha
tags: [argocd, build-plane]
confidence: high
---

# Argo CD Server-Side Diff Hides Changes to Argo Workflows Objects

## Symptom
- After a merge, `openchoreo-workflow-plane-mgmt` is `Synced`/`Healthy` at the new revision, also after a hard refresh,
  but the live `ClusterWorkflowTemplate` still has the old spec (old `resourceVersion`, last apply at bootstrap) (#184).
- `argocd app diff --core` (client-side) shows the change; `argocd app diff --core --server-side-diff` shows nothing.
- A manual sync applies the change at once. Builds meanwhile run the old template.

## Cause
- addons/openchoreo-workflow-plane installs argo-workflows with `crds.full: false`: the CRDs declare `spec` as
  `x-kubernetes-map-type: atomic` + `x-kubernetes-preserve-unknown-fields`. The API server records Argo's ownership
  as `f:spec: {}` (one atomic field).
- Argo CD builds its GVK parser from `/openapi/v2`, where that `spec` is published without a type, so the parser treats
  it as a granular map. In server-side diff, the mutation-webhook filter (`removeWebhookMutation`) then sees every field
  under `spec` as "not owned by argocd-controller" and resets it to the live value. The apiserver's dry-run apply did
  predict the new spec; Argo throws it away and reports no diff (argoproj/argo-cd#27625, open on 3.6).
- Hits every kind with that CRD shape: `ClusterWorkflowTemplate`, `WorkflowTemplate`, `CronWorkflow`, `Workflow`.

## Fix
- Addons that render those kinds set `compareOptions: [IncludeMutationWebhook=true]` in charts/platform values.yaml
  (Application annotation `argocd.argoproj.io/compare-options`). The diff is still server-side; only the webhook filter is
  skipped. Today: openchoreo-workflow-plane, openchoreo-platform, argo-events.
- Not used: `crds.full: true` (huge upstream CRDs, a much bigger change than the diff bug), a checksum annotation (forces a sync
  but self-heal stays blind to spec drift), `Replace=true` (recreates objects).

## Where enforced
- hack/tests/test_argocd_compare_options.sh: an addon has `IncludeMutationWebhook=true` if and only if its templates or
  files render one of those kinds.

## Not the same: ExternalSecret thunder-bootstrap (#221)
- That ExternalSecret is a Helm hook (`pre-install,pre-upgrade` -> Argo `PreSync`). Argo never diffs hook resources, so a
  changed hook alone never makes the app OutOfSync. Hooks run only when something else triggers a sync.

## Links
- [Argo CD Custom Health for Kyverno DeletingPolicy and Unmatched CRS](argocd-custom-health-deletingpolicy-and-crs.md)
