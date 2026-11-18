# openchoreo-observability-plane

## Purpose

Wrapper chart for `openchoreo-observability-plane` (`1.3.3`) plus OpenSearch logs (`0.7.0`), OpenSearch traces (`0.8.0`), and Prometheus metrics (`0.8.0`) on `mgmt`. Runs `ClusterObservabilityPlane/default`, the `observer` API, Alertmanager, and ingress `Gateway`s receiving telemetry from workload clusters.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-observability-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-observability-plane` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| agentServerCA.configMapName | string | `"cluster-gateway-ca"` |  |
| agentServerCA.enabled | bool | `true` |  |
| agentServerCA.sourceSecret | string | `"cluster-gateway-ca"` |  |
| agentServerCA.store | string | `"mgmt-openchoreo"` |  |
| cluster.name | string | `"mgmt"` |  |
| clusterObservabilityPlane.name | string | `"default"` | Registers `ClusterObservabilityPlane/default` (`clusterObservabilityPlane.{name,planeID}`) and syncs `cluster-gateway-ca` (`agentServerCA`). |
| clusterObservabilityPlane.planeID | string | `"default"` |  |
| observability-logs-opensearch.adapter.image.tag | string | `"0.7.0@sha256:a3921d5aec41452f3a9a440325bc64c4a73dd3e139bac66032bf226b0a86eaaf"` |  |
| observability-logs-opensearch.adapter.openSearchSecretName | string | `"opensearch-admin-credentials"` |  |
| observability-logs-opensearch.adapter.resources.limits.cpu | string | `"100m"` |  |
| observability-logs-opensearch.adapter.resources.limits.memory | string | `"128Mi"` |  |
| observability-logs-opensearch.adapter.resources.requests.cpu | string | `"20m"` |  |
| observability-logs-opensearch.adapter.resources.requests.memory | string | `"48Mi"` |  |
| observability-logs-opensearch.fluent-bit.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearch.enabled | bool | `true` |  |
| observability-logs-opensearch.openSearch.extraEnvs[0].name | string | `"OPENSEARCH_INITIAL_ADMIN_PASSWORD"` |  |
| observability-logs-opensearch.openSearch.extraEnvs[0].valueFrom.secretKeyRef.key | string | `"password"` |  |
| observability-logs-opensearch.openSearch.extraEnvs[0].valueFrom.secretKeyRef.name | string | `"opensearch-admin-credentials"` |  |
| observability-logs-opensearch.openSearch.image.repository | string | `"docker.io/opensearchproject/opensearch"` |  |
| observability-logs-opensearch.openSearch.image.tag | string | `"3.3.0@sha256:d96afaf6cbd2a6a3695aeb2f1d48c9a16ad5c8918eb849e5cbf43475f0f8e146"` |  |
| observability-logs-opensearch.openSearch.majorVersion | string | `"3"` |  |
| observability-logs-opensearch.openSearch.opensearchJavaOpts | string | `"-Xms512m -Xmx512m -XX:ActiveProcessorCount=1"` |  |
| observability-logs-opensearch.openSearch.persistence.enabled | bool | `true` |  |
| observability-logs-opensearch.openSearch.persistence.image | string | `"docker.io/library/busybox"` |  |
| observability-logs-opensearch.openSearch.persistence.imageTag | string | `"1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"` |  |
| observability-logs-opensearch.openSearch.persistence.size | string | `"8Gi"` |  |
| observability-logs-opensearch.openSearch.resources.limits.cpu | string | `"1"` |  |
| observability-logs-opensearch.openSearch.resources.limits.memory | string | `"1536Mi"` |  |
| observability-logs-opensearch.openSearch.resources.requests.cpu | string | `"200m"` |  |
| observability-logs-opensearch.openSearch.resources.requests.memory | string | `"1Gi"` |  |
| observability-logs-opensearch.openSearch.singleNode | bool | `true` |  |
| observability-logs-opensearch.openSearch.sysctlInit.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearch.sysctlInit.image | string | `"docker.io/library/busybox"` |  |
| observability-logs-opensearch.openSearch.sysctlInit.imageTag | string | `"1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"` |  |
| observability-logs-opensearch.openSearchCluster.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearchSetup.dataRetentionTime.auditLogs | string | `"30d"` |  |
| observability-logs-opensearch.openSearchSetup.dataRetentionTime.containerLogs | string | `"7d"` |  |
| observability-logs-opensearch.openSearchSetup.dataRetentionTime.k8sEvents | string | `"7d"` |  |
| observability-logs-opensearch.openSearchSetup.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearchSetup.image.tag | string | `"0.7.0@sha256:4c1b5bef4e4eee94ad965146371fbc81e123bc1e435c530d177f42024bb257f3"` |  |
| observability-logs-opensearch.openSearchSetup.openSearchSecretName | string | `"opensearch-admin-credentials"` |  |
| observability-logs-opensearch.openSearchSetup.run | bool | `true` |  |
| observability-metrics-prometheus.adapter.image.tag | string | `"0.8.0@sha256:97e67d24a826e1e6ab01517dab08ef84306c856b74a37badfc9d5f9b83b49f35"` |  |
| observability-metrics-prometheus.adapter.resources.limits.cpu | string | `"100m"` |  |
| observability-metrics-prometheus.adapter.resources.limits.memory | string | `"128Mi"` |  |
| observability-metrics-prometheus.adapter.resources.requests.cpu | string | `"10m"` |  |
| observability-metrics-prometheus.adapter.resources.requests.memory | string | `"48Mi"` |  |
| observability-metrics-prometheus.global.installationMode | string | `"multiClusterReceiver"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.image.sha | string | `"e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.image.tag | string | `"v0.34.1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.resources.limits.cpu | string | `"100m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.resources.limits.memory | string | `"128Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.resources.requests.cpu | string | `"10m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.alertmanagerSpec.resources.requests.memory | string | `"48Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubeStateMetrics.enabled | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubelet.enabled | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubernetesServiceMonitors.enabled | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.image.sha | string | `"451a845bae1d51622b41af1780eb2ad911bbb79a9855bc8e9bb67fabbc03f934"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.image.tag | string | `"v3.15.1-distroless"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.resources.limits.cpu | string | `"1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.resources.limits.memory | string | `"1Gi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.resources.requests.cpu | string | `"100m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.resources.requests.memory | string | `"384Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.retention | string | `"7d"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.retentionSize | string | `"6GiB"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0] | string | `"ReadWriteOnce"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage | string | `"8Gi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.admissionWebhooks.certManager.enabled | bool | `true` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.image.sha | string | `"7c88d4e7bae63bd8d0f8da986054337c23b4472fa8d3c6817f5bc4b8407a2d6a"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.image.tag | string | `"v0.94.1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.prometheusConfigReloader.image.sha | string | `"06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.prometheusConfigReloader.image.tag | string | `"v0.94.1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.limits.cpu | string | `"500m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.limits.memory | string | `"256Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.requests.cpu | string | `"20m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.requests.memory | string | `"64Mi"` |  |
| observability-metrics-prometheus.prometheusCustomizations.http.hostnames[0] | string | `"prometheus.observability.openchoreo.localhost"` |  |
| observability-tracing-opensearch.adapter.image.tag | string | `"0.8.0@sha256:57a13f88cd17c2316137be5c82a4c9fa826b878f6eddb99e0f6a289f7b5deae2"` |  |
| observability-tracing-opensearch.adapter.openSearchSecretName | string | `"opensearch-admin-credentials"` |  |
| observability-tracing-opensearch.adapter.resources.limits.cpu | string | `"100m"` |  |
| observability-tracing-opensearch.adapter.resources.limits.memory | string | `"128Mi"` |  |
| observability-tracing-opensearch.adapter.resources.requests.cpu | string | `"20m"` |  |
| observability-tracing-opensearch.adapter.resources.requests.memory | string | `"48Mi"` |  |
| observability-tracing-opensearch.global.installationMode | string | `"multiClusterReceiver"` |  |
| observability-tracing-opensearch.openSearch.enabled | bool | `false` |  |
| observability-tracing-opensearch.openSearchSetup.dataRetentionTime.traces | string | `"7d"` |  |
| observability-tracing-opensearch.openSearchSetup.image.tag | string | `"0.8.0@sha256:dfb2305dcfd799c4476aa6915c815da4e5239539e2e8c5f4bc17fae0325c6df0"` |  |
| observability-tracing-opensearch.openSearchSetup.openSearchSecretName | string | `"opensearch-admin-credentials"` |  |
| observability-tracing-opensearch.opentelemetry-collector.image.repository | string | `"docker.io/otel/opentelemetry-collector-contrib"` |  |
| observability-tracing-opensearch.opentelemetry-collector.image.tag | string | `"0.163.2@sha256:7f22d2a6748110ffb6a59bc0df448bccbf501cdb667d610ede4c61d3863d5849"` |  |
| observability-tracing-opensearch.opentelemetry-collector.resources.limits.cpu | string | `"200m"` |  |
| observability-tracing-opensearch.opentelemetry-collector.resources.limits.memory | string | `"256Mi"` |  |
| observability-tracing-opensearch.opentelemetry-collector.resources.requests.cpu | string | `"50m"` |  |
| observability-tracing-opensearch.opentelemetry-collector.resources.requests.memory | string | `"128Mi"` |  |
| observability-tracing-opensearch.opentelemetryCollectorCustomizations.http.hostnames[0] | string | `"opentelemetry.observability.openchoreo.localhost"` |  |
| observability-tracing-opensearch.opentelemetryCollectorCustomizations.tailSampling.enabled | bool | `false` |  |
| openchoreo-observability-plane.clusterAgent.image.tag | string | `"v1.3.3@sha256:de4907fcf4ffa6822dcbcaff876b02861bae0804c3aa86db6df64f918ef8451c"` |  |
| openchoreo-observability-plane.clusterAgent.planeID | string | `"default"` |  |
| openchoreo-observability-plane.clusterAgent.resources.limits.cpu | string | `"100m"` |  |
| openchoreo-observability-plane.clusterAgent.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-observability-plane.clusterAgent.resources.requests.cpu | string | `"10m"` |  |
| openchoreo-observability-plane.clusterAgent.resources.requests.memory | string | `"64Mi"` |  |
| openchoreo-observability-plane.clusterAgent.serverUrl | string | `"wss://cluster-gateway.openchoreo-control-plane.svc.cluster.local:8443/ws"` |  |
| openchoreo-observability-plane.clusterAgent.tls.caSecretName | string | `""` |  |
| openchoreo-observability-plane.clusterAgent.tls.clientSecretName | string | `"cluster-agent-tls"` |  |
| openchoreo-observability-plane.clusterAgent.tls.enabled | bool | `true` |  |
| openchoreo-observability-plane.clusterAgent.tls.generateCerts | bool | `true` |  |
| openchoreo-observability-plane.clusterAgent.tls.secretName | string | `"cluster-agent-tls"` |  |
| openchoreo-observability-plane.clusterAgent.tls.serverCAConfigMap | string | `"cluster-gateway-ca"` |  |
| openchoreo-observability-plane.controllerManager.image.tag | string | `"v1.3.3@sha256:ce7e9d6394cd10bdd7d4f9f5746468b3f1f010b714b878a8a51051aac0b97863"` |  |
| openchoreo-observability-plane.controllerManager.resources.limits.cpu | string | `"500m"` |  |
| openchoreo-observability-plane.controllerManager.resources.limits.memory | string | `"512Mi"` |  |
| openchoreo-observability-plane.controllerManager.resources.requests.cpu | string | `"20m"` |  |
| openchoreo-observability-plane.controllerManager.resources.requests.memory | string | `"96Mi"` |  |
| openchoreo-observability-plane.finOpsAgent.cors.allowedOrigins[0] | string | `"http://openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.finOpsAgent.enabled | bool | `false` |  |
| openchoreo-observability-plane.finOpsAgent.http.hostnames[0] | string | `"finops-agent.openchoreo.localhost"` |  |
| openchoreo-observability-plane.finOpsAgent.image.tag | string | `"v1.3.3@sha256:1875e43e83d25c90dfc16703eb3b9ec3d12cd280117313c79e09f2348022564c"` |  |
| openchoreo-observability-plane.finOpsAgent.llmBaseUrl | string | `"http://agentgateway-proxy.agentgateway-system.svc.cluster.local"` |  |
| openchoreo-observability-plane.finOpsAgent.llmName | string | `""` |  |
| openchoreo-observability-plane.finOpsAgent.oauth.clientId | string | `"openchoreo-finops-agent"` |  |
| openchoreo-observability-plane.finOpsAgent.openchoreoApiUrl | string | `"http://api.openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.finOpsAgent.secretName | string | `"finops-agent"` |  |
| openchoreo-observability-plane.gateway.httpPort | int | `11080` |  |
| openchoreo-observability-plane.gateway.httpsPort | int | `11085` |  |
| openchoreo-observability-plane.gateway.tls.enabled | bool | `false` |  |
| openchoreo-observability-plane.gateway.tlsPassthrough.enabled | bool | `true` |  |
| openchoreo-observability-plane.gateway.tlsPassthrough.hostname | string | `"opensearch.observability.openchoreo.localhost"` |  |
| openchoreo-observability-plane.gateway.tlsPassthrough.port | int | `11085` |  |
| openchoreo-observability-plane.observer.alertStoreSqliteSize | string | `"128Mi"` |  |
| openchoreo-observability-plane.observer.controlPlaneApiUrl | string | `"http://api.openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.observer.cors.allowedOrigins[0] | string | `"http://openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.observer.extraEnvs[0].name | string | `"OBSERVER_BASE_URL"` |  |
| openchoreo-observability-plane.observer.extraEnvs[0].value | string | `"http://observer.openchoreo.localhost:11080"` |  |
| openchoreo-observability-plane.observer.extraEnvs[1].name | string | `"AUTHZ_TIMEOUT"` |  |
| openchoreo-observability-plane.observer.extraEnvs[1].value | string | `"30s"` |  |
| openchoreo-observability-plane.observer.http.hostnames[0] | string | `"observer.openchoreo.localhost"` |  |
| openchoreo-observability-plane.observer.image.tag | string | `"v1.3.3@sha256:58f27ddf5ff2d701b92178ad552bfb069e1a55811dfea411b83cf61fcb680be1"` |  |
| openchoreo-observability-plane.observer.resources.limits.cpu | string | `"200m"` |  |
| openchoreo-observability-plane.observer.resources.limits.memory | string | `"256Mi"` |  |
| openchoreo-observability-plane.observer.resources.requests.cpu | string | `"50m"` |  |
| openchoreo-observability-plane.observer.resources.requests.memory | string | `"128Mi"` |  |
| openchoreo-observability-plane.observer.secretName | string | `"observer-secret"` |  |
| openchoreo-observability-plane.rca.cors.allowedOrigins[0] | string | `"http://openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.rca.enabled | bool | `false` |  |
| openchoreo-observability-plane.rca.http.hostnames[0] | string | `"rca-agent.openchoreo.localhost"` |  |
| openchoreo-observability-plane.rca.image.tag | string | `"v1.3.3@sha256:f61a2ac460f6eecde24cdbb36f6ab87e2b37a0827f318800a2dbb297ac23e8b5"` |  |
| openchoreo-observability-plane.rca.llm.baseUrl | string | `"http://agentgateway-proxy.agentgateway-system.svc.cluster.local"` |  |
| openchoreo-observability-plane.rca.llm.modelName | string | `""` |  |
| openchoreo-observability-plane.rca.oauth.clientId | string | `"openchoreo-rca-agent"` |  |
| openchoreo-observability-plane.rca.openchoreoApiUrl | string | `"http://api.openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.rca.resources.limits.cpu | string | `"250m"` |  |
| openchoreo-observability-plane.rca.resources.limits.memory | string | `"1536Mi"` |  |
| openchoreo-observability-plane.rca.resources.requests.cpu | string | `"50m"` |  |
| openchoreo-observability-plane.rca.resources.requests.memory | string | `"512Mi"` |  |
| openchoreo-observability-plane.rca.secretName | string | `"rca-agent-secret"` |  |
| openchoreo-observability-plane.security.oidc.authServerBaseUrl | string | `"http://thunder.openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.security.oidc.issuer | string | `"http://thunder.openchoreo.localhost:8080"` |  |
| openchoreo-observability-plane.security.oidc.jwksUrl | string | `"http://thunder.openchoreo.localhost:8080/oauth2/jwks"` |  |
| openchoreo-observability-plane.security.oidc.tokenUrl | string | `"http://thunder.openchoreo.localhost:8080/oauth2/token"` |  |
| openchoreo-observability-plane.tls.enabled | bool | `false` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` |  |
| openchoreo.observability.enabled | bool | `true` | HTTP (`httpPort: 11080`) and OpenSearch TLS passthrough (`tlsPort: 11085`) Gateway ports. |
| openchoreo.observability.httpPort | int | `11080` |  |
| openchoreo.observability.tlsPort | int | `11085` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| openchoreo.workflowPlane.enabled | bool | `true` |  |
| prometheusIngress.enabled | bool | `true` | `NetworkPolicy` allowing `promotion-gate` pods (`platform.koorikla.io/egress: openchoreo`) to query Prometheus. |
| prometheusIngress.fromPodLabels."platform.koorikla.io/egress" | string | `"openchoreo"` |  |
| prometheusIngress.podLabels."app.kubernetes.io/name" | string | `"prometheus"` |  |
| prometheusIngress.podLabels."operator.prometheus.io/name" | string | `"openchoreo-observability"` |  |
| prometheusIngress.ports[0] | int | `9090` |  |
| secrets.aiRemoteKey | string | `"openchoreo-ai"` |  |
| secrets.remoteKey | string | `"openchoreo-observability"` |  |
| secrets.store | string | `"platform"` | Pulls OpenSearch/observer (`openchoreo-observability`) and optional AI agent (`openchoreo-ai`) credentials (`secrets.{store,remoteKey,aiRemoteKey}`) from `ClusterSecretStore/platform`. |

## Day-2 notes

- Querying Prometheus/OpenSearch and checking observability readiness: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [Observability and runtime security](../../docs/observability.md)