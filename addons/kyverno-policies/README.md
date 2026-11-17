# kyverno-policies

## Purpose

Installs upstream Kyverno CEL Pod Security Standards (`baseline`, `Audit`) plus platform policies on workload clusters: automatic Istio ambient enrollment for OpenChoreo cell namespaces and per-environment image signature/attestation gates.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kyverno`; layers `values/role-mgmt.yaml` on `mgmt`).
- **Catalog label:** `addons.platform.koorikla.io/kyverno-policies` (`default: true`, opt-out with `"false"`).

## Key values

- `kyverno-policies.{podSecurityStandard,validationFailureAction,vpolExclude}`: `baseline` in `Audit` mode (`failurePolicy: Ignore`), excluding `platformNamespaces`.
- `ambientEnrollment.enabled`: `true` on workload clusters (`false` on `mgmt`), enrolling `renderedrelease-controller` namespaces into Istio ambient.
- `imageVerification.{enabled,environments,github,platformKey,requireDigest}`: `Audit` in `development`/`staging` and `Deny` in `production`, verifying `koorikla/ci` keyless workflow attestations or `cosign-platform` signatures (key inline in `platformKey.publicKey` or, with Harbor, from ConfigMap `platform-image-verification` that `charts/cluster` delivers; `platformKey.cluster`).

## Day-2 notes

- Debugging denied images and moving CI workflow SHA or `cosign` pins: [incidents](../../docs/runbooks/incidents.md#kyverno-denying-an-image), [upgrades](../../docs/runbooks/upgrades.md#6-kyverno-and-supply-chain-policy-pins), and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#5-cosign-platform-signing-key).

## Links

- [Supply chain](../../docs/supply-chain.md)
- [Networking](../../docs/networking.md)
