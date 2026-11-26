# crossplane

## Purpose

Wrapper chart for Crossplane v2 (`2.4.3`) on workload clusters (on mgmt: core + the Harbor provider, `values/role-mgmt.yaml`, and, per installation, GitHub repository governance: `githubRepos`, the `GitHubRepository` API in `files/github-repository/`): core, the pinned Functions / Providers (PSS `restricted` runtime configs), the PostgreSQL API as the signed Configuration package `platform-postgresql` (from `packages/postgresql`, `tag@digest`, `skipDependencyResolution`), `EnvironmentConfig platform-postgresql` with this cluster's facts (backend from the provider label), MRAP, workload-identity ProviderConfigs and Kyverno policies.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: crossplane-system`, `serverSideDiff: true`; layers `values/provider-docker.yaml` on `docker`, `values/role-mgmt.yaml` on mgmt: `platformAPIs.enabled: false`, `harborProvider.enabled: true`).
- **Catalog label:** `addons.platform.koorikla.io/crossplane` (`default: false`, opt-in with `"true"` per cluster via `addons.crossplane: true`; mgmt: `mgmt.addons.crossplane: true`, required with `registry.type: harbor`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.environment | string | `"development"` |  |
| cluster.name | string | `"sample"` |  |
| cluster.provider | string | `"docker"` |  |
| cluster.region | string | `"local"` |  |
| crossplane.args | list | `[]` |  |
| crossplane.image.repository | string | `"xpkg.crossplane.io/crossplane/crossplane"` |  |
| crossplane.image.tag | string | `"v2.4.3@sha256:1c66261d805a73cade46e2ac94b665c73aebd4a00844de5fcae4bcadaa2be638"` |  |
| crossplane.metrics.enabled | bool | `true` |  |
| crossplane.podSecurityContextCrossplane.runAsNonRoot | bool | `true` |  |
| crossplane.podSecurityContextCrossplane.seccompProfile.type | string | `"RuntimeDefault"` |  |
| crossplane.podSecurityContextRBACManager.runAsNonRoot | bool | `true` |  |
| crossplane.podSecurityContextRBACManager.seccompProfile.type | string | `"RuntimeDefault"` |  |
| crossplane.provider.defaultActivations | list | `[]` | `[]` (`templates/activation-policy.yaml` activates only the APIs used by the active `Composition`). |
| crossplane.rbacManager.replicas | int | `1` |  |
| crossplane.replicas | int | `1` |  |
| crossplane.resourcesCrossplane.limits.cpu | string | `"500m"` |  |
| crossplane.resourcesCrossplane.limits.memory | string | `"1Gi"` |  |
| crossplane.resourcesCrossplane.requests.cpu | string | `"50m"` |  |
| crossplane.resourcesCrossplane.requests.memory | string | `"128Mi"` |  |
| crossplane.resourcesRBACManager.limits.cpu | string | `"100m"` |  |
| crossplane.resourcesRBACManager.limits.memory | string | `"256Mi"` |  |
| crossplane.resourcesRBACManager.requests.cpu | string | `"10m"` |  |
| crossplane.resourcesRBACManager.requests.memory | string | `"64Mi"` |  |
| crossplane.securityContextCrossplane.allowPrivilegeEscalation | bool | `false` |  |
| crossplane.securityContextCrossplane.capabilities.drop[0] | string | `"ALL"` |  |
| crossplane.securityContextCrossplane.readOnlyRootFilesystem | bool | `true` |  |
| crossplane.securityContextCrossplane.runAsGroup | int | `65532` |  |
| crossplane.securityContextCrossplane.runAsNonRoot | bool | `true` |  |
| crossplane.securityContextCrossplane.runAsUser | int | `65532` |  |
| crossplane.securityContextCrossplane.seccompProfile.type | string | `"RuntimeDefault"` |  |
| crossplane.securityContextRBACManager.allowPrivilegeEscalation | bool | `false` |  |
| crossplane.securityContextRBACManager.capabilities.drop[0] | string | `"ALL"` |  |
| crossplane.securityContextRBACManager.readOnlyRootFilesystem | bool | `true` |  |
| crossplane.securityContextRBACManager.runAsGroup | int | `65532` |  |
| crossplane.securityContextRBACManager.runAsNonRoot | bool | `true` |  |
| crossplane.securityContextRBACManager.runAsUser | int | `65532` |  |
| crossplane.securityContextRBACManager.seccompProfile.type | string | `"RuntimeDefault"` |  |
| githubRepos.activate[0] | string | `"repositories.repo.github.m.upbound.io"` |  |
| githubRepos.activate[1] | string | `"repositoryrulesets.repo.github.m.upbound.io"` |  |
| githubRepos.activate[2] | string | `"repositorycollaborators.repo.github.m.upbound.io"` |  |
| githubRepos.activate[3] | string | `"teams.team.github.m.upbound.io"` |  |
| githubRepos.activate[4] | string | `"teamrepositories.team.github.m.upbound.io"` |  |
| githubRepos.credentials.remoteKey | string | `"github-repo-admin"` | Store key with githubAppID, githubAppInstallationID, githubAppPrivateKey of the repo-admin GitHub App. |
| githubRepos.credentials.store | string | `"platform"` |  |
| githubRepos.enabled | bool | `false` | `true` installs `provider-upjet-github`, the `GitHubRepository` API and `githubRepos.repositories` (per installation, on its mgmt only). |
| githubRepos.owner | string | `""` | GitHub account (user or organisation) the App is installed on: the `owner` of every repository. |
| githubRepos.package | string | `"xpkg.crossplane.io/crossplane-contrib/provider-upjet-github:v0.23.0@sha256:3da1fc7df824246e0d31bc55d47d5b5acfcb65d13b3f495027b84fdfbc9b1836"` |  |
| githubRepos.repositories | object | `{}` | GitHub repositories by name: `management` (`Observe` or `Full`, required), `description`, `visibility`, `requiredChecks`, `bypassApps`, `collaborators`, `rulesetId` (XRD `files/github-repository/definition.yaml`). |
| githubRepos.resources.limits.cpu | string | `"500m"` |  |
| githubRepos.resources.limits.memory | string | `"512Mi"` |  |
| githubRepos.resources.requests.cpu | string | `"10m"` |  |
| githubRepos.resources.requests.memory | string | `"128Mi"` |  |
| githubRepos.teams | object | `{}` | GitHub org teams by slug: `{ id, description, repositories: { <repo>: <permission> } }`; `id` (numeric) adopts an existing team. Membership stays in GitHub. |
| harborProvider.activate[0] | string | `"registries.harbor.m.crossplane.io"` |  |
| harborProvider.activate[1] | string | `"projects.harbor.m.crossplane.io"` |  |
| harborProvider.activate[2] | string | `"replications.harbor.m.crossplane.io"` |  |
| harborProvider.activate[3] | string | `"accounts.robot.harbor.m.crossplane.io"` |  |
| harborProvider.activate[4] | string | `"securities.config.harbor.m.crossplane.io"` |  |
| harborProvider.enabled | bool | `false` | `true` on mgmt (`values/role-mgmt.yaml`): installs `provider-upjet-harbor` and activates only the Harbor kinds addon harbor uses. |
| harborProvider.package | string | `"xpkg.crossplane.io/crossplane-contrib/provider-upjet-harbor:v1.4.3@sha256:8f379d7081bfbb1cd8261439d18fe2bc3f1f90aa0dcc05c82065842555659b73"` |  |
| harborProvider.resources.limits.cpu | string | `"500m"` |  |
| harborProvider.resources.limits.memory | string | `"512Mi"` |  |
| harborProvider.resources.requests.cpu | string | `"10m"` |  |
| harborProvider.resources.requests.memory | string | `"96Mi"` |  |
| monitoring.podMonitor | bool | `true` |  |
| mysql.backend | string | `"moco"` |  |
| mysql.configuration | string | `"ghcr.io/koorikla/platform/mysql:v0.3.0@sha256:0ed7c47fd696d14315cf134e3149236c0f05e4f409c87802726ecb8e9cf5c58d"` |  |
| mysql.enabled | string | `"false"` | `"true"` installs the MySQL API (Configuration platform-mysql + EnvironmentConfig + embedded Function); a string because the ApplicationSet passes cluster labels as strings (helm set-string). |
| mysql.function.koorikla-platform-mysqlcompose-mysql | string | `"ghcr.io/koorikla/platform/mysql_compose-mysql:v0.3.0@sha256:c97c760e34e56c745980164eebda4e9643bd5debddb5d371a0cb189b6752d2eb"` |  |
| namespace.podSecurity | string | `"restricted"` |  |
| packages.configuration | string | `"ghcr.io/koorikla/platform/postgresql:v0.2.0@sha256:478419ad87ba4e90756b6826638c6977bfda3d23ecdee48b5fa0bca539ba5be1"` | The PostgreSQL API package (packages/postgresql), release tag vX.Y.Z (release-please postgresql-vX.Y.Z) @digest (a Configuration has one manifest, no index); never the moving `main` tag. The promotion point: per-environment pins go in installations/<inst>/addons/crossplane/env-<env>.yaml. Renovate bumps it. |
| packages.functions.function-auto-ready | string | `"xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.7.3@sha256:cce8799e19a8f25fb84e1f8dd8855021fdbe8cd7a12a5c22a0c0c345476ae9fe"` |  |
| packages.functions.function-environment-configs | string | `"xpkg.crossplane.io/crossplane-contrib/function-environment-configs:v0.9.2@sha256:1e4f74646d274437da6dc94d1323a0be8ccfa2e2497c0e92e6722e870ac4d3f6"` |  |
| packages.functions.function-go-templating | string | `"xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.13.2@sha256:20198cb6ea5b4b8a48042343410ec9031e5ec43431d874364ecd3eac8e861290"` |  |
| packages.functions.koorikla-platform-postgresqlcompose-postgresql | string | `"ghcr.io/koorikla/platform/postgresql_compose-postgresql:v0.2.0@sha256:7f4d5cb26e8ca5d2736a28acea5dadbee07b45d0900d614889ed416b7d2cc2ce"` |  |
| packages.providers.aws-rds.provider-aws-ec2 | string | `"xpkg.crossplane.io/crossplane-contrib/provider-aws-ec2:v2.9.0@sha256:e5c093671479fa349bc8e08ddea44ecaaa2f50ae5d586191b38127a101de5330"` |  |
| packages.providers.aws-rds.provider-aws-kms | string | `"xpkg.crossplane.io/crossplane-contrib/provider-aws-kms:v2.9.0@sha256:59864b9cfbdc5970f2063dd396717bc769b9849c818dac17b3304bf4cef94911"` |  |
| packages.providers.aws-rds.provider-aws-rds | string | `"xpkg.crossplane.io/crossplane-contrib/provider-aws-rds:v2.9.0@sha256:5f46e7bd9dc5152baa835705f0820d66729d659afc3b287bfa4ff60ccab4c307"` |  |
| packages.providers.aws-rds.provider-family-aws | string | `"xpkg.crossplane.io/crossplane-contrib/provider-family-aws:v2.9.0@sha256:4b426b75d6c2b5cbc3270b4c2423c81cfd0ce7e7a7f5f02d2af305ba76944505"` |  |
| packages.providers.azure-flexible.provider-azure-dbforpostgresql | string | `"xpkg.crossplane.io/crossplane-contrib/provider-azure-dbforpostgresql:v2.8.0@sha256:5ea12751afc1c3dc5d9a9de0bf5ee423a8b097287c088111504c98099012c7b9"` |  |
| packages.providers.azure-flexible.provider-family-azure | string | `"xpkg.crossplane.io/crossplane-contrib/provider-family-azure:v2.8.0@sha256:d28c4d7c973edd77d79f279772782eef7eeaa704b9904b098b4c81f58d74f044"` |  |
| packages.providers.cnpg | object | `{}` |  |
| packages.providers.gcp-cloudsql.provider-family-gcp | string | `"xpkg.crossplane.io/crossplane-contrib/provider-family-gcp:v3.1.0@sha256:712ad98847a6484046964fef69b5faef94468ff3d01dbbd53af8c269f1ecac97"` |  |
| packages.providers.gcp-cloudsql.provider-gcp-sql | string | `"xpkg.crossplane.io/crossplane-contrib/provider-gcp-sql:v3.1.0@sha256:e108a2d4b34ff89318e3bd0b891f4321f937ee40d999a0f8a215a6334164bda5"` |  |
| packages.runtimeConfig.name | string | `"restricted"` |  |
| packages.runtimeConfig.providerResources.limits.cpu | string | `"1"` |  |
| packages.runtimeConfig.providerResources.limits.memory | string | `"1Gi"` |  |
| packages.runtimeConfig.providerResources.requests.cpu | string | `"50m"` |  |
| packages.runtimeConfig.providerResources.requests.memory | string | `"256Mi"` |  |
| packages.runtimeConfig.resources.limits.cpu | string | `"500m"` |  |
| packages.runtimeConfig.resources.limits.memory | string | `"512Mi"` |  |
| packages.runtimeConfig.resources.requests.cpu | string | `"10m"` |  |
| packages.runtimeConfig.resources.requests.memory | string | `"64Mi"` |  |
| packages.signatureVerification.enabled | bool | `false` |  |
| packages.signatureVerification.issuer | string | `"https://token.actions.githubusercontent.com"` |  |
| packages.signatureVerification.prefix | string | `"ghcr.io/koorikla/platform/"` |  |
| packages.signatureVerification.subjectRegExp | string | `"^https://github\\.com/(koorikla|Sparky-stack)/platform/\\.github/workflows/app-crossplane-configuration\\.yaml@refs/(heads/main|tags/postgresql-v[0-9.]+)$"` |  |
| platformAPIs | object | `{"enabled":true}` | `false` skips the platform data APIs (PostgreSQL and MySQL packages, EnvironmentConfigs, Functions, compose RBAC, admission policies); `values/role-mgmt.yaml` sets it. |
| policy.enabled | bool | `true` |  |
| policy.exemptNamespaces[0] | string | `"crossplane-system"` |  |
| policy.exemptNamespaces[1] | string | `"cnpg-system"` |  |
| policy.exemptNamespaces[2] | string | `"moco-system"` |  |
| policy.exemptServiceAccountNamespaces[0] | string | `"crossplane-system"` |  |
| policy.exemptServiceAccountNamespaces[1] | string | `"cnpg-system"` |  |
| policy.exemptServiceAccountNamespaces[2] | string | `"moco-system"` |  |
| policy.exemptServiceAccountNamespaces[3] | string | `"kube-system"` |  |
| policy.production.action | string | `"Deny"` | `Deny` on cloud (`Audit` in `values/provider-docker.yaml`) for non-HA or unbacked `production` instances. |
| policy.production.environments[0] | string | `"production"` |  |
| postgresql.aws.identity.roleArn | string | `""` |  |
| postgresql.aws.identity.source | string | `"IRSA"` |  |
| postgresql.aws.nodeSecurityGroupId | string | `""` |  |
| postgresql.aws.region | string | `""` |  |
| postgresql.aws.subnetIds | list | `[]` |  |
| postgresql.aws.vpcId | string | `""` |  |
| postgresql.azure.clientID | string | `""` |  |
| postgresql.azure.delegatedSubnetId | string | `""` |  |
| postgresql.azure.location | string | `""` |  |
| postgresql.azure.privateDnsZoneId | string | `""` |  |
| postgresql.azure.resourceGroupName | string | `""` |  |
| postgresql.azure.subscriptionID | string | `""` |  |
| postgresql.azure.tenantID | string | `""` |  |
| postgresql.backend | string | `""` | Active `Composition` (`postgresql.backendByProvider` maps `cluster.provider` to `cnpg`, `aws-rds`, `gcp-cloudsql`, or `azure-flexible`). |
| postgresql.backendByProvider.aws | string | `"aws-rds"` |  |
| postgresql.backendByProvider.aws-eks | string | `"aws-rds"` |  |
| postgresql.backendByProvider.azure-aks | string | `"azure-flexible"` |  |
| postgresql.backendByProvider.byo | string | `"cnpg"` |  |
| postgresql.backendByProvider.docker | string | `"cnpg"` |  |
| postgresql.backendByProvider.gcp-gke | string | `"gcp-cloudsql"` |  |
| postgresql.backendByProvider.hetzner | string | `"cnpg"` |  |
| postgresql.backendByProvider.vsphere-talos | string | `"cnpg"` |  |
| postgresql.cnpg.backup.credentials.s3Credentials.inheritFromIAMRole | bool | `true` |  |
| postgresql.cnpg.backup.destinationPath | string | `""` |  |
| postgresql.cnpg.backup.serviceAccountAnnotations | object | `{}` |  |
| postgresql.cnpg.imageCatalog | string | `"postgresql-standard"` | Backend-specific image catalog (`postgresql-standard`) and `postgresql.{cnpg,aws,gcp,azure}` subnet/VPC and workload-identity settings. |
| postgresql.cnpg.podMonitor | bool | `true` |  |
| postgresql.gcp.allocatedIpRange | string | `""` |  |
| postgresql.gcp.identity.serviceAccount | string | `""` |  |
| postgresql.gcp.privateNetwork | string | `""` |  |
| postgresql.gcp.project | string | `""` |  |
| postgresql.gcp.region | string | `""` |  |
| registry.type | string | `"external"` |  |

## Day-2 notes

- Values are checked by `values.schema.json` (backend enums, `aws.identity.source`, every package pinned `<repo>:<tag>@sha256:<digest>`; `helm` prints the failing path). Facts each backend needs (aws/gcp/azure ids, a backend for `cluster.provider`) are checked in `templates/validate.yaml`.
- Crossplane v2 installs its own CRDs from its init container: the platform objects here carry `SkipDryRunOnMissingResource` and sync wave 1 (wave 2 for the ProviderConfigs, whose CRDs come with the providers).
- Only the managed resources the active Composition composes are activated (`crossplane.provider.defaultActivations: []` plus `templates/activation-policy.yaml`), which keeps provider CRD count and memory low.
- `githubRepos.repositories` entries must state `management` (`Observe` reads GitHub only, `Full` enforces and reverts drift, never deletes); `githubRepos.teams` declares the four org teams and their `TeamRepository` permissions (no `Delete`, membership stays in GitHub): [GitHub repository governance](../../docs/github-repos.md#day-2).
- Backing up composed CloudNativePG databases and upgrading Crossplane: [backup and restore](../../docs/runbooks/backup-restore.md#6-cloudnativepg-cloudnative-pg) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Crossplane platform APIs](../../docs/crossplane.md), [Crossplane on mgmt](../../docs/crossplane.md#crossplane-on-mgmt), [GitHub repository governance](../../docs/github-repos.md)
- [Data services: PostgreSQL as a service](../../docs/data-services.md#postgresql-as-a-service)