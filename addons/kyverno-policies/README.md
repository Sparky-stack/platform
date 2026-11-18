# kyverno-policies

## Purpose

Installs upstream Kyverno CEL Pod Security Standards (`baseline`, `Audit`) plus platform policies: automatic Istio ambient enrollment for OpenChoreo cell namespaces and per-environment image signature/attestation gates on workload clusters, digest-only images in workflow run namespaces on `mgmt`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kyverno`; layers `values/role-mgmt.yaml` on `mgmt`).
- **Catalog label:** `addons.platform.koorikla.io/kyverno-policies` (`default: true`, opt-out with `"false"`).

## Key values

- `previews` (from `installation.yaml`) and `previewGuards`: PR previews - expiry stamp, per-tenant cap and TTL `DeletingPolicy` on `mgmt` Environments; quota, limits and egress isolation generated into preview cell namespaces ([preview environments](../../docs/preview-environments.md)).

- `kyverno-policies.{podSecurityStandard,validationFailureAction,vpolExclude}`: `baseline` in `Audit` mode (`failurePolicy: Ignore`), excluding `platformNamespaces`.
- `ambientEnrollment.enabled`: `true` on workload clusters (`false` on `mgmt`), enrolling `renderedrelease-controller` namespaces into Istio ambient.
- `imageVerification.{enabled,environments,github,platformKey,requireDigest}`: `Audit` in `development`/`staging` and `Deny` in `production`, verifying `koorikla/ci` keyless workflow attestations or `cosign-platform` signatures (key inline in `platformKey.publicKey` or, with Harbor, from ConfigMap `platform-image-verification` that `charts/cluster` delivers; `platformKey.cluster`).
- `workflowImageDigests.{enabled,namespacePrefix,failurePolicy}`: on `mgmt` only (where the workflow plane runs), denies Pods in `workflows-*` whose images are not `image@sha256:<digest>` (ValidatingPolicy `platform-workflow-image-digests`, [build plane](../../docs/build-plane.md#security-posture-of-build-pods)).

## Day-2 notes

- Debugging denied images and moving CI workflow SHA or `cosign` pins: [incidents](../../docs/runbooks/incidents.md#kyverno-denying-an-image), [upgrades](../../docs/runbooks/upgrades.md#6-kyverno-and-supply-chain-policy-pins), and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#5-cosign-platform-signing-key).

## Links

- [Supply chain](../../docs/supply-chain.md)
- [Networking](../../docs/networking.md)
