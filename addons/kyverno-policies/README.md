# kyverno-policies

## Purpose

Installs upstream Kyverno CEL Pod Security Standards (`baseline`, `Audit`) plus platform policies. Workload clusters: Istio ambient enrollment, strict mTLS and identity allow-lists (AuthorizationPolicy) for OpenChoreo cell namespaces, per-environment image signature/attestation gates, production workload resilience (replicas, probes, requests; Deny in production, Audit elsewhere) and PR preview cell guardrails. `mgmt`: digest-only images in workflow run namespaces, PR preview expiry/cap/TTL, and ResourceReleaseBindings only to data planes that run the addons their type needs.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kyverno`; layers `values/role-mgmt.yaml` on `mgmt`).
- **Catalog label:** `addons.platform.koorikla.io/kyverno-policies` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| ambientEnrollment.cellNamespaceSelector.matchExpressions[0].key | string | `"openchoreo.dev/project"` |  |
| ambientEnrollment.cellNamespaceSelector.matchExpressions[0].operator | string | `"Exists"` |  |
| ambientEnrollment.cellNamespaceSelector.matchExpressions[1].key | string | `"openchoreo.dev/environment"` |  |
| ambientEnrollment.cellNamespaceSelector.matchExpressions[1].operator | string | `"Exists"` |  |
| ambientEnrollment.cellNamespaceSelector.matchLabels."openchoreo.dev/managed-by" | string | `"renderedrelease-controller"` |  |
| ambientEnrollment.enabled | bool | `true` | `true` on workload clusters (`false` on `mgmt`), enrolling `renderedrelease-controller` namespaces into Istio ambient. |
| ambientEnrollment.mtls.optOutLabel | string | `"platform.koorikla.io/mtls"` |  |
| ambientEnrollment.mtls.platformPeers | list | `["cluster.local/ns/openchoreo-data-plane/sa/gateway-default","cluster.local/ns/telemetry/sa/openchoreo-prometheus-agent","cluster.local/ns/cnpg-system/sa/cnpg","cluster.local/ns/moco-system/sa/moco-controller-manager","cluster.local/ns/keda/sa/keda-operator","cluster.local/ns/strimzi/sa/strimzi-cluster-operator"]` | With `strict`: AuthorizationPolicy `platform-cell-peers` admits into a cell only its own workloads and these SPIFFE principals (`<trust domain>/ns/<namespace>/sa/<service account>`); any other mesh identity, e.g. another cell, is refused (#324). |
| ambientEnrollment.mtls.strict | bool | `true` | Every enrolled cell gets NetworkPolicy `platform-mesh-hbone` and a `STRICT` `PeerAuthentication`, or `PERMISSIVE` where `<optOutLabel>=permissive` ([strict mTLS in cell namespaces](../../docs/networking.md#strict-mtls-in-cell-namespaces)). |
| ambientEnrollment.strimzi.enabled | bool | `true` | Every enrolled cell gets NetworkPolicy `platform-strimzi`: pods with `strimzi.io/cluster` admit the cell's pods, `openchoreo.dev/system-component` pods and `peers` on any port (HBONE `15008` included) plus kubelet probes. |
| ambientEnrollment.strimzi.peers[0].namespace | string | `"strimzi"` |  |
| ambientEnrollment.strimzi.peers[0].podLabels."strimzi.io/kind" | string | `"cluster-operator"` |  |
| ambientEnrollment.strimzi.peers[1].namespace | string | `"keda"` |  |
| ambientEnrollment.strimzi.peers[1].podLabels.app | string | `"keda-operator"` |  |
| dataPlaneCapabilities.enabled | bool | `false` | On `mgmt` only, denies a `ResourceReleaseBinding` whose (Cluster)ResourceType names an addon in `platform.koorikla.io/requires-addons` that the environment's data plane does not announce (`ValidatingPolicy/platform-data-plane-capabilities`, [data services](../../docs/data-services.md#only-on-data-planes-that-run-the-operator)). |
| imageVerification.attestationTypes.provenance | string | `"https://slsa.dev/provenance/v1"` |  |
| imageVerification.attestationTypes.sbom | string | `"https://spdx.dev/Document/v2.3"` |  |
| imageVerification.attestationTypes.vuln | string | `"https://cosign.sigstore.dev/attestation/vuln/v1"` |  |
| imageVerification.cellNamespaceSelector.matchLabels."openchoreo.dev/managed-by" | string | `"renderedrelease-controller"` |  |
| imageVerification.defaultAction | string | `"Audit"` |  |
| imageVerification.enabled | bool | `true` | `Audit` in `development`/`staging` and `Deny` in `production` (`imageVerification.{enabled,environments,github,platformKey,requireDigest}`), verifying koorikla/platform `app-container.yaml` keyless workflow attestations or `cosign-platform` signatures. |
| imageVerification.environments.development | string | `"Audit"` |  |
| imageVerification.environments.production | string | `"Deny"` |  |
| imageVerification.environments.staging | string | `"Audit"` |  |
| imageVerification.extraTrustedPrefixes | list | `[]` |  |
| imageVerification.failurePolicy.Audit | string | `"Ignore"` |  |
| imageVerification.failurePolicy.Deny | string | `"Fail"` |  |
| imageVerification.github.attestations[0] | string | `"sbom"` |  |
| imageVerification.github.attestations[1] | string | `"provenance"` |  |
| imageVerification.github.attestations[2] | string | `"vuln"` |  |
| imageVerification.github.enabled | bool | `true` |  |
| imageVerification.github.issuer | string | `"https://token.actions.githubusercontent.com"` |  |
| imageVerification.github.prefixes[0] | string | `"ghcr.io/koorikla/"` |  |
| imageVerification.github.refs[0] | string | `"refs/heads/main"` |  |
| imageVerification.github.rekorURL | string | `"https://rekor.sigstore.dev"` |  |
| imageVerification.github.repositories[0] | string | `"koorikla/hello-world"` |  |
| imageVerification.github.transitionWorkflowRefs | list | `[]` |  |
| imageVerification.github.triggers[0] | string | `"push"` |  |
| imageVerification.github.workflow | string | `"https://github.com/koorikla/platform/.github/workflows/app-container.yaml"` |  |
| imageVerification.github.workflowRef | string | `"3311f541a8eab72a2649b6f1eda4fe05efa3142e"` |  |
| imageVerification.platformKey.attestations[0] | string | `"sbom"` |  |
| imageVerification.platformKey.attestations[1] | string | `"vuln"` |  |
| imageVerification.platformKey.cluster.configMap | string | `"platform-image-verification"` |  |
| imageVerification.platformKey.cluster.namespace | string | `"kyverno"` |  |
| imageVerification.platformKey.cluster.pullSecret | string | `"platform-registry"` |  |
| imageVerification.platformKey.enabled | bool | `true` |  |
| imageVerification.platformKey.publicKey | string | `""` |  |
| imageVerification.platformKey.rekor | bool | `false` |  |
| imageVerification.requireDigest.Audit | bool | `false` |  |
| imageVerification.requireDigest.Deny | bool | `true` |  |
| imageVerification.timeoutSeconds | int | `30` |  |
| kyverno-policies.customAnnotations."argocd.argoproj.io/sync-options" | string | `"SkipDryRunOnMissingResource=true"` |  |
| kyverno-policies.failurePolicy | string | `"Ignore"` |  |
| kyverno-policies.kyvernoVersion | string | `"1.20.0"` |  |
| kyverno-policies.podSecurityStandard | string | `"baseline"` | `baseline` in `Audit` mode (`validationFailureAction: Audit`, `failurePolicy: Ignore`), excluding `platformNamespaces` (`vpolExclude`). |
| kyverno-policies.validationFailureAction | string | `"Audit"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[0] | string | `"kube-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[10] | string | `"capi-k3s-bootstrap-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[11] | string | `"capi-k3s-control-plane-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[12] | string | `"capd-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[13] | string | `"capa-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[14] | string | `"caph-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[15] | string | `"fleet"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[16] | string | `"openchoreo-control-plane"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[17] | string | `"openchoreo-data-plane"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[18] | string | `"openchoreo-workflow-plane"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[19] | string | `"openchoreo-observability-plane"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[1] | string | `"kube-public"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[20] | string | `"openchoreo-secrets"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[21] | string | `"thunder"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[22] | string | `"kgateway-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[23] | string | `"istio-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[24] | string | `"cilium"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[25] | string | `"falco"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[26] | string | `"telemetry"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[27] | string | `"obi"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[28] | string | `"agentgateway-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[2] | string | `"kube-node-lease"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[3] | string | `"kyverno"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[4] | string | `"argocd"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[5] | string | `"cert-manager"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[6] | string | `"external-secrets"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[7] | string | `"platform-secrets"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[8] | string | `"capi-operator-system"` |  |
| kyverno-policies.vpolExclude.excludeNamespaces[9] | string | `"capi-system"` |  |
| mesh.probeSourceCIDRs[0] | string | `"169.254.7.127/32"` |  |
| mesh.probeSourceCIDRs[1] | string | `"fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128"` |  |
| platformNamespaces[0] | string | `"kube-system"` |  |
| platformNamespaces[10] | string | `"capi-k3s-bootstrap-system"` |  |
| platformNamespaces[11] | string | `"capi-k3s-control-plane-system"` |  |
| platformNamespaces[12] | string | `"capd-system"` |  |
| platformNamespaces[13] | string | `"capa-system"` |  |
| platformNamespaces[14] | string | `"caph-system"` |  |
| platformNamespaces[15] | string | `"fleet"` |  |
| platformNamespaces[16] | string | `"openchoreo-control-plane"` |  |
| platformNamespaces[17] | string | `"openchoreo-data-plane"` |  |
| platformNamespaces[18] | string | `"openchoreo-workflow-plane"` |  |
| platformNamespaces[19] | string | `"openchoreo-observability-plane"` |  |
| platformNamespaces[1] | string | `"kube-public"` |  |
| platformNamespaces[20] | string | `"openchoreo-secrets"` |  |
| platformNamespaces[21] | string | `"thunder"` |  |
| platformNamespaces[22] | string | `"kgateway-system"` |  |
| platformNamespaces[23] | string | `"istio-system"` |  |
| platformNamespaces[24] | string | `"cilium"` |  |
| platformNamespaces[25] | string | `"falco"` |  |
| platformNamespaces[26] | string | `"telemetry"` |  |
| platformNamespaces[27] | string | `"obi"` |  |
| platformNamespaces[28] | string | `"agentgateway-system"` |  |
| platformNamespaces[2] | string | `"kube-node-lease"` |  |
| platformNamespaces[3] | string | `"kyverno"` |  |
| platformNamespaces[4] | string | `"argocd"` |  |
| platformNamespaces[5] | string | `"cert-manager"` |  |
| platformNamespaces[6] | string | `"external-secrets"` |  |
| platformNamespaces[7] | string | `"platform-secrets"` |  |
| platformNamespaces[8] | string | `"capi-operator-system"` |  |
| platformNamespaces[9] | string | `"capi-system"` |  |
| previewGuards.containerLimits.default.cpu | string | `"500m"` |  |
| previewGuards.containerLimits.default.memory | string | `"256Mi"` |  |
| previewGuards.containerLimits.defaultRequest.cpu | string | `"50m"` |  |
| previewGuards.containerLimits.defaultRequest.memory | string | `"64Mi"` |  |
| previewGuards.containerLimits.max.memory | string | `"1Gi"` |  |
| previewGuards.environments | bool | `false` |  |
| previewGuards.namespaces | bool | `true` |  |
| previewGuards.quota."limits.cpu" | string | `"4"` |  |
| previewGuards.quota."limits.memory" | string | `"2Gi"` |  |
| previewGuards.quota."requests.cpu" | string | `"1"` |  |
| previewGuards.quota."requests.memory" | string | `"1Gi"` |  |
| previewGuards.quota."requests.storage" | string | `"15Gi"` |  |
| previewGuards.quota."services.loadbalancers" | string | `"0"` |  |
| previewGuards.quota."services.nodeports" | string | `"0"` |  |
| previewGuards.quota.persistentvolumeclaims | string | `"2"` |  |
| previewGuards.quota.pods | string | `"10"` |  |
| previewGuards.schedule | string | `"*/5 * * * *"` |  |
| previewGuards.ttlGrace | string | `"1h"` |  |
| previews.enabled | bool | `false` | PR previews (`previews` and `previewGuards`): expiry stamp, per-tenant cap and TTL `DeletingPolicy` on `mgmt` Environments; quota, limits and egress isolation in preview cell namespaces ([preview environments](../../docs/preview-environments.md)). |
| previews.maxPerTenant | int | `2` |  |
| previews.ttl | string | `"48h"` |  |
| registry.appsProject | string | `"apps"` |  |
| registry.host | string | `""` |  |
| workflowImageDigests.enabled | bool | `false` | On `mgmt` only, denies Pods in `workflows-*` whose images are not `image@sha256:<digest>` (`ValidatingPolicy/platform-workflow-image-digests`, [build plane](../../docs/build-plane.md#security-posture-of-build-pods)). |
| workflowImageDigests.failurePolicy | string | `"Fail"` |  |
| workflowImageDigests.namespacePrefix | string | `"workflows-"` |  |
| workloadResilience.cellNamespaceSelector.matchLabels."openchoreo.dev/managed-by" | string | `"renderedrelease-controller"` |  |
| workloadResilience.enabled | bool | `true` | Workload clusters only (mgmt has no OpenChoreo cell namespaces); values/role-mgmt.yaml turns it off. |
| workloadResilience.enforcedEnvironments | list | `["production"]` | Environments (cell namespace label `openchoreo.dev/environment`) where the checks deny; Audit everywhere else. |

## Day-2 notes

- A rejected render names the bad value: `values.schema.json` checks types, formats and enums (Helm prints `at '/<path>'`); cross-field rules live in `templates/validate.yaml`.
- Debugging denied images and moving CI workflow SHA or `cosign` pins: [incidents](../../docs/runbooks/incidents.md#kyverno-denying-an-image), [upgrades](../../docs/runbooks/upgrades.md#6-kyverno-and-supply-chain-policy-pins), and [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#5-cosign-platform-signing-key).

## Links

- [Supply chain](../../docs/supply-chain.md)
- [Networking](../../docs/networking.md)