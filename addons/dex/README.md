# dex

## Purpose

Wrapper chart for Dex (`0.26.0` / `v2.46.1`). Runs on `mgmt` as a temporary OIDC broker mapping GitHub org teams (`Sparky-stack:<team>`) into the OIDC `groups` claim for ThunderID until `thunder-id/thunderid#7069` ships native GitHub teams support.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: dex`).
- **Catalog label:** `addons.platform.koorikla.io/dex` (`default: false`, opt-in with `"true"` on `mgmt` when `secrets.githubLogin.enabled` is true).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| dex.config.connectors[0].config.clientID | string | `"$GITHUB_CLIENT_ID"` |  |
| dex.config.connectors[0].config.clientSecret | string | `"$GITHUB_CLIENT_SECRET"` |  |
| dex.config.connectors[0].config.orgs[0].name | string | `"Sparky-stack"` |  |
| dex.config.connectors[0].config.redirectURI | string | `"http://dex.openchoreo.localhost:8080/callback"` |  |
| dex.config.connectors[0].config.teamNameField | string | `"slug"` |  |
| dex.config.connectors[0].config.useLoginAsID | bool | `true` |  |
| dex.config.connectors[0].id | string | `"github"` |  |
| dex.config.connectors[0].name | string | `"GitHub"` |  |
| dex.config.connectors[0].type | string | `"github"` |  |
| dex.config.issuer | string | `"http://dex.openchoreo.localhost:8080"` |  |
| dex.config.oauth2.skipApprovalScreen | bool | `true` |  |
| dex.config.staticClients[0].id | string | `"thunder"` |  |
| dex.config.staticClients[0].name | string | `"ThunderID"` |  |
| dex.config.staticClients[0].redirectURIs[0] | string | `"http://thunder.openchoreo.localhost:8080/gate/callback"` |  |
| dex.config.staticClients[0].secretEnv | string | `"THUNDER_CLIENT_SECRET"` |  |
| dex.config.storage.type | string | `"memory"` |  |
| dex.config.web.http | string | `"0.0.0.0:5556"` |  |
| dex.envVars[0].name | string | `"GITHUB_CLIENT_ID"` |  |
| dex.envVars[0].valueFrom.secretKeyRef.key | string | `"github-client-id"` |  |
| dex.envVars[0].valueFrom.secretKeyRef.name | string | `"dex-secrets"` |  |
| dex.envVars[1].name | string | `"GITHUB_CLIENT_SECRET"` |  |
| dex.envVars[1].valueFrom.secretKeyRef.key | string | `"github-client-secret"` |  |
| dex.envVars[1].valueFrom.secretKeyRef.name | string | `"dex-secrets"` |  |
| dex.envVars[2].name | string | `"THUNDER_CLIENT_SECRET"` |  |
| dex.envVars[2].valueFrom.secretKeyRef.key | string | `"thunder-client-secret"` |  |
| dex.envVars[2].valueFrom.secretKeyRef.name | string | `"dex-secrets"` |  |
| dex.fullnameOverride | string | `"dex"` |  |
| dex.httpRoute.enabled | bool | `true` | Exposes `dex.<openchoreo.controlPlane.host>` via `openchoreo-control-plane/gateway-default`. |
| dex.httpRoute.hostnames[0] | string | `"dex.openchoreo.localhost"` |  |
| dex.httpRoute.parentRefs[0].name | string | `"gateway-default"` |  |
| dex.httpRoute.parentRefs[0].namespace | string | `"openchoreo-control-plane"` |  |
| dex.image.pullPolicy | string | `"IfNotPresent"` |  |
| dex.image.repository | string | `"ghcr.io/dexidp/dex"` |  |
| dex.image.tag | string | `"v2.46.1@sha256:65b72ca0f4b0bf6d4ada84ec21da8851782563404ac7b8f926923d27ceced9ab"` | Multi-arch index digest of `v2.46.1` (`amd64`, `arm64`, `arm/v7`, `ppc64le`, `s390x`). |
| dex.ingress.enabled | bool | `false` |  |
| dex.podSecurityContext.fsGroup | int | `1001` |  |
| dex.podSecurityContext.runAsGroup | int | `1001` |  |
| dex.podSecurityContext.runAsNonRoot | bool | `true` |  |
| dex.podSecurityContext.runAsUser | int | `1001` |  |
| dex.podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| dex.rbac.create | bool | `false` |  |
| dex.rbac.createClusterScoped | bool | `false` |  |
| dex.replicaCount | int | `1` | Single replica with `storage.type: memory`: Dex only holds short-lived OAuth state during the GitHub redirect (Thunder owns user sessions and refresh tokens), so memory storage avoids CRDs, ClusterRole, DB, and leftover CRDs when Dex is removed. For HA production, switch to `storage.type: kubernetes` + `rbac.create: true` (or postgres). |
| dex.resources.limits.memory | string | `"128Mi"` |  |
| dex.resources.requests.cpu | string | `"50m"` |  |
| dex.resources.requests.memory | string | `"64Mi"` |  |
| dex.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| dex.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| dex.securityContext.readOnlyRootFilesystem | bool | `true` |  |
| dex.volumeMounts[0].mountPath | string | `"/tmp"` |  |
| dex.volumeMounts[0].name | string | `"tmp"` |  |
| dex.volumes[0].emptyDir | object | `{}` |  |
| dex.volumes[0].name | string | `"tmp"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` |  |
| secrets.name | string | `"dex-secrets"` |  |
| secrets.remoteKey | string | `"github-login"` |  |
| secrets.store | string | `"platform"` | ExternalSecret pulling GitHub OAuth credentials and the Dex<->Thunder client secret from `ClusterSecretStore/platform`. |

## Day-2 notes

- Uses single-replica `storage.type: memory` with `rbac.create: false` (no CRDs, no DB, clean removal in one PR); for HA production switch to `storage.type: kubernetes` + `rbac.create: true` or postgres.
- Credentials arrive via `ExternalSecret/dex-secrets` from `ClusterSecretStore/platform` (`github-login`); `templates/validate.yaml` rejects inline literals and host drift.
- `coredns-local` already rewrites `*.openchoreo.localhost` to `gateway-default`, so Thunder reaches `http://dex.openchoreo.localhost:8080` from inside the cluster.

## Links

- [OpenChoreo](../../docs/openchoreo.md#sign-in-with-github)
- [GitHub teams and roles](../../docs/github-repos.md#teams-and-roles)