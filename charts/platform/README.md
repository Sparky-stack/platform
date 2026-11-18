# platform

## Purpose

Root GitOps chart of an installation. Renders Argo CD `AppProject`s (`platform`, `fleet`, `previews`, `examples`), the `mgmt` cluster secret, and `ApplicationSet`s for workload clusters (`fleet`), the addon catalog (`addons/*`), tenants (`tenants`), and opt-in examples.

## Where it runs

- **Target:** `mgmt` cluster (`namespace: argocd`), reconciled by the bootstrap `Application/root` (`bootstrap/root-app.yaml`).
- **Selection:** Not a catalog addon; owns the `addons` catalog in `charts/platform/values.yaml` that selects clusters via `platform.koorikla.io/role`, `platform.koorikla.io/provider`, and `addons.platform.koorikla.io/<addon>`.

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| addons.agentgateway.default | bool | `false` |  |
| addons.agentgateway.namespace | string | `"agentgateway-system"` |  |
| addons.agentgateway.roles[0] | string | `"mgmt"` |  |
| addons.argo-cd | object | `{"default":true,"namespace":"argocd","releaseName":"argocd","roles":["mgmt"]}` | Addon catalog entry (`namespace`, `roles`, `providers`, `default`, parameter mappings, `installationValueFiles`). |
| addons.argo-events.default | bool | `true` |  |
| addons.argo-events.fleetParameters[0] | string | `"falco.clusters"` |  |
| addons.argo-events.namespace | string | `"argo-events"` |  |
| addons.argo-events.roles[0] | string | `"mgmt"` |  |
| addons.aws-ccm.default | bool | `true` |  |
| addons.aws-ccm.namespace | string | `"kube-system"` |  |
| addons.aws-ccm.providers[0] | string | `"aws"` |  |
| addons.aws-ccm.roles[0] | string | `"workload"` |  |
| addons.capi-operator.default | bool | `true` |  |
| addons.capi-operator.namespace | string | `"capi-operator-system"` |  |
| addons.capi-operator.roles[0] | string | `"mgmt"` |  |
| addons.capi-providers.default | bool | `true` |  |
| addons.capi-providers.namespace | string | `"capi-system"` |  |
| addons.capi-providers.roles[0] | string | `"mgmt"` |  |
| addons.cert-manager.default | bool | `true` |  |
| addons.cert-manager.namespace | string | `"cert-manager"` |  |
| addons.cert-manager.roles[0] | string | `"mgmt"` |  |
| addons.cert-manager.roles[1] | string | `"workload"` |  |
| addons.cilium.clusterServerParameters."cilium.k8sServiceHost" | string | `"host"` |  |
| addons.cilium.clusterServerParameters."cilium.k8sServicePort" | string | `"port"` |  |
| addons.cilium.default | bool | `false` |  |
| addons.cilium.namespace | string | `"kube-system"` |  |
| addons.cilium.roles[0] | string | `"workload"` |  |
| addons.cloudnative-pg.default | bool | `false` |  |
| addons.cloudnative-pg.namespace | string | `"cnpg-system"` |  |
| addons.cloudnative-pg.roles[0] | string | `"workload"` |  |
| addons.cloudnative-pg.serverSideDiff | bool | `true` |  |
| addons.clusterclasses.default | bool | `true` |  |
| addons.clusterclasses.namespace | string | `"fleet"` |  |
| addons.clusterclasses.roles[0] | string | `"mgmt"` |  |
| addons.clusterclasses.serverSideDiff | bool | `true` |  |
| addons.coredns-local.default | bool | `true` |  |
| addons.coredns-local.namespace | string | `"kube-system"` |  |
| addons.coredns-local.providers[0] | string | `"docker"` |  |
| addons.coredns-local.providers[1] | string | `"byo"` |  |
| addons.coredns-local.roles[0] | string | `"mgmt"` |  |
| addons.coredns-local.roles[1] | string | `"workload"` |  |
| addons.crossplane.default | bool | `false` |  |
| addons.crossplane.namespace | string | `"crossplane-system"` |  |
| addons.crossplane.roles[0] | string | `"workload"` |  |
| addons.crossplane.serverSideDiff | bool | `true` |  |
| addons.external-dns.clusterIdParameters[0] | string | `"external-dns.txtOwnerId"` |  |
| addons.external-dns.default | bool | `false` |  |
| addons.external-dns.installationParameters."external-dns.domainFilters" | string | `"{{ printf \"{%s}\" (join \",\" .Values.dns.domainFilters) }}"` |  |
| addons.external-dns.installationValueFiles[0] | string | `"values/dns-{{ .Values.dns.provider }}.yaml"` |  |
| addons.external-dns.namespace | string | `"external-dns"` |  |
| addons.external-dns.roles[0] | string | `"mgmt"` |  |
| addons.external-dns.roles[1] | string | `"workload"` |  |
| addons.external-secrets.default | bool | `true` |  |
| addons.external-secrets.namespace | string | `"external-secrets"` |  |
| addons.external-secrets.roles[0] | string | `"mgmt"` |  |
| addons.external-secrets.roles[1] | string | `"workload"` |  |
| addons.falco.clusterNameFormats."falco.falcosidekick.config.customfields" | string | `"cluster:%s"` |  |
| addons.falco.default | bool | `true` |  |
| addons.falco.namespace | string | `"falco"` |  |
| addons.falco.roles[0] | string | `"mgmt"` |  |
| addons.falco.roles[1] | string | `"workload"` |  |
| addons.finops-opencost.default | bool | `false` |  |
| addons.finops-opencost.namespace | string | `"openchoreo-observability-plane"` |  |
| addons.finops-opencost.roles[0] | string | `"mgmt"` |  |
| addons.gateway-api-crds.default | bool | `true` |  |
| addons.gateway-api-crds.namespace | string | `"kube-system"` |  |
| addons.gateway-api-crds.roles[0] | string | `"mgmt"` |  |
| addons.gateway-api-crds.roles[1] | string | `"workload"` |  |
| addons.harbor.default | bool | `true` |  |
| addons.harbor.installationParameters."harbor.externalURL" | string | `"https://{{ .Values.registry.host }}"` |  |
| addons.harbor.namespace | string | `"harbor"` |  |
| addons.harbor.roles[0] | string | `"mgmt"` |  |
| addons.hcloud-ccm.default | bool | `true` |  |
| addons.hcloud-ccm.namespace | string | `"kube-system"` |  |
| addons.hcloud-ccm.providers[0] | string | `"hetzner"` |  |
| addons.hcloud-ccm.roles[0] | string | `"workload"` |  |
| addons.keda.default | bool | `false` |  |
| addons.keda.namespace | string | `"keda"` |  |
| addons.keda.roles[0] | string | `"workload"` |  |
| addons.keda.serverSideDiff | bool | `true` |  |
| addons.kgateway.default | bool | `true` |  |
| addons.kgateway.namespace | string | `"kgateway-system"` |  |
| addons.kgateway.roles[0] | string | `"mgmt"` |  |
| addons.kgateway.roles[1] | string | `"workload"` |  |
| addons.kyverno-policies.default | bool | `true` |  |
| addons.kyverno-policies.namespace | string | `"kyverno"` |  |
| addons.kyverno-policies.roles[0] | string | `"mgmt"` |  |
| addons.kyverno-policies.roles[1] | string | `"workload"` |  |
| addons.kyverno.default | bool | `true` |  |
| addons.kyverno.namespace | string | `"kyverno"` |  |
| addons.kyverno.roles[0] | string | `"mgmt"` |  |
| addons.kyverno.roles[1] | string | `"workload"` |  |
| addons.mesh.clusterLabelParameters."global.meshID".label | string | `"mesh.platform.koorikla.io/group"` |  |
| addons.mesh.clusterLabelParameters."global.network".label | string | `"mesh.platform.koorikla.io/network"` |  |
| addons.mesh.clusterLabelParameters."mesh.group".label | string | `"mesh.platform.koorikla.io/group"` |  |
| addons.mesh.clusterLabelParameters."mesh.network".label | string | `"mesh.platform.koorikla.io/network"` |  |
| addons.mesh.clusterLabelParameters."ztunnel.podAnnotations.mesh\.platform\.koorikla\.io/group".label | string | `"mesh.platform.koorikla.io/group"` |  |
| addons.mesh.clusterNameParameters[0] | string | `"global.multiCluster.clusterName"` |  |
| addons.mesh.clusterNameParameters[1] | string | `"cert-manager-istio-csr.app.server.clusterID"` |  |
| addons.mesh.default | bool | `true` |  |
| addons.mesh.ignoreDifferences[0].group | string | `"admissionregistration.k8s.io"` |  |
| addons.mesh.ignoreDifferences[0].kind | string | `"ValidatingWebhookConfiguration"` |  |
| addons.mesh.ignoreDifferences[0].managedFieldsManagers[0] | string | `"pilot-discovery"` |  |
| addons.mesh.namespace | string | `"istio-system"` |  |
| addons.mesh.roles[0] | string | `"workload"` |  |
| addons.obi.default | bool | `false` |  |
| addons.obi.namespace | string | `"obi"` |  |
| addons.obi.roles[0] | string | `"workload"` |  |
| addons.openbao.default | bool | `false` |  |
| addons.openbao.namespace | string | `"openbao"` |  |
| addons.openbao.roles[0] | string | `"mgmt"` |  |
| addons.openchoreo-control-plane.default | bool | `true` |  |
| addons.openchoreo-control-plane.installationParameters."openchoreo-control-plane.backstage.features.observability.enabled" | string | `"{{ .Values.openchoreo.observability.enabled }}"` |  |
| addons.openchoreo-control-plane.installationParameters."openchoreo-control-plane.backstage.features.workflows.enabled" | string | `"{{ .Values.openchoreo.workflowPlane.enabled }}"` |  |
| addons.openchoreo-control-plane.namespace | string | `"openchoreo-control-plane"` |  |
| addons.openchoreo-control-plane.roles[0] | string | `"mgmt"` |  |
| addons.openchoreo-data-plane.clusterNameParameters[0] | string | `"openchoreo-data-plane.clusterAgent.planeID"` |  |
| addons.openchoreo-data-plane.default | bool | `true` |  |
| addons.openchoreo-data-plane.installationParameters."openchoreo-data-plane.clusterAgent.serverUrl" | string | `"{{ .Values.openchoreo.controlPlane.clusterGatewayURL }}"` |  |
| addons.openchoreo-data-plane.namespace | string | `"openchoreo-data-plane"` |  |
| addons.openchoreo-data-plane.roles[0] | string | `"workload"` |  |
| addons.openchoreo-observability-plane.default | bool | `true` |  |
| addons.openchoreo-observability-plane.namespace | string | `"openchoreo-observability-plane"` |  |
| addons.openchoreo-observability-plane.roles[0] | string | `"mgmt"` |  |
| addons.openchoreo-platform.default | bool | `true` |  |
| addons.openchoreo-platform.namespace | string | `"default"` |  |
| addons.openchoreo-platform.roles[0] | string | `"mgmt"` |  |
| addons.openchoreo-workflow-plane.default | bool | `true` |  |
| addons.openchoreo-workflow-plane.namespace | string | `"openchoreo-workflow-plane"` |  |
| addons.openchoreo-workflow-plane.roles[0] | string | `"mgmt"` |  |
| addons.reloader.default | bool | `true` |  |
| addons.reloader.namespace | string | `"reloader"` |  |
| addons.reloader.roles[0] | string | `"mgmt"` |  |
| addons.reloader.roles[1] | string | `"workload"` |  |
| addons.secret-stores.default | bool | `true` |  |
| addons.secret-stores.namespace | string | `"external-secrets"` |  |
| addons.secret-stores.roles[0] | string | `"mgmt"` |  |
| addons.secret-stores.roles[1] | string | `"workload"` |  |
| addons.strimzi.default | bool | `false` |  |
| addons.strimzi.namespace | string | `"strimzi"` |  |
| addons.strimzi.roles[0] | string | `"workload"` |  |
| addons.telemetry.default | bool | `true` |  |
| addons.telemetry.namespace | string | `"telemetry"` |  |
| addons.telemetry.roles[0] | string | `"workload"` |  |
| addons.thunder.default | bool | `true` |  |
| addons.thunder.namespace | string | `"thunder"` |  |
| addons.thunder.roles[0] | string | `"mgmt"` |  |
| dns.domainFilters | list | `[]` |  |
| dns.provider | string | `"none"` |  |
| examples.eastwest.enabled | bool | `false` |  |
| examples.eastwest.namespace | string | `"eastwest-demo"` |  |
| examples.eastwest.selector.matchLabels."addons.platform.koorikla.io/istio-eastwest" | string | `"true"` |  |
| examples.eastwest.selector.matchLabels."platform.koorikla.io/role" | string | `"workload"` |  |
| examplesProject.namespaceResources[0].group | string | `""` |  |
| examplesProject.namespaceResources[0].kind | string | `"Service"` |  |
| examplesProject.namespaceResources[1].group | string | `""` |  |
| examplesProject.namespaceResources[1].kind | string | `"ServiceAccount"` |  |
| examplesProject.namespaceResources[2].group | string | `"apps"` |  |
| examplesProject.namespaceResources[2].kind | string | `"Deployment"` |  |
| examplesProject.namespaceResources[3].group | string | `"security.istio.io"` |  |
| examplesProject.namespaceResources[3].kind | string | `"AuthorizationPolicy"` |  |
| installation.githubOrg | string | `"https://github.com/koorikla"` |  |
| installation.name | string | `"local"` | GitOps repository and org scope (`installation.{name,repoURL,revision,githubOrg}`) layered from `installations/<inst>/installation.yaml`. |
| installation.repoURL | string | `"https://github.com/koorikla/platform.git"` |  |
| installation.revision | string | `"HEAD"` |  |
| mgmt.addons | object | `{}` | `mgmt` addon opt-in/opt-out overrides. |
| mgmt.environment | string | `"mgmt"` |  |
| mgmt.name | string | `"mgmt"` | Management cluster identity (`mgmt.{name,provider,region,environment}`). |
| mgmt.provider | string | `"docker"` |  |
| mgmt.region | string | `"local"` |  |
| openchoreo.controlPlane.clusterGatewayURL | string | `"wss://cluster-gateway.openchoreo.localhost:8443/ws"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` |  |
| openchoreo.observability.enabled | bool | `false` |  |
| openchoreo.orgNamespace | string | `"default"` | Installation-wide OpenChoreo toggles (`openchoreo.*`) passed into catalog parameters. |
| openchoreo.workflowPlane.enabled | bool | `false` |  |
| registry.host | string | `""` |  |
| registry.type | string | `"external"` |  |
| secrets.githubGateApp.enabled | bool | `false` |  |
| sourceIntegrity.enabled | bool | `false` | Enables Git commit signature verification for `platform`, `fleet`, and `tenant` `AppProject`s. |
| sourceIntegrity.keys[0] | string | `"B5690EEEBB952194"` |  |
| sourceIntegrity.mode | string | `"head"` |  |
| sourceIntegrity.repos[0] | string | `"{{ .Values.installation.githubOrg }}/*"` |  |

## Day-2 notes

- Addon rollout waves, Renovate bumps, and stuck root/addon syncs: [upgrades](../../docs/runbooks/upgrades.md) and [incidents](../../docs/runbooks/incidents.md#argo-app-stuck-or-outofsync).
- Emergency `selfHeal` freeze on `Application/root`: [break-glass](../../docs/runbooks/break-glass.md).

## Links

- [Architecture: Addons catalog + labels](../../docs/architecture.md#addons-catalog--labels-gitops-bridge-style)
- [Conventions and contracts](../../docs/conventions.md)
- [Day-2 operations](../../docs/operations.md)