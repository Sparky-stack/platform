---
title: Preview Teardown - Stuck ResourceReleaseBinding and Re-created Tenant Descriptor
created: 2026-11-20
updated: 2026-11-20
type: gotcha
tags: [previews, openchoreo, kyverno, openbao, finalizers]
confidence: high
---

# Preview Teardown - Stuck ResourceReleaseBinding and Re-created Tenant Descriptor

## Symptom
After closing a PR (hello-world#35) the preview's Environment and cell namespace were gone, but:
- `ResourceReleaseBinding/<resource>-pr-<n>-<component>` stayed terminating (condition `Finalizing`), and its
  `RenderedRelease/r-<binding>-<hash>` showed `CleanupFailed: failed to get environment pr-<n>-<component>`.
- `openbao-tenants/<project>-openbao-tenant-pr-<n>-<component>` still existed, created at the second the
  ProjectReleaseBinding disappeared.

## Cause
- OpenChoreo 1.3.3: the binding finalizer (`openchoreo.dev/resourcereleasebinding-cleanup`) deletes the
  RenderedRelease and waits for it; the RenderedRelease finalizer (`openchoreo.dev/dataplane-cleanup`) resolves the
  data plane through `spec.environmentName` (`getDPClient`). Once the Environment is gone it can never finish. The
  binding's owner reference to the Environment had no `blockOwnerDeletion`, so the Environment's foreground delete did
  not wait for it.
- Kyverno 1.20 GeneratingPolicy with `synchronize`: the binding's DELETE removes the descriptor, but OpenChoreo removes
  its finalizer later, an UPDATE of a binding that still matched the policy. That UPDATE re-generated the descriptor,
  and no later event deletes it (background controller log: two URs at the same second, one `already exists`).

## Fix
- `auto_build.py` `preview_resource_bindings`: owner reference with `blockOwnerDeletion: true` (Role:
  `environments/finalizers update`). Every delete of the Environment is foreground: Argo's resources finalizer, and the
  TTL DeletingPolicy (`deletionPropagationPolicy: Foreground`). The Environment now waits for the binding and its
  data-plane objects. If the data plane is unreachable, the Environment stays terminating (visible) instead of the binding.
- `platform-preview-tenant-secrets`: matchCondition `!has(object.metadata.deletionTimestamp)`. With synchronize, a
  non-matching UPDATE deletes the downstream instead of re-creating it (offline test: a terminating binding in
  `addons/openbao/tests/kyverno/preview-tenant-secrets/bindings.yaml`).
- Never remove the finalizers by hand as a "fix": that leaves the CNPG cluster or descriptor behind.

Related: [preview cells](preview-cells-tenant-secrets-and-cnpg.md),
[OpenChoreo ReleaseBinding gotchas](openchoreo-releasebinding-and-fresh-registry.md),
[docs/preview-environments.md](../../docs/preview-environments.md#lifecycle-and-limits).
