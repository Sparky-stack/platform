# platform

## Purpose

Root GitOps chart of an installation. Renders Argo CD `AppProject`s (`platform`, `fleet`, `examples`), the `mgmt` cluster secret, and `ApplicationSet`s for workload clusters (`fleet`), the addon catalog (`addons/*`), tenants (`tenants`), and opt-in examples.

## Where it runs

- **Target:** `mgmt` cluster (`namespace: argocd`), reconciled by the bootstrap `Application/root` (`bootstrap/root-app.yaml`).
- **Selection:** Not a catalog addon; owns the `addons` catalog in `charts/platform/values.yaml` that selects clusters via `platform.koorikla.io/role`, `platform.koorikla.io/provider`, and `addons.platform.koorikla.io/<addon>`.

## Key values

- `installation.{name,repoURL,revision,githubOrg}`: GitOps repository and org scope layered from `installations/<inst>/installation.yaml`.
- `mgmt.{name,provider,region,environment,addons}`: management cluster labels and `mgmt` addon opt-in/opt-out overrides.
- `addons.<name>`: catalog entry (`namespace`, `roles`, `providers`, `default`, parameter mappings, `installationValueFiles`).
- `openchoreo.*`, `registry.*`, `dns.*`, `sourceIntegrity.*`, `examples.*`: installation-wide toggles passed into catalog parameters.

## Day-2 notes

- Addon rollout waves, Renovate bumps, and stuck root/addon syncs: [upgrades](../../docs/runbooks/upgrades.md) and [incidents](../../docs/runbooks/incidents.md#argo-app-stuck-or-outofsync).
- Emergency `selfHeal` freeze on `Application/root`: [break-glass](../../docs/runbooks/break-glass.md).

## Links

- [Architecture: Addons catalog + labels](../../docs/architecture.md#addons-catalog--labels-gitops-bridge-style)
- [Conventions and contracts](../../docs/conventions.md)
- [Day-2 operations](../../docs/operations.md)
