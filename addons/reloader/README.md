# reloader

## Purpose

Wrapper chart for Stakater Reloader (`2.2.20` / `v1.4.24`), scoped strictly to explicit namespaces (no `ClusterRole`). Rolls `openchoreo-data-plane` `cluster-agent-dataplane` on TLS renewal on workload clusters, and `openchoreo-control-plane` Backstage on `ConfigMap` changes on `mgmt`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: reloader`).
- **Catalog label:** `addons.platform.koorikla.io/reloader` (`default: true`, opt-out with `"false"`).

## Key values

- `reloader.reloader.watchGlobally`: `false` (enforced by `templates/validate.yaml`; prevents cross-namespace Secret RBAC).
- `reloader.reloader.namespaces`: `[openchoreo-data-plane]` on workload clusters; `[openchoreo-control-plane]` in `values/role-mgmt.yaml`.
- `reloader.reloader.{autoReloadAll,resourceLabelSelector,ignoreSecrets}` (`values/role-mgmt.yaml`): watches only `app.kubernetes.io/component=backstage` `ConfigMap`s with `ignoreSecrets: true`.

## Day-2 notes

- Agent certificate rotation and reload checks: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#3-openchoreo-agent-certificates) and [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected).

## Links

- [OpenChoreo: Trust model](../../docs/openchoreo.md#trust-model)
