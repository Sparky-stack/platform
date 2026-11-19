---
title: OpenChoreo SecretReference Rotation and Scope
created: 2026-11-19
updated: 2026-11-19
type: gotcha
tags: [openchoreo, openbao, secrets, eso]
confidence: high
---

# OpenChoreo SecretReference Rotation and Scope

## Symptom
- A rotated OpenBao value shows up in the cell namespace's Kubernetes Secret within seconds, but the app keeps the old
  value (#250).
- `SecretReference.spec.refreshInterval` seems to have no effect.

## Cause
- OpenChoreo 1.3.3 component types render the ExternalSecret themselves with a fixed `refreshInterval: 15s`; the
  SecretReference's own interval is not used by that path.
- The Deployment reads the Secret via `envFrom`; `files[]` are mounted with `subPath`. Neither is refreshed in a running
  container. Reloader is scoped to platform namespaces on purpose (no ClusterRole, cannot read tenant `dp-*`).
- `SecretReference.spec.targetPlane` belongs to OpenChoreo's secrets API (`occ secret`, PushSecret into the plane's
  ClusterSecretStore in `openchoreo-kv-<ns>`), not to the GitOps flow; that API checks `secret:*` actions, which the
  `developer` role does not hold (it has `secretreference:*`).

## Fix / rule
- Rotation: write a new version, then roll the pods (docs/runbooks/certificates-and-secrets.md section 7).
- The store is fixed by the platform (component types -> `SecretStore openbao-tenant`); developers only name a key
  inside their own mount. Tests: hack/tests/test_tenant_app_secrets.sh.
- Open follow-up: automatic rollout on rotation (component-type pod annotation of the Secret hash, addon
  openchoreo-platform).
