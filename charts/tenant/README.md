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
| demoSecrets | list | `[]` | DEMO ONLY: OpenBao values seeded into `kv-tenant-<project>` (`[{key, property}]`, the app's `SecretReference` `remoteRef`s) by `PushSecret/<project>-seed-<key>` (ESO `Password` generator, `updatePolicy: IfNotExists`) with the tenant's own writer identity; a missing property gets a generated `demo-only-<hex>` value, an existing one is never overwritten. One entry per key (a lowercase DNS label). Needs `secrets.tenantStores.enabled`; never list real secrets ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)). |
| deploymentPipeline.environments | list | `["development","staging","production"]` | Environments (`development`, `staging`, `production`) provisioned via `ProjectReleaseBinding`. |
| deploymentPipeline.name | string | `"default"` |  |
| description | string | `""` |  |
| developerGroups | list | `[]` | Groups (JWT claim `groups`) that develop this project: OpenChoreo role `developer` scoped to this project only, binding writes in `promotion.gatedEnvironments` excluded (`templates/developer-authz.yaml`). Empty = `[<project>-developers]`. Members also need group `developers` for the org-wide read-only views (component types, environments). |
| developerKinds | list | `["Component","Workload","ReleaseBinding","ComponentRelease","SecretReference","Resource","ResourceReleaseBinding"]` | The only kinds (group openchoreo.dev, org namespace) an app repo may sync; Project, ProjectReleaseBinding and platform kinds stay platform-owned. |
| developerRole | string | `"developer"` |  |
| installation.githubOrg | string | `"https://github.com/koorikla"` |  |
| installation.name | string | `"local"` |  |
| installation.repoURL | string | `"https://github.com/Sparky-stack/platform.git"` |  |
| installation.revision | string | `"main"` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| previewOptIn.annotation | string | `"platform.koorikla.io/preview-environments"` |  |
| previewOptIn.value | string | `"enabled"` |  |
| previewProject | string | `"previews"` |  |
| previewToken.secretName | string | `"preview-github-token"` |  |
| previews.botLabel | string | `"preview"` |  |
| previews.dataPlane | string | `"dev1"` |  |
| previews.enabled | bool | `false` | Enables `ApplicationSet/previews-<project>` (`previews.*`, `previewOptIn`, `previewToken`: opted-in Components x open pull requests -> one `charts/preview` Application per PR; [preview environments](../../docs/preview-environments.md)). |
| previews.expiredLabel | string | `"preview-expired"` |  |
| previews.grantedLabel | string | `"preview-granted"` |  |
| previews.requeueAfterSeconds | int | `1800` |  |
| previews.skipBots | bool | `true` |  |
| project | string | `""` | OpenChoreo `Project` name (DNS-1123 label) and `AppProject/tenant-<project>` (alongside `description`). |
| projectType.kind | string | `"ClusterProjectType"` |  |
| projectType.name | string | `"default"` |  |
| promotion.bindingFile | string | `"release-bindings/{environment}.yaml"` |  |
| promotion.bindingWriteActions[0] | string | `"releasebinding:create"` |  |
| promotion.bindingWriteActions[1] | string | `"releasebinding:update"` |  |
| promotion.bindingWriteActions[2] | string | `"releasebinding:delete"` |  |
| promotion.bindingWriteActions[3] | string | `"projectreleasebinding:create"` |  |
| promotion.bindingWriteActions[4] | string | `"projectreleasebinding:update"` |  |
| promotion.bindingWriteActions[5] | string | `"projectreleasebinding:delete"` |  |
| promotion.bindingWriteActions[6] | string | `"resourcereleasebinding:create"` |  |
| promotion.bindingWriteActions[7] | string | `"resourcereleasebinding:update"` |  |
| promotion.bindingWriteActions[8] | string | `"resourcereleasebinding:delete"` |  |
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
| tenantSecrets.demoSeed.addr | string | `"https://openbao-active.openbao.svc:8200"` |  |
| tenantSecrets.demoSeed.audience | string | `"openbao"` |  |
| tenantSecrets.demoSeed.caSecret | string | `"openbao-ca"` |  |
| tenantSecrets.demoSeed.loginRole | string | `"tenant-writer"` |  |
| tenantSecrets.demoSeed.refreshInterval | string | `"5m"` |  |
| tenantSecrets.label | string | `"openbao.platform.koorikla.io/tenant"` |  |
| tenantSecrets.namespace | string | `"openbao-tenants"` |  |

## Day-2 notes

- Blocked promotions, freeze windows, or stuck tenant syncs: [incidents](../../docs/runbooks/incidents.md#promotion-gate-failing-closed) and [break-glass](../../docs/runbooks/break-glass.md).

## Links

- [OpenChoreo: Tenants](../../docs/openchoreo.md#tenants)
- [Promotion gates](../../docs/promotion.md)