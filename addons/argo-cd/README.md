# argo-cd

## Purpose

Wrapper chart for `argo-cd` (`10.18.0` / `v3.6.1`) on the management cluster. Adopts the bootstrap `argocd` Helm release and reconciles `Application/root`, `ApplicationSet`s, and every workload cluster in push mode.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: argocd`, `releaseName: argocd`).
- **Catalog label:** `addons.platform.koorikla.io/argo-cd` (`default: true`, opt-out with `"false"`).

## Key values

- `argo-cd.configs.params.controller.diff.server.side`: `true` so CAPI, ESO, cert-manager, and OpenChoreo CRD defaults do not cause permanent diffs.
- `argo-cd.configs.cm.helm.dependencies.enabled`: `"true"` so `repo-server` builds HTTPS and OCI wrapper dependencies (`ARGOCD_EXEC_TIMEOUT=180s`).
- `argo-cd.configs.cm.resource.customizations.health.PersistentVolumeClaim`: treats `Pending` `WaitForFirstConsumer` PVCs as `Healthy` so hook Jobs can bind volumes.
- `argo-cd.{controller,server,repoServer,applicationSet,dex,notifications}.image.tag` and `argo-cd.redis.image`: pinned by multi-arch index digest.

## Day-2 notes

- Stuck or `OutOfSync` applications: [incidents](../../docs/runbooks/incidents.md#argo-app-stuck-or-outofsync).
- Emergency controller freeze (`selfHeal` pause): [break-glass](../../docs/runbooks/break-glass.md#freezing-argo-cd-self-heal) and [upgrades](../../docs/runbooks/upgrades.md).

## Links

- [Architecture](../../docs/architecture.md)
- [Supply chain](../../docs/supply-chain.md)
