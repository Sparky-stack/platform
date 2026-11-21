---
title: argocd-agent Managed Mode Waits for Upstream 1.0
created: 2026-11-21
updated: 2026-11-21
type: decision
tags: [argocd, gitops, upstream, security]
confidence: medium
---

# argocd-agent Managed Mode Waits for Upstream 1.0

## Context
Issue #20 asked to move workload clusters from Argo CD push mode to argocd-agent managed mode so mgmt holds no
workload admin kubeconfig. A spike on two throwaway k3d clusters (`hack/spikes/argocd-agent/`) ran argocd-agent
v0.11.0 with Argo CD v3.6.1 and five real addon ApplicationSets.

## Decision
Go later, with conditions: argocd-agent >= 1.0 (or its managed-mode sync/status bugs fixed), owner sign-off on changing
invariant 3 (Argo CD core on every workload cluster), and the goal restated as "Argo CD holds no workload credential".
Findings, measurements and the migration outline: the spike comment on #20.

## Facts that hold whatever we decide
- The principal routes by `spec.destination.name` only (destination-based mapping); `destination.server` with
  `?agentName=` is ignored. Our cluster generator still works because the agent's cluster secret is a cluster secret.
- CAPI keeps `fleet/<c>-kubeconfig` on mgmt; charts/cluster mesh ExternalSecrets and CRSs use it. The agent removes only
  Argo CD's copy.
- Health Lua, ignoreDifferences and other argocd-cm customizations run in the SPOKE controller; a hub-only override has
  no effect.
- Live resources, logs and actions go through the agent ServiceAccount: grant spoke RBAC or the UI says PermissionDenied.
- The principal must reach the hub's `argocd-redis` (NetworkPolicy), or hub Application status silently stops updating.
- A disconnected agent leaves hub Applications at their last status with no condition: alert on agent connection.

## Alternatives rejected
- **Autonomous mode:** Applications defined on each workload cluster; breaks "one ApplicationSet catalog on mgmt".
- **Migrating now on 0.x:** principal HA is Beta, upstream Helm chart lags releases, open bugs can lose sync requests.
