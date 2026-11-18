# tenant

## Purpose

Registers one OpenChoreo tenant project from `installations/<inst>/tenants/<project>.yaml`: renders `AppProject/tenant-<project>` (scoped to developer kinds and the org's repos), OpenChoreo `Project` + `ProjectReleaseBinding`s, per-app Argo CD `Application`s, and gated-environment `Application`s + ABAC rules.

## Where it runs

- **Target:** `mgmt` cluster (`argocd` and `openchoreo.orgNamespace`), rendered by `ApplicationSet/tenants` as `Application/tenant-<project>`.
- **Selection:** Not a catalog addon; generated for every `installations/<inst>/tenants/<project>.yaml` file.

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| apps | list | `[]` | Tenant applications (`[{name, repoURL, path, revision, promotionGates}]`; `name` must equal the app repo's `Component` name). |
| argocd.namespace | string | `"argocd"` |  |
| argocd.server | string | `"https://kubernetes.default.svc"` |  |
| defaults.path | string | `"deploy/openchoreo"` |  |
| defaults.revision | string | `"main"` |  |
| deploymentPipeline.environments | list | `["development","staging","production"]` | Environments (`development`, `staging`, `production`) provisioned via `ProjectReleaseBinding`. |
| deploymentPipeline.name | string | `"default"` |  |
| description | string | `""` |  |
| developerKinds | list | `["Component","Workload","ReleaseBinding","ComponentRelease","SecretReference","Resource","ResourceReleaseBinding"]` | Allowlisted OpenChoreo developer CRDs. |
| installation.githubOrg | string | `"https://github.com/koorikla"` |  |
| installation.name | string | `"local"` |  |
| installation.repoURL | string | `"https://github.com/koorikla/platform.git"` |  |
| installation.revision | string | `"main"` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| previewOptIn.annotation | string | `"platform.koorikla.io/preview-environments"` |  |
| previewOptIn.value | string | `"enabled"` |  |
| previewProject | string | `"previews"` |  |
| previewToken.secretName | string | `"preview-github-token"` |  |
| previews.dataPlane | string | `"dev1"` |  |
| previews.enabled | bool | `false` | Enables `ApplicationSet/previews-<project>` (`previews.*`, `previewOptIn`, `previewToken`: opted-in Components x open pull requests -> one `charts/preview` Application per PR; [preview environments](../../docs/preview-environments.md)). |
| previews.expiredLabel | string | `"preview-expired"` |  |
| previews.requeueAfterSeconds | int | `1800` |  |
| project | string | `""` | OpenChoreo `Project` name (DNS-1123 label) and `AppProject/tenant-<project>` (alongside `description`). |
| projectType.kind | string | `"ClusterProjectType"` |  |
| projectType.name | string | `"default"` |  |
| promotion.bindingFile | string | `"release-bindings/{environment}.yaml"` |  |
| promotion.componentDeleterRole | string | `"promotion-component-deleter"` |  |
| promotion.freezeWindows[0].end | string | `"Mon 08:00"` |  |
| promotion.freezeWindows[0].environments[0] | string | `"production"` |  |
| promotion.freezeWindows[0].name | string | `"weekend"` |  |
| promotion.freezeWindows[0].start | string | `"Fri 16:00"` |  |
| promotion.freezeWindows[0].timeZone | string | `"Europe/Tallinn"` |  |
| promotion.gatedEnvironments | list | `["production"]` | Environments with separate gated `Application`s, ABAC component-delete deny (`restrictedGroups`), and `freezeWindows`. |
| promotion.restrictedGroups[0] | string | `"developers"` |  |
| secrets.tenantStores.enabled | bool | `false` | Enables per-tenant OpenBao secrets (`tenantSecrets.{namespace,label}`: descriptor `Secret/<project>-openbao-tenant` and `ServiceAccount/<project>-writer` in `openbao-tenants`; [Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)). |
| sourceIntegrity.enabled | bool | `false` |  |
| sourceIntegrity.keys[0] | string | `"B5690EEEBB952194"` |  |
| sourceIntegrity.mode | string | `"head"` |  |
| sourceIntegrity.repos[0] | string | `"{{ .Values.installation.githubOrg }}/*"` |  |
| tenantSecrets.label | string | `"openbao.platform.koorikla.io/tenant"` |  |
| tenantSecrets.namespace | string | `"openbao-tenants"` |  |

## Day-2 notes

- Blocked promotions, freeze windows, or stuck tenant syncs: [incidents](../../docs/runbooks/incidents.md#promotion-gate-failing-closed) and [break-glass](../../docs/runbooks/break-glass.md).

## Links

- [OpenChoreo: Tenants](../../docs/openchoreo.md#tenants)
- [Promotion gates](../../docs/promotion.md)