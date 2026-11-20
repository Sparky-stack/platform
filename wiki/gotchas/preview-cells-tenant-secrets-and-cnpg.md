---
title: Preview Cells - Tenant Secrets and CloudNativePG under Cilium
created: 2026-11-20
updated: 2026-11-20
type: gotcha
tags: [previews, openbao, cilium, cloudnative-pg, kyverno]
confidence: high
---

# Preview Cells - Tenant Secrets and CloudNativePG under Cilium

## Symptom
- A PR preview pod with a `SecretReference` stays in `CreateContainerConfigError`; SecretStore `openbao-tenant` in the
  cell is `InvalidProviderConfig`, ESO logs `claim "sub" does not match any associated bound claim values` (#267).
- A preview's own database never gets Ready: its PVC is denied by the preview ResourceQuota, and the CNPG pods cannot
  reach the API server (#331).

## Cause
- OpenBao binds a tenant role to an explicit namespace list. charts/tenant lists only pipeline environments; a preview
  cell namespace (`dp-<org>-<project>-pr-<n>-<component>`, hashed) appears per pull request.
- `previewGuards.quota.requests.storage` was 5Gi; ClusterResourceType `postgresql` has `storageGiB` minimum 10.
- Cilium does not match `ipBlock` rules against the `kube-apiserver` / `host` identities, so `ipBlock 0.0.0.0/0`
  egress does not reach the API. Every CNPG pod runs the instance manager, and initdb jobs also wait for the Cluster
  object through the API (`management.WaitForGetCluster`). Job pods carry `cnpg.io/jobRole`, not `cnpg.io/podRole`.

## Fix
- Addon openbao `templates/tenant-previews.yaml`: Kyverno writes a descriptor per preview ProjectReleaseBinding
  (tenant = `spec.owner.projectName`). `tenant-reconcile.sh` computes the namespace itself (`cell_namespace`, same as
  charts/tenant `tenant.cellNamespace`), so a preview can never claim another tenant's namespace.
- Addon kyverno-policies: quota 15Gi (contract test against the type's minimum); with `cluster.cni == cilium` a
  generated CiliumNetworkPolicy allows `toEntities: [kube-apiserver]` only for CNPG instance / job pods, excluding
  `openchoreo.dev/component` workloads.
- Avoid globs on OpenBao `bound_claims` for previews: OpenChoreo truncates each name part (13/13/13/12 chars), so a
  prefix glob of one project can match another's namespaces, and unbound aliases get entities without `tenant` metadata.
