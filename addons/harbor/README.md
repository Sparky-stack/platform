# harbor

## Purpose

Wrapper chart for Harbor (`1.19.4` / `v2.15.4`) on `mgmt`. Hosts the `apps` project for in-cluster builds and upstream pull-through proxy caches (`dockerhub`, `ghcr`, `quay`, `k8s`, `openchoreo`, `gcr`) for cluster nodes, with TLS from a `mgmt`-local CA and declarative project reconciliation.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: harbor`).
- **Catalog label:** `addons.platform.koorikla.io/harbor` (`default: true`; cloud/external-registry installations set `mgmt.addons.harbor: "false"`).

## Key values

- `registry.{type,host,appsProject,proxyCache}`: registry hostname (`harbor.externalURL` via `installationParameters`), build target project, and upstream proxy cache projects.
- `secrets.{store,remoteKey,ghcrKey,secretName}`: pulls Harbor admin, robot, and component credentials from `ClusterSecretStore/platform`.
- `pki.{caIssuer,tlsSecret}` and `gateway.{name,className}`: issues `harbor-tls` in `harbor`, exposes Harbor via `kgateway`, and exports the public CA via `ClusterSecretStore/mgmt-harbor`.

## Day-2 notes

- Database/blob backups and node registry secret recovery: [backup and restore](../../docs/runbooks/backup-restore.md#5-harbor-harbor) and [break-glass](../../docs/runbooks/break-glass.md#blocked-cluster-sync-on-node-registry-secret).

## Links

- [Build plane: Harbor](../../docs/build-plane.md#registry-harbor)
