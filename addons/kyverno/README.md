# kyverno

## Purpose

Wrapper chart for Kyverno (`3.10.0` / `v1.20.0`). Runs the admission, background, cleanup, and reports controllers on every cluster; policy definitions live in `addons/kyverno-policies`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kyverno`; layers `values/role-mgmt.yaml` on `mgmt`, `values/role-workload.yaml` on workload clusters).
- **Catalog label:** `addons.platform.koorikla.io/kyverno` (`default: true`, opt-out with `"false"`).

## Key values

- `kyverno.config.webhooks.namespaceSelector`: excludes `platformNamespaces` (`kube-system`, `argocd`, `capi-*`, `openchoreo-*`, etc.) from admission webhook interception.
- `SSL_CERT_DIR` + optional ConfigMap `platform-image-verification` volume on the admission and reports controllers (`values/role-workload.yaml`): trust the Harbor CA delivered by `charts/cluster` for verifying Harbor-built images ([supply-chain](../../docs/supply-chain.md#wiring-the-key)).
- `kyverno.reportsController.resources` (`values/role-mgmt.yaml`): raises memory to `96Mi` request / `256Mi` limit on `mgmt` for initial object-list peaks.
- `kyverno.{admissionController,backgroundController,cleanupController,reportsController}` images: `v1.20.0` pinned by multi-arch index digest.

## Day-2 notes

- Investigating blocked image admissions and upgrading Kyverno: [incidents](../../docs/runbooks/incidents.md#kyverno-denying-an-image) and [upgrades](../../docs/runbooks/upgrades.md#6-kyverno-and-supply-chain-policy-pins).

## Links

- [Networking](../../docs/networking.md)
- [Supply chain](../../docs/supply-chain.md)
