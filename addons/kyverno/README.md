# kyverno

## Purpose

Wrapper chart for Kyverno (`3.10.0` / `v1.20.0`). Runs the admission, background, cleanup, and reports controllers on every cluster; policy definitions live in `addons/kyverno-policies`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: kyverno`; layers `values/role-mgmt.yaml` on `mgmt`, `values/role-workload.yaml` on workload clusters).
- **Catalog label:** `addons.platform.koorikla.io/kyverno` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| byoDelivery.configMap | string | `"platform-image-verification"` |  |
| byoDelivery.enabled | bool | `false` | On byo clusters (`values/provider-byo.yaml`), `templates/byo-image-verification.yaml` rebuilds ConfigMap `platform-image-verification` from the Secret mgmt pushes ([byo](../../docs/providers.md#bring-your-own-cluster-byo)). |
| byoDelivery.store | string | `"delivery"` |  |
| kyverno.admissionController.container.extraArgs.imageVerifyCacheEnabled | bool | `true` |  |
| kyverno.admissionController.container.extraArgs.imageVerifyCacheMaxSize | string | `"33554432"` |  |
| kyverno.admissionController.container.extraArgs.imageVerifyCacheTTLDuration | string | `"24h"` |  |
| kyverno.admissionController.container.image | object | `{"tag":"v1.20.0@sha256:9de49c5416ea536f00a205527197ac048abdf32c5a75d633cd9afff8928f359d"}` | `v1.20.0` pinned by multi-arch index digest (alongside `backgroundController`, `cleanupController`, `reportsController`; `values/role-workload.yaml` mounts `platform-image-verification` and `SSL_CERT_DIR` to trust the Harbor CA, [supply-chain](../../docs/supply-chain.md#wiring-the-key)). |
| kyverno.admissionController.container.resources.limits.memory | string | `"384Mi"` |  |
| kyverno.admissionController.container.resources.requests.cpu | string | `"50m"` |  |
| kyverno.admissionController.container.resources.requests.memory | string | `"128Mi"` |  |
| kyverno.admissionController.initContainer.image.tag | string | `"v1.20.0@sha256:339067e083430e0c97007541bef9cfdbac89bee13f7228772c77ae8aead14b8b"` |  |
| kyverno.admissionController.replicas | int | `1` |  |
| kyverno.backgroundController.image.tag | string | `"v1.20.0@sha256:c72df38320a48fc9de10f9d23d087a117853bb08207b7f60f6d1e8457fb3ddb7"` |  |
| kyverno.backgroundController.replicas | int | `1` |  |
| kyverno.backgroundController.resources.limits.memory | string | `"128Mi"` |  |
| kyverno.backgroundController.resources.requests.cpu | string | `"25m"` |  |
| kyverno.backgroundController.resources.requests.memory | string | `"64Mi"` |  |
| kyverno.cleanupController.image.tag | string | `"v1.20.0@sha256:0f9ce0c203561c52499e871a987ff987371f57385fcafe7af1a01dfd6db1feee"` |  |
| kyverno.cleanupController.replicas | int | `1` |  |
| kyverno.cleanupController.resources.limits.memory | string | `"128Mi"` |  |
| kyverno.cleanupController.resources.requests.cpu | string | `"25m"` |  |
| kyverno.cleanupController.resources.requests.memory | string | `"64Mi"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[0] | string | `"kube-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[10] | string | `"capi-k3s-bootstrap-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[11] | string | `"capi-k3s-control-plane-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[12] | string | `"capd-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[13] | string | `"capa-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[14] | string | `"caph-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[15] | string | `"fleet"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[16] | string | `"openchoreo-control-plane"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[17] | string | `"openchoreo-data-plane"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[18] | string | `"openchoreo-workflow-plane"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[19] | string | `"openchoreo-observability-plane"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[1] | string | `"kube-public"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[20] | string | `"openchoreo-secrets"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[21] | string | `"thunder"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[22] | string | `"kgateway-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[23] | string | `"istio-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[24] | string | `"cilium"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[25] | string | `"falco"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[26] | string | `"telemetry"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[27] | string | `"obi"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[28] | string | `"agentgateway-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[2] | string | `"kube-node-lease"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[3] | string | `"kyverno"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[4] | string | `"argocd"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[5] | string | `"cert-manager"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[6] | string | `"external-secrets"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[7] | string | `"platform-secrets"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[8] | string | `"capi-operator-system"` |  |
| kyverno.config.resourceFiltersIncludeNamespaces[9] | string | `"capi-system"` |  |
| kyverno.config.webhooks.namespaceSelector | object | `{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["kube-system","kube-public","kube-node-lease","kyverno","argocd","cert-manager","external-secrets","platform-secrets","capi-operator-system","capi-system","capi-k3s-bootstrap-system","capi-k3s-control-plane-system","capd-system","capa-system","caph-system","fleet","openchoreo-control-plane","openchoreo-data-plane","openchoreo-workflow-plane","openchoreo-observability-plane","openchoreo-secrets","thunder","kgateway-system","istio-system","cilium","falco","telemetry","obi","agentgateway-system"]}]}` | Excludes `platformNamespaces` (`kube-system`, `argocd`, `capi-*`, `openchoreo-*`, etc.) from admission webhook interception. |
| kyverno.crds.migration.image.tag | string | `"v1.20.0@sha256:bd2b8b7c9d550ecf04e0bacaf351adce2f82ce67fd3f291075edcee7f8ab4ab4"` |  |
| kyverno.reportsController.image.tag | string | `"v1.20.0@sha256:f54e3cc106fadb1a615d0ec11c42f741f51d3580a5f70dfbe7bd7ec58864ef03"` |  |
| kyverno.reportsController.rbac.clusterRole.extraResources[0].apiGroups[0] | string | `""` |  |
| kyverno.reportsController.rbac.clusterRole.extraResources[0].resources[0] | string | `"pods/ephemeralcontainers"` |  |
| kyverno.reportsController.rbac.clusterRole.extraResources[0].verbs[0] | string | `"get"` |  |
| kyverno.reportsController.rbac.clusterRole.extraResources[0].verbs[1] | string | `"list"` |  |
| kyverno.reportsController.rbac.clusterRole.extraResources[0].verbs[2] | string | `"watch"` |  |
| kyverno.reportsController.replicas | int | `1` |  |
| kyverno.reportsController.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}` | Raises memory to `96Mi` request / `256Mi` limit on `mgmt` (`values/role-mgmt.yaml`) for initial object-list peaks. |
| kyverno.test.image.tag | string | `"v1.20.0@sha256:6079a30d75fe7ba868a5a7e5dfa71ee92a3a8bae97adcea1c8cfb1009280ee6c"` |  |
| kyverno.upgrade.legacyPolicyCheck.image.tag | string | `"v1.20.0@sha256:bd2b8b7c9d550ecf04e0bacaf351adce2f82ce67fd3f291075edcee7f8ab4ab4"` |  |
| kyverno.webhooksCleanup.image.tag | string | `"v1.20.0@sha256:6079a30d75fe7ba868a5a7e5dfa71ee92a3a8bae97adcea1c8cfb1009280ee6c"` |  |

## Day-2 notes

- Investigating blocked image admissions and upgrading Kyverno: [incidents](../../docs/runbooks/incidents.md#kyverno-denying-an-image) and [upgrades](../../docs/runbooks/upgrades.md#6-kyverno-and-supply-chain-policy-pins).

## Links

- [Networking](../../docs/networking.md)
- [Supply chain](../../docs/supply-chain.md)