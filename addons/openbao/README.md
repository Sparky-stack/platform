# openbao

## Purpose

Wrapper chart for `openbao` (`0.30.7` / `v2.7.2`) on `mgmt`. Runs the Istio multicluster mesh CA and, opt-in, the per-tenant secret backend (one root + intermediate PKI mount per `mesh.groups` entry with private keys generated inside OpenBao), per-member Kubernetes JWT auth, static auto-unseal via ESO, and a TLS-passthrough `Gateway`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openbao`).
- **Catalog label:** `addons.platform.koorikla.io/openbao` (`default: false`, opt-in via `installation.yaml` `mgmt.addons.openbao: "true"`).

## Key values

- `mesh.{groups,ca.host,ca.port}`: mesh groups reconciled into PKI mounts and the passthrough endpoint.
- `unseal.{store,remoteKey,secretName}`: pulls `openbao-unseal` from `ClusterSecretStore/platform` for static auto-unseal.
- `pki.{trustDomain,allowedDomains,workloadTTL,rootTTL,intermediateTTL}`: X.509 constraints (`cluster.local`, `24h` leaf TTL).
- `secrets.tenantStores.enabled` + `tenantSecrets.*`: per-tenant KV v2 mounts `kv-tenant-<tenant>`, JWT auth `tenants-<cluster>` per mesh member and the CronJob `tenant-reconcile` (static templated policies `tenant-read` / `tenant-write` from self-initialisation) ([Tenant secrets](../../docs/multicluster.md#tenant-secrets-openbao)).
- `caPublic.{store,secretName,namespaces}`: publishes root/CA bundles through `ClusterSecretStore/mgmt-openbao` to `fleet`.

## Day-2 notes

- Raft backup/restore, sealed recovery, and local re-init: [backup and restore](../../docs/runbooks/backup-restore.md#3-openbao-raft-storage-and-unseal-key), [incidents](../../docs/runbooks/incidents.md#openbao-sealed), and [break-glass](../../docs/runbooks/break-glass.md#openbao-local-re-initialization).
- Mesh CA rotation: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#2-openbao-mesh-ca-openbao--istio-csr).

## Links

- [Multicluster: Mesh CA (OpenBao)](../../docs/multicluster.md#mesh-ca-openbao)
