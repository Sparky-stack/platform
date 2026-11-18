---
title: OpenBao Policies Only at Init, Policy Reconciler, and Wave -1 Seal Key
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [secrets, mesh, argocd]
confidence: high
---

# OpenBao Policies Only at Init, Policy Reconciler, and Wave -1 Seal Key

## Symptom
1. Adding a new tenant or updating `tenant-*` HCL policies in `addons/openbao` has no effect on an already-running local `mgmt` cluster; tenant `SecretStore/openbao-tenant` gets permission denied (#96, PR #179).
2. On a cold bootstrap, `openbao` hangs in Argo CD before the `StatefulSet` can start (#191).

## Cause
- **Init-only policy bootstrap:** OpenBao's initialization script (`openbao-init`) runs only when the Raft storage volume is uninitialized. Once initialized, subsequent Helm upgrades left existing policies and JWT auth roles untouched unless manually re-initialized.
- **Seal key sync-wave race:** When the `openbao-unseal` `ExternalSecret` sat in the default sync wave alongside the `StatefulSet` and `PostSync` hooks, the pod waited on a missing volume mount while Argo waited for pod readiness (#191).

## Fix
- Add an idempotent **OpenBao policy reconciler** job in `addons/openbao` that syncs `tenant-*` policies and one identity entity per tenant namespace from Git on every Argo sync without re-initializing Raft storage (PRs #179, #190).
- Place the `openbao-unseal` `ExternalSecret` in sync wave `-1`, before the OpenBao `StatefulSet` (PR #191).

## Where enforced
- `addons/openbao/templates/` and [docs/runbooks/certificates-and-secrets.md](../../docs/runbooks/certificates-and-secrets.md).

## Links
- Issues #19, #96, #191; PRs #117, #170, #179, #190, #191
- Authoritative docs: [docs/multicluster.md](../../docs/multicluster.md), [docs/runbooks/certificates-and-secrets.md](../../docs/runbooks/certificates-and-secrets.md)
- Related wiki: [OpenBao as local mesh CA with pluggable cloud CA](../decisions/openbao-mesh-ca-and-pluggable-cloud-ca.md), [Argo sync-wave ordering and retry -1](argocd-sync-wave-ordering-and-unlimited-retry.md)
