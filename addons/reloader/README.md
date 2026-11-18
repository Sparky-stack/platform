# reloader

## Purpose

Wrapper chart for Stakater Reloader (`2.2.20` / `v1.4.24`), scoped strictly to explicit namespaces (no `ClusterRole`). Rolls `openchoreo-data-plane` `cluster-agent-dataplane` on TLS renewal on workload clusters, and `openchoreo-control-plane` Backstage on `ConfigMap` changes on `mgmt`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: reloader`).
- **Catalog label:** `addons.platform.koorikla.io/reloader` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| reloader.fullnameOverride | string | `"reloader"` |  |
| reloader.image.repository | string | `"ghcr.io/stakater/reloader"` |  |
| reloader.image.tag | string | `"v1.4.24@sha256:3ab43d3eb96c59798644bf826b0444a846c0197d22ab4b6c101c4da3e1d6ef23"` |  |
| reloader.reloader.deployment.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| reloader.reloader.deployment.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| reloader.reloader.deployment.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| reloader.reloader.deployment.resources.limits.cpu | string | `"100m"` |  |
| reloader.reloader.deployment.resources.limits.memory | string | `"128Mi"` |  |
| reloader.reloader.deployment.resources.requests.cpu | string | `"10m"` |  |
| reloader.reloader.deployment.resources.requests.memory | string | `"32Mi"` |  |
| reloader.reloader.deployment.securityContext.runAsGroup | int | `65534` |  |
| reloader.reloader.deployment.securityContext.runAsNonRoot | bool | `true` |  |
| reloader.reloader.deployment.securityContext.runAsUser | int | `65534` |  |
| reloader.reloader.deployment.securityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| reloader.reloader.ignoreCronJobs | bool | `true` |  |
| reloader.reloader.ignoreJobs | bool | `true` |  |
| reloader.reloader.namespaces | list | `["openchoreo-data-plane"]` | Watched namespaces (`[openchoreo-control-plane]` in `values/role-mgmt.yaml` with `autoReloadAll`, `resourceLabelSelector` and `ignoreSecrets: true`). |
| reloader.reloader.readOnlyRootFileSystem | bool | `true` |  |
| reloader.reloader.reloadStrategy | string | `"annotations"` |  |
| reloader.reloader.watchGlobally | bool | `false` | Scoped Role + RoleBinding per watched namespace (enforced `false` by `templates/validate.yaml`; no `ClusterRole`). |

## Day-2 notes

- Agent certificate rotation and reload checks: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#3-openchoreo-agent-certificates) and [incidents](../../docs/runbooks/incidents.md#data-plane-agent-disconnected).

## Links

- [OpenChoreo: Trust model](../../docs/openchoreo.md#trust-model)