# secret-stores

## Purpose

Renders External Secrets Operator `ClusterSecretStore`s, scoped reader RBAC, and Argo CD's `platform-repo-creds` `ExternalSecret`. Separates platform secrets (`platform`, `workflows`, `mgmt-fleet`, `mgmt-openchoreo` on `mgmt`; `mgmt-harbor` lives in addon harbor) from workload tenant (`default`) and Cloudflare DNS (`dns`) stores.

Every store and its identity (ServiceAccount, plus a reader Role on the kubernetes backend) comes from one helper, `secret-stores.store` (`templates/_helpers.tpl`); `templates/stores.yaml` validates each role's values once at the top, then lists only what differs per store. Per-tenant OpenBao `SecretStore`s and their admission policies: `templates/tenant-stores.yaml`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: external-secrets`; layers `values/role-<role>.yaml`).
- **Catalog label:** `addons.platform.koorikla.io/secret-stores` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| delivery.enabled | bool | `false` | `ClusterSecretStore/delivery` on byo clusters (`values/provider-byo.yaml`), name-scoped to the public material mgmt pushes into `platform-delivery` ([byo](../../docs/providers.md#bring-your-own-cluster-byo)). |
| delivery.keys[0] | string | `"cluster-gateway-ca"` |  |
| delivery.keys[1] | string | `"platform-image-verification"` |  |
| delivery.namespace | string | `"platform-delivery"` |  |
| delivery.namespaces[0] | string | `"openchoreo-data-plane"` |  |
| delivery.namespaces[1] | string | `"kyverno"` |  |
| dns.provider | string | `"none"` |  |
| dnsStore.namespaces | list | `["external-dns"]` | Isolates Cloudflare `DNS:Edit` credentials in `ClusterSecretStore/dns` (`external-dns` only, with `secrets.dnsStore`). |
| installation.githubOrg | string | `"https://github.com/Sparky-stack"` |  |
| platformStore.namespaces | list | `["argocd","fleet","capa-system","dex","thunder","openchoreo-control-plane","openchoreo-observability-plane","falco","argo-events","harbor","openbao","external-dns","agentgateway-system","crossplane-system"]` | Explicit `mgmt` namespaces permitted to reference `ClusterSecretStore/platform`. |
| previewToken.githubKey | string | `"promotion-gate-github"` |  |
| previewToken.namespace | string | `"argocd"` |  |
| previewToken.permissions.pull_requests | string | `"read"` |  |
| previewToken.refreshInterval | string | `"30m"` |  |
| previewToken.secretName | string | `"preview-github-token"` | Pull-request-read installation token (`previewToken.*` with `previews.enabled`) of the platform GitHub App for the preview ApplicationSets (`argocd/preview-github-token`). |
| previews.enabled | bool | `false` |  |
| registry.external.credentialsKey | string | `"platform-ghcr"` |  |
| registry.type | string | `"harbor"` |  |
| repoCreds.auth | string | `"token"` |  |
| repoCreds.name | string | `"platform-repo-creds"` |  |
| repoCreds.namespace | string | `"argocd"` |  |
| repoCreds.remoteKey | string | `"platform-github"` | `token` (PAT) or `githubApp` credentials (`repoCreds.{auth,remoteKey}`) for Argo CD. |
| role | string | `"mgmt"` |  |
| secrets.aws.prefix | string | `""` |  |
| secrets.aws.region | string | `"eu-central-1"` |  |
| secrets.aws.role | string | `""` |  |
| secrets.backend | string | `"kubernetes"` | `kubernetes` (`platform-secrets` / `openchoreo-secrets`), `aws`, or `vault`. |
| secrets.dnsStore.aws.role | string | `""` |  |
| secrets.dnsStore.kubernetes.namespace | string | `"external-dns-credentials"` |  |
| secrets.dnsStore.vault.path | string | `""` |  |
| secrets.dnsStore.vault.role | string | `""` |  |
| secrets.kubernetes.namespace | string | `"platform-secrets"` |  |
| secrets.tenantStores.enabled | bool | `false` | Per-tenant OpenBao `SecretStore/openbao-tenant` (`tenantStores.*`) in every OpenChoreo cell namespace ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)). |
| secrets.vault.auth.kubernetes.mountPath | string | `"kubernetes"` |  |
| secrets.vault.auth.kubernetes.role | string | `"external-secrets"` |  |
| secrets.vault.path | string | `"platform"` |  |
| secrets.vault.server | string | `"https://vault.example.com"` |  |
| secrets.vault.version | string | `"v2"` |  |
| secrets.workflowStore.aws.role | string | `""` |  |
| secrets.workflowStore.vault.path | string | `""` |  |
| secrets.workflowStore.vault.role | string | `"external-secrets-workflows"` |  |
| secrets.workloadKubernetes.namespace | string | `"openchoreo-secrets"` |  |
| tenantStores.audience | string | `"openbao-tenant-secrets"` |  |
| tenantStores.caSecret.key | string | `"ca.crt"` |  |
| tenantStores.caSecret.name | string | `"openbao-ca"` |  |
| tenantStores.caSecret.namespace | string | `"istio-system"` |  |
| tenantStores.serviceAccount | string | `"openbao-tenant"` |  |
| tenantStores.storeName | string | `"openbao-tenant"` |  |
| tenantStores.storeWriters[0] | string | `"system:serviceaccount:kyverno:kyverno-background-controller"` |  |
| tenantStores.tenantLabel | string | `"openchoreo.dev/project"` |  |
| tenantStores.tokenExpirationSeconds | int | `600` |  |
| workflowStore.keys[0] | string | `"cosign-platform"` |  |
| workflowStore.keys[1] | string | `"harbor"` |  |
| workflowStore.keys[2] | string | `"promotion-gate"` |  |
| workflowStore.keys[3] | string | `"promotion-gate-github"` |  |
| workflowStore.namespaceRegexes | list | `["^workflows-.+$"]` | Least-privilege `workflows` store (`workflowStore.{namespaceRegexes,keys}` and `secrets.workflowStore`) for `workflows-*` build and promotion runs. |

## Day-2 notes

- A rejected render names the bad value: `values.schema.json` checks types, formats and enums (Helm prints `at '/<path>'`); cross-field rules live in `templates/validate.yaml`.
- Rotating GitHub App keys, PATs, and ESO-backed secrets: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#4-github-app-keys-and-registry-pats).

## Links

- [Architecture: Secrets](../../docs/architecture.md#secrets-one-store-name-pluggable-backends)
- [Conventions: Secret keys](../../docs/conventions.md#secret-keys)