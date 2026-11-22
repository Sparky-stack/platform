# openchoreo-workflow-plane

## Purpose

Wrapper chart for `openchoreo-workflow-plane` (`1.3.3`) on `mgmt`. Runs Argo Workflows, the workflow `cluster-agent`, `ClusterWorkflowPlane/default`, rootless BuildKit `ClusterWorkflowTemplate`s (`koorikla-build`, `koorikla-helm-chart`: each step runs a versioned `ci/scripts/workflow` script from the toolbox image `images.TOOLBOX_IMAGE`, see [build plane](../../docs/build-plane.md#step-scripts-ciscriptsworkflow)), and strict egress `NetworkPolicy` rules for workflow runs.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-workflow-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-workflow-plane` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agentServerCA.configMapName | string | `"cluster-gateway-ca"` |  |
| agentServerCA.enabled | bool | `true` | Syncs `cluster-gateway-ca` (`agentServerCA.{enabled,store,sourceSecret}`) from `ClusterSecretStore/mgmt-openchoreo`. |
| agentServerCA.sourceSecret | string | `"cluster-gateway-ca"` |  |
| agentServerCA.store | string | `"mgmt-openchoreo"` |  |
| buildkitMirrors.caFile | string | `"/registry-ca/ca.crt"` |  |
| buildkitMirrors.configMapName | string | `"buildkitd-config"` |  |
| buildkitMirrors.enabled | bool | `true` |  |
| cluster.name | string | `"mgmt"` |  |
| clusterAgentRBAC.enabled | bool | `true` | Least-privilege agent RBAC (`clusterAgentRBAC.{enabled,serviceAccount,runNamespacePrefix}`) instead of the upstream ClusterRole (`openchoreo-workflow-plane.clusterAgent.rbac.create: false`; [build plane](../../docs/build-plane.md#security-posture-of-build-pods)). |
| clusterAgentRBAC.runNamespacePrefix | string | `"workflows-"` |  |
| clusterAgentRBAC.serviceAccount | string | `"cluster-agent-workflowplane"` |  |
| clusterWorkflowPlane.name | string | `"default"` | Binds `ClusterWorkflowPlane/default` (`clusterWorkflowPlane.{name,planeID,secretStore}`) to the key-scoped `ClusterSecretStore/workflows`. |
| clusterWorkflowPlane.planeID | string | `"default"` |  |
| clusterWorkflowPlane.secretStore | string | `"workflows"` |  |
| images.BUILDKIT_IMAGE | string | `"docker.io/moby/buildkit:v0.35.0-rootless@sha256:5987568f92dafbfb679879de59c1cd8d26597f5f6635c314e166164e2615870c"` |  |
| images.POSTGRES_IMAGE | string | `"docker.io/library/postgres:17.12-alpine@sha256:34261f594522cf41dfcb76aefd42b9d201098b0e6b23c9c68733f169e4218b6f"` |  |
| images.TOOLBOX_IMAGE | string | `"ghcr.io/koorikla/platform/ci-toolbox:dbf92f6@sha256:c44cc8e8df235cfa694b5f7480cce4ea0bd013478bf237782fd043b29184948e"` |  |
| openchoreo-workflow-plane.argo-workflows.commonLabels."openchoreo.dev/plane" | string | `"workflowplane"` |  |
| openchoreo-workflow-plane.argo-workflows.commonLabels."openchoreo.dev/plane-id" | string | `"default"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.image.tag | string | `"v4.0.8@sha256:7a156419f80285859fc8f859927b6cc249f0d128e161e080dc17fca8fcbbceb6"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.resources.limits.cpu | string | `"500m"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.resources.requests.cpu | string | `"25m"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.resources.requests.memory | string | `"64Mi"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.workflowDefaults.spec.podGC.strategy | string | `"OnPodCompletion"` |  |
| openchoreo-workflow-plane.argo-workflows.controller.workflowDefaults.spec.ttlStrategy.secondsAfterCompletion | int | `86400` |  |
| openchoreo-workflow-plane.argo-workflows.controller.workflowNamespaces | list | `[]` |  |
| openchoreo-workflow-plane.argo-workflows.crds.full | bool | `false` |  |
| openchoreo-workflow-plane.argo-workflows.crds.install | bool | `true` |  |
| openchoreo-workflow-plane.argo-workflows.executor.image.tag | string | `"v4.0.8@sha256:86a965d7eea176959351156e24f3a2fa8d8e342e477ef425009af95a12e3fe87"` |  |
| openchoreo-workflow-plane.argo-workflows.executor.resources.limits.cpu | string | `"200m"` |  |
| openchoreo-workflow-plane.argo-workflows.executor.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-workflow-plane.argo-workflows.executor.resources.requests.cpu | string | `"10m"` |  |
| openchoreo-workflow-plane.argo-workflows.executor.resources.requests.memory | string | `"32Mi"` |  |
| openchoreo-workflow-plane.argo-workflows.images.pullPolicy | string | `"IfNotPresent"` |  |
| openchoreo-workflow-plane.argo-workflows.server.enabled | bool | `false` |  |
| openchoreo-workflow-plane.argo-workflows.workflow.serviceAccount.create | bool | `false` |  |
| openchoreo-workflow-plane.clusterAgent.image.tag | string | `"v1.3.3@sha256:de4907fcf4ffa6822dcbcaff876b02861bae0804c3aa86db6df64f918ef8451c"` |  |
| openchoreo-workflow-plane.clusterAgent.planeID | string | `"default"` |  |
| openchoreo-workflow-plane.clusterAgent.rbac.create | bool | `false` |  |
| openchoreo-workflow-plane.clusterAgent.resources.limits.cpu | string | `"100m"` |  |
| openchoreo-workflow-plane.clusterAgent.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-workflow-plane.clusterAgent.resources.requests.cpu | string | `"10m"` |  |
| openchoreo-workflow-plane.clusterAgent.resources.requests.memory | string | `"64Mi"` |  |
| openchoreo-workflow-plane.clusterAgent.serverUrl | string | `"wss://cluster-gateway.openchoreo-control-plane.svc.cluster.local:8443/ws"` |  |
| openchoreo-workflow-plane.clusterAgent.tls.caSecretName | string | `""` |  |
| openchoreo-workflow-plane.clusterAgent.tls.clientSecretName | string | `"cluster-agent-tls"` |  |
| openchoreo-workflow-plane.clusterAgent.tls.enabled | bool | `true` |  |
| openchoreo-workflow-plane.clusterAgent.tls.generateCerts | bool | `true` |  |
| openchoreo-workflow-plane.clusterAgent.tls.secretName | string | `"cluster-agent-tls"` |  |
| openchoreo-workflow-plane.clusterAgent.tls.serverCAConfigMap | string | `"cluster-gateway-ca"` |  |
| openchoreo.observability.enabled | bool | `true` |  |
| openchoreo.observability.httpPort | int | `11080` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| openchoreo.workflowPlane.enabled | bool | `true` |  |
| registry.host | string | `"harbor.openchoreo.localhost:9443"` |  |
| registry.proxyCache[0].project | string | `"dockerhub"` |  |
| registry.proxyCache[0].upstream | string | `"docker.io"` |  |
| registry.proxyCache[1].project | string | `"ghcr"` |  |
| registry.proxyCache[1].upstream | string | `"ghcr.io"` |  |
| registry.proxyCache[2].project | string | `"quay"` |  |
| registry.proxyCache[2].upstream | string | `"quay.io"` |  |
| registry.proxyCache[3].project | string | `"k8s"` |  |
| registry.proxyCache[3].upstream | string | `"registry.k8s.io"` |  |
| registry.proxyCache[4].project | string | `"openchoreo"` |  |
| registry.proxyCache[4].upstream | string | `"cr.openchoreo.dev"` |  |
| registry.proxyCache[5].project | string | `"gcr"` |  |
| registry.proxyCache[5].upstream | string | `"gcr.io"` |  |
| registry.type | string | `"harbor"` |  |
| runExecutorToken.enabled | bool | `true` |  |
| runExecutorToken.serviceAccount | string | `"workflow-sa"` |  |
| runNetworkPolicy.apiServer[0].cidr | string | `"10.43.0.1/32"` |  |
| runNetworkPolicy.apiServer[0].port | int | `443` |  |
| runNetworkPolicy.apiServer[1].cidr | string | `"0.0.0.0/0"` |  |
| runNetworkPolicy.apiServer[1].port | int | `6443` |  |
| runNetworkPolicy.enabled | bool | `true` | Restricts build/gate pod egress (`runNetworkPolicy.{enabled,registry,apiServer}`) in `workflows-*` namespaces. |
| runNetworkPolicy.internet.exceptCIDRs[0] | string | `"10.0.0.0/8"` |  |
| runNetworkPolicy.internet.exceptCIDRs[1] | string | `"172.16.0.0/12"` |  |
| runNetworkPolicy.internet.exceptCIDRs[2] | string | `"192.168.0.0/16"` |  |
| runNetworkPolicy.internet.exceptCIDRs[3] | string | `"100.64.0.0/10"` |  |
| runNetworkPolicy.internet.exceptCIDRs[4] | string | `"169.254.0.0/16"` |  |
| runNetworkPolicy.internet.ports[0] | int | `80` |  |
| runNetworkPolicy.internet.ports[1] | int | `443` |  |
| runNetworkPolicy.platformWorkflows.controlPlane.namespace | string | `"openchoreo-control-plane"` |  |
| runNetworkPolicy.platformWorkflows.controlPlane.podLabels."gateway.networking.k8s.io/gateway-name" | string | `"gateway-default"` |  |
| runNetworkPolicy.platformWorkflows.controlPlane.port | int | `8080` |  |
| runNetworkPolicy.platformWorkflows.enabled | bool | `true` |  |
| runNetworkPolicy.platformWorkflows.observability.namespace | string | `"openchoreo-observability-plane"` |  |
| runNetworkPolicy.platformWorkflows.observability.podLabels."gateway.networking.k8s.io/gateway-name" | string | `"gateway-default"` |  |
| runNetworkPolicy.platformWorkflows.observability.prometheus.podLabels."app.kubernetes.io/name" | string | `"prometheus"` |  |
| runNetworkPolicy.platformWorkflows.observability.prometheus.podLabels."operator.prometheus.io/name" | string | `"openchoreo-observability"` |  |
| runNetworkPolicy.platformWorkflows.observability.prometheus.ports[0] | int | `9090` |  |
| runNetworkPolicy.platformWorkflows.podLabels."platform.koorikla.io/egress" | string | `"openchoreo"` |  |
| runNetworkPolicy.registry.enabled | bool | `true` |  |
| runNetworkPolicy.registry.namespace | string | `"harbor"` |  |
| runNetworkPolicy.registry.podLabels."gateway.networking.k8s.io/gateway-name" | string | `"harbor"` |  |
| runNetworkPolicy.registry.port | int | `9443` |  |

Validation: `values.schema.json` checks the platform's own keys (types, required keys, names; Helm prints the failing
path). Cross-field rules against `installation.yaml` live in `templates/validate.yaml`. Upstream subchart keys are not
constrained.

## Day-2 notes

- Workflow controller crash loops and upgrades: [incidents](../../docs/runbooks/incidents.md#workflows-controller-crash-loop) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [Build plane](../../docs/build-plane.md)