# external-secrets

## Purpose

Wrapper chart for External Secrets Operator (`2.15.0`). Reconciles `ExternalSecret` and `ClusterSecretStore` resources so credentials reach management and workload clusters without storing secret material in Git.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: external-secrets`).
- **Catalog label:** `addons.platform.koorikla.io/external-secrets` (`default: true`, opt-out with `"false"`).

## Key values

- `external-secrets.installCRDs`: `true`.
- `external-secrets.{image,webhook.image,certController.image}.tag`: `v2.15.0` pinned by multi-arch index digest.
- `external-secrets.genericTargets.enabled` (`values/role-mgmt.yaml`): `true` on `mgmt` only so ESO can render non-Secret targets such as gateway CA `ConfigMap`s.

## Day-2 notes

- Rotating backing keys and forcing `ExternalSecret` refreshes: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).
- Unblocking failed node registry secret syncs: [break-glass](../../docs/runbooks/break-glass.md#blocked-cluster-sync-on-node-registry-secret).

## Links

- [Architecture](../../docs/architecture.md)
- [Conventions and contracts](../../docs/conventions.md)
