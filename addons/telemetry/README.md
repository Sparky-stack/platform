# telemetry

## Purpose

Wrapper chart for workload data-plane telemetry: node-local OpenTelemetry Collector (`0.163.2`), Fluent Bit logs (`0.7.0`), Prometheus agent metrics (`0.8.0`), and Kubernetes events (`0.1.2`), shipping signals to `mgmt`'s observability plane (and optionally Datadog).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: telemetry`).
- **Catalog label:** `addons.platform.koorikla.io/telemetry` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.name | string | `"default"` |  |
| datadog.enabled | bool | `false` | Optional dual-shipping to Datadog (`datadog.{enabled,remoteKey,property}`; `false` by default). |
| datadog.property | string | `"api-key"` |  |
| datadog.remoteKey | string | `"datadog"` |  |
| gatewayMetrics.enabled | bool | `true` |  |
| gatewayMetrics.keep | string | `"envoy_cluster_upstream_rq"` |  |
| hubbleMetrics.enabled | bool | `true` |  |
| hubbleMetrics.keep | string | `"hubble_http_(requests_total|request_duration_seconds_(bucket|sum|count))"` |  |
| observability-events-otel-collector.collector.extraEnv[0].name | string | `"OPENSEARCH_USERNAME"` |  |
| observability-events-otel-collector.collector.extraEnv[0].valueFrom.secretKeyRef.key | string | `"username"` |  |
| observability-events-otel-collector.collector.extraEnv[0].valueFrom.secretKeyRef.name | string | `"opensearch-admin-credentials"` |  |
| observability-events-otel-collector.collector.extraEnv[1].name | string | `"OPENSEARCH_PASSWORD"` |  |
| observability-events-otel-collector.collector.extraEnv[1].valueFrom.secretKeyRef.key | string | `"password"` |  |
| observability-events-otel-collector.collector.extraEnv[1].valueFrom.secretKeyRef.name | string | `"opensearch-admin-credentials"` |  |
| observability-events-otel-collector.collector.image.tag | string | `"0.1.2@sha256:2ac7562b98dfb9c1837593dbc585f279856f15cb6c52f438621dd82d313dcc75"` |  |
| observability-events-otel-collector.collector.resources.limits.memory | string | `"256Mi"` |  |
| observability-events-otel-collector.collector.resources.requests.cpu | string | `"10m"` |  |
| observability-events-otel-collector.collector.resources.requests.memory | string | `"48Mi"` |  |
| observability-events-otel-collector.enabled | bool | `true` |  |
| observability-events-otel-collector.exporters.opensearch.http.auth.authenticator | string | `"basicauth/opensearch"` |  |
| observability-events-otel-collector.exporters.opensearch.http.endpoint | string | `"https://opensearch.observability.openchoreo.localhost:11085"` |  |
| observability-events-otel-collector.exporters.opensearch.http.tls.insecure_skip_verify | bool | `true` |  |
| observability-events-otel-collector.exporters.opensearch.logs_index | string | `"k8s-events"` |  |
| observability-events-otel-collector.exporters.opensearch.logs_index_time_format | string | `"yyyy-MM-dd"` |  |
| observability-events-otel-collector.extraExtensions.basicauth/opensearch.client_auth.password | string | `"${env:OPENSEARCH_PASSWORD}"` |  |
| observability-events-otel-collector.extraExtensions.basicauth/opensearch.client_auth.username | string | `"${env:OPENSEARCH_USERNAME}"` |  |
| observability-events-otel-collector.pipelineExporters[0] | string | `"opensearch"` |  |
| observability-logs-opensearch.adapter.enabled | bool | `false` |  |
| observability-logs-opensearch.fluent-bit.enabled | bool | `true` |  |
| observability-logs-opensearch.fluent-bit.envFrom[0].configMapRef.name | string | `"telemetry-env"` |  |
| observability-logs-opensearch.fluent-bit.image.digest | string | `"sha256:2740f387f6e68fab66d28e4fa6a853387b9cab6ffb4cb78958f69bba4eb0e7b4"` |  |
| observability-logs-opensearch.fluent-bit.image.repository | string | `"cr.fluentbit.io/fluent/fluent-bit"` |  |
| observability-logs-opensearch.fluent-bit.image.tag | string | `"5.1.5"` |  |
| observability-logs-opensearch.fluent-bit.initContainers | string | `"- name: set-volume-ownership\n  image: \"{{ with .Values.global.imageRegistry }}{{ . }}/{{ end }}docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec\"\n  command: [\"sh\", \"-c\", \"chown -R 10000:10000 /var/lib/fluent-bit/db\"]\n  resources:\n    limits:\n      cpu: 15m\n      memory: \"32Mi\"\n    requests:\n      cpu: 10m\n      memory: \"24Mi\"\n  securityContext:\n    capabilities:\n      drop:\n      - ALL\n      add:\n      - CHOWN\n    readOnlyRootFilesystem: true\n    runAsUser: 0\n  volumeMounts:\n  - name: db\n    mountPath: /var/lib/fluent-bit/db\n{{- if .Values.waitForIndexTemplate.enabled }}\n- name: wait-for-index-template\n  image: \"{{ with .Values.global.imageRegistry }}{{ . }}/{{ end }}{{ .Values.waitForIndexTemplate.image }}\"\n  command:\n  - sh\n  - -c\n  - |\n    for t in $TEMPLATES; do\n      until [ \"$(curl -sk -o /dev/null -w '%{http_code}' -u \"$OPENSEARCH_USERNAME:$OPENSEARCH_PASSWORD\" \\\n            --connect-to \"$OPENSEARCH_VHOST:$OPENSEARCH_PORT:$OPENSEARCH_HOST:$OPENSEARCH_PORT\" \\\n            \"https://$OPENSEARCH_VHOST:$OPENSEARCH_PORT/_index_template/$t\")\" = \"200\" ]; do\n        echo \"Waiting for OpenSearch index template $t...\"\n        sleep 5\n      done\n      echo \"Index template $t found\"\n    done\n  env:\n  - name: OPENSEARCH_HOST\n    value: {{ .Values.openSearchHost | quote }}\n  - name: OPENSEARCH_PORT\n    value: {{ .Values.openSearchPort | quote }}\n  - name: OPENSEARCH_VHOST\n    value: {{ .Values.openSearchVHost | default \"opensearch\" | quote }}\n  - name: TEMPLATES\n    value: {{ join \" \" .Values.waitForIndexTemplate.templateNames | quote }}\n  - name: OPENSEARCH_USERNAME\n    valueFrom:\n      secretKeyRef:\n        name: {{ .Values.waitForIndexTemplate.credentialsSecretName }}\n        key: username\n  - name: OPENSEARCH_PASSWORD\n    valueFrom:\n      secretKeyRef:\n        name: {{ .Values.waitForIndexTemplate.credentialsSecretName }}\n        key: password\n  resources:\n    limits:\n      cpu: 15m\n      memory: \"32Mi\"\n    requests:\n      cpu: 10m\n      memory: \"24Mi\"\n  securityContext:\n    allowPrivilegeEscalation: false\n    capabilities:\n      drop:\n      - ALL\n    readOnlyRootFilesystem: true\n    runAsNonRoot: true\n    runAsUser: 10000\n{{- end }}"` |  |
| observability-logs-opensearch.fluent-bit.openSearchHost | string | `"k3d-platform-mgmt-serverlb"` |  |
| observability-logs-opensearch.fluent-bit.openSearchPort | int | `11085` |  |
| observability-logs-opensearch.fluent-bit.openSearchVHost | string | `"opensearch.observability.openchoreo.localhost"` |  |
| observability-logs-opensearch.fluent-bit.resources.limits.cpu | string | `"200m"` |  |
| observability-logs-opensearch.fluent-bit.resources.limits.memory | string | `"192Mi"` |  |
| observability-logs-opensearch.fluent-bit.resources.requests.cpu | string | `"20m"` |  |
| observability-logs-opensearch.fluent-bit.resources.requests.memory | string | `"64Mi"` |  |
| observability-logs-opensearch.fluent-bit.waitForIndexTemplate.image | string | `"docker.io/curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"` |  |
| observability-logs-opensearch.fluentBitCustomizations.clusterInstance | string | `"${CLUSTER_NAME}"` |  |
| observability-logs-opensearch.openSearch.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearchCluster.enabled | bool | `false` |  |
| observability-logs-opensearch.openSearchSetup.enabled | bool | `false` |  |
| observability-metrics-prometheus.global.installationMode | string | `"multiClusterExporter"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.alertmanager.enabled | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.image.sha | string | `"sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.image.tag | string | `"v2.20.0"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.resources.limits.cpu | string | `"100m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.resources.limits.memory | string | `"128Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.resources.requests.cpu | string | `"10m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kube-state-metrics.resources.requests.memory | string | `"32Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubelet.serviceMonitor.authorization.credentials.key | string | `"token"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubelet.serviceMonitor.authorization.credentials.name | string | `"openchoreo-prometheus-agent-token"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubelet.serviceMonitor.authorization.type | string | `"Bearer"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.kubelet.serviceMonitor.kubelet | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheus.enabled | bool | `false` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.admissionWebhooks.certManager.enabled | bool | `true` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.image.sha | string | `"7c88d4e7bae63bd8d0f8da986054337c23b4472fa8d3c6817f5bc4b8407a2d6a"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.image.tag | string | `"v0.94.1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.prometheusConfigReloader.image.sha | string | `"06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.prometheusConfigReloader.image.tag | string | `"v0.94.1"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.limits.cpu | string | `"500m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.limits.memory | string | `"256Mi"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.requests.cpu | string | `"20m"` |  |
| observability-metrics-prometheus.kube-prometheus-stack.prometheusOperator.resources.requests.memory | string | `"64Mi"` |  |
| observability-metrics-prometheus.prometheusCustomizations.agent.image | string | `"quay.io/prometheus/prometheus:v3.15.1-distroless@sha256:451a845bae1d51622b41af1780eb2ad911bbb79a9855bc8e9bb67fabbc03f934"` |  |
| observability-metrics-prometheus.prometheusCustomizations.http.observabilityPlaneUrl | string | `"http://prometheus.observability.openchoreo.localhost:11080/api/v1/write"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` | `mgmt` ingestion endpoints (with `openchoreo.observability.{httpPort,tlsPort}`) for remote-write, OTLP, and OpenSearch. |
| openchoreo.observability.enabled | bool | `true` |  |
| openchoreo.observability.httpPort | int | `11080` |  |
| openchoreo.observability.tlsPort | int | `11085` |  |
| opentelemetry-collector.alternateConfig.exporters.nop | object | `{}` |  |
| opentelemetry-collector.alternateConfig.exporters.otlp_http/observability.endpoint | string | `"${env:OBS_OTLP_ENDPOINT}"` |  |
| opentelemetry-collector.alternateConfig.exporters.otlp_http/observability.tls.insecure | bool | `true` |  |
| opentelemetry-collector.alternateConfig.exporters.prometheusremotewrite/observability.endpoint | string | `"${env:OBS_REMOTE_WRITE_URL}"` |  |
| opentelemetry-collector.alternateConfig.exporters.prometheusremotewrite/observability.resource_to_telemetry_conversion.enabled | bool | `true` |  |
| opentelemetry-collector.alternateConfig.exporters.prometheusremotewrite/observability.tls.insecure | bool | `true` |  |
| opentelemetry-collector.alternateConfig.extensions.health_check.endpoint | string | `"${env:MY_POD_IP}:13133"` |  |
| opentelemetry-collector.alternateConfig.processors.batch | object | `{}` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.auth_type | string | `"serviceAccount"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.labels[0].from | string | `"pod"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.labels[0].key_regex | string | `"(.*)"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.labels[0].tag_name | string | `"$$1"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.metadata[0] | string | `"k8s.pod.name"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.metadata[1] | string | `"k8s.pod.uid"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.metadata[2] | string | `"k8s.deployment.name"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.metadata[3] | string | `"k8s.namespace.name"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.extract.metadata[4] | string | `"k8s.node.name"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.filter.node_from_env_var | string | `"OTEL_K8S_NODE_NAME"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.passthrough | bool | `false` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.pod_association[0].sources[0].from | string | `"resource_attribute"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.pod_association[0].sources[0].name | string | `"k8s.pod.uid"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.pod_association[1].sources[0].from | string | `"resource_attribute"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.pod_association[1].sources[0].name | string | `"k8s.pod.ip"` |  |
| opentelemetry-collector.alternateConfig.processors.k8s_attributes.pod_association[2].sources[0].from | string | `"connection"` |  |
| opentelemetry-collector.alternateConfig.processors.memory_limiter.check_interval | string | `"5s"` |  |
| opentelemetry-collector.alternateConfig.processors.memory_limiter.limit_percentage | int | `80` |  |
| opentelemetry-collector.alternateConfig.processors.memory_limiter.spike_limit_percentage | int | `25` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[0].action | string | `"upsert"` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[0].key | string | `"k8s.cluster.name"` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[0].value | string | `"${env:CLUSTER_NAME}"` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[1].action | string | `"upsert"` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[1].key | string | `"openchoreo_cluster_instance"` |  |
| opentelemetry-collector.alternateConfig.processors.resource/cluster.attributes[1].value | string | `"${env:CLUSTER_NAME}"` |  |
| opentelemetry-collector.alternateConfig.receivers.otlp.protocols.grpc.endpoint | string | `"${env:MY_POD_IP}:4317"` |  |
| opentelemetry-collector.alternateConfig.receivers.otlp.protocols.http.endpoint | string | `"${env:MY_POD_IP}:4318"` |  |
| opentelemetry-collector.alternateConfig.receivers.webhookevent/falco.endpoint | string | `"${env:MY_POD_IP}:8088"` |  |
| opentelemetry-collector.alternateConfig.receivers.webhookevent/falco.path | string | `"/falco"` |  |
| opentelemetry-collector.alternateConfig.service.extensions[0] | string | `"health_check"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.exporters[0] | string | `"nop"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.processors[0] | string | `"memory_limiter"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.processors[1] | string | `"k8s_attributes"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.processors[2] | string | `"resource/cluster"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.processors[3] | string | `"batch"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.receivers[0] | string | `"otlp"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.logs.receivers[1] | string | `"webhookevent/falco"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.exporters[0] | string | `"prometheusremotewrite/observability"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.processors[0] | string | `"memory_limiter"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.processors[1] | string | `"k8s_attributes"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.processors[2] | string | `"resource/cluster"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.processors[3] | string | `"batch"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.metrics.receivers[0] | string | `"otlp"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.exporters[0] | string | `"otlp_http/observability"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.processors[0] | string | `"memory_limiter"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.processors[1] | string | `"k8s_attributes"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.processors[2] | string | `"resource/cluster"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.processors[3] | string | `"batch"` |  |
| opentelemetry-collector.alternateConfig.service.pipelines.traces.receivers[0] | string | `"otlp"` |  |
| opentelemetry-collector.alternateConfig.service.telemetry.logs.level | string | `"info"` |  |
| opentelemetry-collector.clusterRole.create | bool | `true` |  |
| opentelemetry-collector.clusterRole.rules[0].apiGroups[0] | string | `""` |  |
| opentelemetry-collector.clusterRole.rules[0].resources[0] | string | `"pods"` |  |
| opentelemetry-collector.clusterRole.rules[0].resources[1] | string | `"namespaces"` |  |
| opentelemetry-collector.clusterRole.rules[0].resources[2] | string | `"nodes"` |  |
| opentelemetry-collector.clusterRole.rules[0].verbs[0] | string | `"get"` |  |
| opentelemetry-collector.clusterRole.rules[0].verbs[1] | string | `"list"` |  |
| opentelemetry-collector.clusterRole.rules[0].verbs[2] | string | `"watch"` |  |
| opentelemetry-collector.clusterRole.rules[1].apiGroups[0] | string | `"apps"` |  |
| opentelemetry-collector.clusterRole.rules[1].resources[0] | string | `"replicasets"` |  |
| opentelemetry-collector.clusterRole.rules[1].verbs[0] | string | `"get"` |  |
| opentelemetry-collector.clusterRole.rules[1].verbs[1] | string | `"list"` |  |
| opentelemetry-collector.clusterRole.rules[1].verbs[2] | string | `"watch"` |  |
| opentelemetry-collector.command.name | string | `"otelcol-contrib"` |  |
| opentelemetry-collector.extraEnvsFrom[0].configMapRef.name | string | `"telemetry-env"` |  |
| opentelemetry-collector.extraEnvsFrom[1].secretRef.name | string | `"telemetry-datadog"` |  |
| opentelemetry-collector.extraEnvsFrom[1].secretRef.optional | bool | `true` |  |
| opentelemetry-collector.fullnameOverride | string | `"telemetry-collector"` |  |
| opentelemetry-collector.image.repository | string | `"docker.io/otel/opentelemetry-collector-contrib"` |  |
| opentelemetry-collector.image.tag | string | `"0.163.2@sha256:7f22d2a6748110ffb6a59bc0df448bccbf501cdb667d610ede4c61d3863d5849"` |  |
| opentelemetry-collector.mode | string | `"daemonset"` | `daemonset` with `service.internalTrafficPolicy: Local` on OTLP port `4317`. |
| opentelemetry-collector.ports.falco.containerPort | int | `8088` |  |
| opentelemetry-collector.ports.falco.enabled | bool | `true` |  |
| opentelemetry-collector.ports.falco.protocol | string | `"TCP"` |  |
| opentelemetry-collector.ports.falco.servicePort | int | `8088` |  |
| opentelemetry-collector.ports.jaeger-compact.enabled | bool | `false` |  |
| opentelemetry-collector.ports.jaeger-grpc.enabled | bool | `false` |  |
| opentelemetry-collector.ports.jaeger-thrift.enabled | bool | `false` |  |
| opentelemetry-collector.ports.otlp-http.enabled | bool | `true` |  |
| opentelemetry-collector.ports.otlp.enabled | bool | `true` |  |
| opentelemetry-collector.ports.zipkin.enabled | bool | `false` |  |
| opentelemetry-collector.resources.limits.cpu | string | `"500m"` |  |
| opentelemetry-collector.resources.limits.memory | string | `"256Mi"` |  |
| opentelemetry-collector.resources.requests.cpu | string | `"20m"` |  |
| opentelemetry-collector.resources.requests.memory | string | `"64Mi"` |  |
| opentelemetry-collector.service.enabled | bool | `true` |  |
| opentelemetry-collector.service.internalTrafficPolicy | string | `"Local"` |  |
| secrets.remoteKey | string | `"openchoreo-observability"` |  |
| secrets.store | string | `"default"` | Pulls `openchoreo-observability` credentials (`secrets.{store,remoteKey}`) from workload `ClusterSecretStore/default`. |

Validation: `values.schema.json` checks the platform's own keys (types, required keys, names; Helm prints the failing
path). Cross-field rules against `installation.yaml` live in `templates/validate.yaml`. Upstream subchart keys are not
constrained.

## Day-2 notes

- Checking shipper readiness and the Prometheus agent active-series budget: [observability first look](../../docs/runbooks/observability-first-look.md#1-first-5-minute-triage-order-where-to-look-first).

## Links

- [Observability and runtime security](../../docs/observability.md)