# thunder

## Purpose

Wrapper chart for ThunderID (`1.0.1`). Runs OpenChoreo's OIDC identity provider on `mgmt`, serving console, API, CLI, observer, promotion-gate, and opt-in AI agent OAuth clients over the control-plane `Gateway`, backed by delete-protected PVCs.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: thunder`).
- **Catalog label:** `addons.platform.koorikla.io/thunder` (`default: true`, opt-out with `"false"`).

## Key values

- `bootstrapSecret.{store,remoteKey,observabilityRemoteKey,promotionGate}`: pulls OIDC client and admin secrets from `ClusterSecretStore/platform` into `thunder-bootstrap`.
- `thunderid.deployment.replicaCount`: `1` (single-writer SQLite persistence) with `1.0.1` pinned by multi-arch index digest.
- `thunderid.httproute`: exposes `thunder.<openchoreo.controlPlane.host>` via `openchoreo-control-plane/gateway-default`.

## Day-2 notes

- Backing up and recovering Thunder's delete-protected PVCs: [backup and restore](../../docs/runbooks/backup-restore.md#4-thunder-pvc-recovery-live-verified) and [break-glass](../../docs/runbooks/break-glass.md#intentional-deletion-of-a-delete-protected-pvc).
- Upgrading Thunder with OpenChoreo: [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [OpenChoreo](../../docs/openchoreo.md)
