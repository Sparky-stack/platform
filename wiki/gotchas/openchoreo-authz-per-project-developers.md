---
title: OpenChoreo Authz - Deny Is Per Entitlement Value; Developers Per Project
created: 2026-11-20
updated: 2026-11-20
type: gotcha
tags: [openchoreo, authz, security, tenants]
confidence: high
---

# OpenChoreo Authz - Deny Is Per Entitlement Value; Developers Per Project

## Symptom
- Upstream's default `developer-binding` (group `developers` -> ClusterAuthzRole `developer`, no scope) gives every
  developer `component:create` and `projectreleasebinding:create` in EVERY project (#335). Live `evaluate_authz` before
  the fix: group `developers`, `projectreleasebinding:create` on `ns/default/project/other-team` -> allowed.
- A `deny` binding on `developers` looks like it fences other groups too; it does not.

## Cause
- OpenChoreo 1.3.3 evaluates each entitlement value of the caller separately (deny-overrides within that value), then
  unions the results: a deny on `developers` never revokes an allow granted to `demo-developers`.
- A mapping without `scope` is namespace-wide (AuthzRoleBinding) or cluster-wide (ClusterAuthzRoleBinding).

## Fix
- Group `developers`: read-only roles `cluster-reader` + `namespace-reader` (addon openchoreo-control-plane bootstrap
  mappings). Per tenant: `AuthzRoleBinding <project>-developer-<group>` grants `developer` with `scope.project` only
  (charts/tenant `developer-authz.yaml`, `developerGroups`, default `<project>-developers`).
- Gated environments: put the condition `!(resource.environment in ["default/production"])` on the binding writes of
  the per-project ALLOW itself; repeat every per-group deny (component:delete) for the project groups.
- Cluster-level views (`clustercomponenttype:view`, ...) cannot come from a namespaced AuthzRoleBinding: developers
  still need the org-wide reader group.

## Verify
- MCP `evaluate_authz` with `subject_context {type: user, entitlement_claim: groups, entitlement_values: [<group>]}`,
  `resource {type: projectreleasebinding, hierarchy {namespace, project}}`, `context.resource.environment`.
