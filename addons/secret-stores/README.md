# secret-stores

## Purpose

Renders External Secrets Operator `ClusterSecretStore`s, scoped reader RBAC, and Argo CD's `platform-repo-creds` `ExternalSecret`. Separates platform secrets (`platform`, `workflows`, `mgmt-fleet`, `mgmt-openchoreo` on `mgmt`; `mgmt-harbor` lives in addon harbor) from workload tenant (`default`) and Cloudflare DNS (`dns`) stores.

Every store and its identity (ServiceAccount, plus a reader Role on the kubernetes backend) comes from one helper, `secret-stores.store` (`templates/_helpers.tpl`); `templates/stores.yaml` only lists what differs per store.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: external-secrets`; layers `values/role-<role>.yaml`).
- **Catalog label:** `addons.platform.koorikla.io/secret-stores` (`default: true`, opt-out with `"false"`).

## Key values

- `secrets.backend`: `kubernetes` (`platform-secrets` / `openchoreo-secrets`), `aws`, or `vault`.
- `platformStore.namespaces`: explicit `mgmt` namespaces permitted to reference `ClusterSecretStore/platform`.
- `workflowStore.{namespaceRegexes,keys}` and `secrets.workflowStore`: least-privilege `workflows` store for `workflows-*` build and promotion runs.
- `dnsStore.namespaces` and `secrets.dnsStore`: isolates Cloudflare `DNS:Edit` credentials in `ClusterSecretStore/dns` (`external-dns` only).
- `secrets.tenantStores.enabled` + `tenantStores.*` (workload): per-tenant OpenBao `SecretStore/openbao-tenant` in every OpenChoreo cell namespace (Kyverno `GeneratingPolicy`), `ValidatingAdmissionPolicies` that allow tenant namespaces no other store, and `ClusterSecretStore/default` conditions that exclude them ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)).
- `delivery.*` (`values/provider-byo.yaml`): `ClusterSecretStore/delivery` on byo clusters, name-scoped to the public material mgmt pushes into `platform-delivery` ([byo](../../docs/providers.md#bring-your-own-cluster-byo)).
- `repoCreds.{auth,remoteKey}`: `token` (PAT) or `githubApp` credentials for Argo CD.

## Day-2 notes

- Rotating GitHub App keys, PATs, and ESO-backed secrets: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#4-github-app-keys-and-registry-pats).

## Links

- [Architecture: Secrets](../../docs/architecture.md#secrets-one-store-name-pluggable-backends)
- [Conventions: Secret keys](../../docs/conventions.md#secret-keys)
