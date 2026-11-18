# external-secrets

## Purpose

Wrapper chart for External Secrets Operator (`2.15.0`). Reconciles `ExternalSecret` and `ClusterSecretStore` resources so credentials reach management and workload clusters without storing secret material in Git.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: external-secrets`).
- **Catalog label:** `addons.platform.koorikla.io/external-secrets` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| external-secrets.certController.image.tag | string | `"v2.15.0@sha256:6888f243e5f8f7592c6d7fae2a5547c9e33531441b47b53807b9093b25a00e31"` |  |
| external-secrets.certController.resources.requests.cpu | string | `"25m"` |  |
| external-secrets.certController.resources.requests.memory | string | `"64Mi"` |  |
| external-secrets.image.tag | string | `"v2.15.0@sha256:6888f243e5f8f7592c6d7fae2a5547c9e33531441b47b53807b9093b25a00e31"` | `v2.15.0` pinned by multi-arch index digest (shared across `image`, `webhook.image`, `certController.image`). |
| external-secrets.installCRDs | bool | `true` | Installs ESO CRDs (`external-secrets.genericTargets.enabled` in `values/role-mgmt.yaml` and `values/provider-byo.yaml` enables non-Secret targets on `mgmt` and [byo](../../docs/providers.md#bring-your-own-cluster-byo) clusters). |
| external-secrets.resources.requests.cpu | string | `"25m"` |  |
| external-secrets.resources.requests.memory | string | `"64Mi"` |  |
| external-secrets.webhook.image.tag | string | `"v2.15.0@sha256:6888f243e5f8f7592c6d7fae2a5547c9e33531441b47b53807b9093b25a00e31"` |  |
| external-secrets.webhook.resources.requests.cpu | string | `"10m"` |  |
| external-secrets.webhook.resources.requests.memory | string | `"32Mi"` |  |

## Day-2 notes

- Rotating backing keys and forcing `ExternalSecret` refreshes: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).
- Unblocking failed node registry secret syncs: [break-glass](../../docs/runbooks/break-glass.md#blocked-cluster-sync-on-node-registry-secret).

## Links

- [Architecture](../../docs/architecture.md)
- [Conventions and contracts](../../docs/conventions.md)