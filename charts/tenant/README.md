# tenant

## Purpose

Registers one OpenChoreo tenant project from `installations/<inst>/tenants/<project>.yaml`: renders `AppProject/tenant-<project>` (scoped to developer kinds and the org's repos), OpenChoreo `Project` + `ProjectReleaseBinding`s, per-app Argo CD `Application`s, and gated-environment `Application`s + ABAC rules.

## Where it runs

- **Target:** `mgmt` cluster (`argocd` and `openchoreo.orgNamespace`), rendered by `ApplicationSet/tenants` as `Application/tenant-<project>`.
- **Selection:** Not a catalog addon; generated for every `installations/<inst>/tenants/<project>.yaml` file.

## Key values

- `project`, `description`: OpenChoreo `Project` name (DNS-1123 label) and `AppProject/tenant-<project>`.
- `apps[]`: `{name, repoURL, path, revision, promotionGates}`; `name` must equal the app repo's `Component` name.
- `deploymentPipeline.{name,environments}`: environments (`development`, `staging`, `production`) provisioned via `ProjectReleaseBinding`.
- `developerKinds`: allowlisted OpenChoreo developer CRDs (`Component`, `Workload`, `ReleaseBinding`, `ComponentRelease`, `SecretReference`).
- `secrets.tenantStores.enabled` (from `installation.yaml`), `tenantSecrets.{namespace,label}`: per-tenant OpenBao secrets: descriptor `Secret/<project>-openbao-tenant` (the project's cell namespaces, computed like OpenChoreo names them) and `ServiceAccount/<project>-writer` in `openbao-tenants` ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)).
- `promotion.{gatedEnvironments,restrictedGroups,bindingFile,freezeWindows}`: separate gated `Application`s, ABAC component-delete deny, and sync freeze windows.

## Day-2 notes

- Blocked promotions, freeze windows, or stuck tenant syncs: [incidents](../../docs/runbooks/incidents.md#promotion-gate-failing-closed) and [break-glass](../../docs/runbooks/break-glass.md).

## Links

- [OpenChoreo: Tenants](../../docs/openchoreo.md#tenants)
- [Promotion gates](../../docs/promotion.md)
