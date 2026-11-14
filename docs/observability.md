# Observability and runtime security

OpenChoreo's **observability plane** stores logs, traces and metrics for everything OpenChoreo deploys. Backstage (Runtime
Logs / Metrics / Traces tabs, RuntimeHealthCard), openchoreo-api and the MCP servers read it through the **observer**
API. Data planes ship telemetry to it; an OpenTelemetry Collector on every workload cluster is the fan-out point, so
Datadog (or any other OTLP backend) is a values overlay. Falco watches syscalls on every cluster; Falco Talon responds
in app namespaces. Planes and trust in general: [openchoreo.md](openchoreo.md).

## What runs where

| Where | Addon (catalog) | Namespace | What |
|---|---|---|---|
| mgmt | `openchoreo-observability-plane` | openchoreo-observability-plane | OpenChoreo 1.3.3 observability plane (observer, controller-manager, cluster-agent, Gateway `gateway-default` on 11080/11085) + community modules: logs `observability-logs-opensearch` 0.7.0 (OpenSearch 3.3 single node, logs-adapter), traces `observability-tracing-opensearch` 0.8.0 (OTLP receiver collector, tracing-adapter), metrics `observability-metrics-prometheus` 0.8.0 (Prometheus + operator + Alertmanager, metrics-adapter); `ClusterObservabilityPlane default` |
| workload | `telemetry` | telemetry | Fluent Bit (container logs), Prometheus agent + kube-state-metrics (pod metrics), events collector (k8s events), OpenTelemetry Collector DaemonSet (OTLP fan-out) |
| workload (opt-in) | `obi` | obi | OpenTelemetry eBPF Instrumentation v1.0.0: zero-code L7 RED metrics + traces for app namespaces |
| mgmt + workload | `falco` | falco | Falco 0.45 (modern eBPF) + falcosidekick; Falco Talon on workload clusters |
| mgmt | `argo-events` | argo-events | Argo Events 1.9: Falco escalation receiver -> WorkflowTemplate `falco-response`; rollout events -> promotion gate ([promotion.md](promotion.md)) |
| mgmt | `charts/cluster` | – | `ClusterDataPlane.spec.observabilityPlaneRef` -> `ClusterObservabilityPlane default` |

Switch: `openchoreo.observability.enabled` in `installations/<inst>/installation.yaml` (local: true). It drives the
`observabilityPlaneRef` on every ClusterDataPlane and must match `backstage.features.observability.enabled` in the
control-plane addon (validated). With it false, also disable the `openchoreo-observability-plane` and `telemetry`
addons (their validate templates fail otherwise, on purpose).

## Topology and trust

```
workload cluster <name>                                      mgmt (k3d platform-mgmt)
 ns telemetry                                                 ns openchoreo-observability-plane
  Fluent Bit ──── https (TLS passthrough, basic auth) ──┐      Gateway gateway-default (kgateway, LoadBalancer -> klipper)
  events collector ─────────────────────────────────────┤ :11085  └ TLSRoute opensearch ─────────► OpenSearch :9200
  Prometheus agent ── remote write (HTTP) ──────────────┤ :11080  ├ HTTPRoute prometheus-remote-write ► Prometheus :9091
  OTel Collector ──── OTLP/HTTP ────────────────────────┘ :11080  ├ HTTPRoute opentelemetry-collector-otlp ► receiver -> OpenSearch
   ▲ OTLP  ▲ CloudEvents                                          └ HTTPRoute observer ─► observer ◄─ Backstage, openchoreo-api, MCP
  apps/OBI  falcosidekick                                      cluster-agent ── wss in-cluster ──► cluster-gateway (ns openchoreo-control-plane)
```

- **Co-located with the control plane.** The plane's cluster-agent dials the cluster-gateway in-cluster
  (`wss://cluster-gateway.openchoreo-control-plane.svc.cluster.local:8443/ws`; the gateway's server cert carries that
  SAN). Its identity is the chart's self-signed client cert (Secret `cluster-agent-tls`, CN `default`);
  `ClusterObservabilityPlane default` trusts exactly that certificate through a `secretKeyRef` (same cluster, nothing
  copied). The agent verifies the gateway with ConfigMap `cluster-gateway-ca` (public cert only), written by ESO from
  `openchoreo-control-plane/cluster-gateway-ca` key `ca.crt` via ClusterSecretStore `mgmt-openchoreo`. No CA private key
  is copied anywhere.
- **Ingestion from data planes** uses what 1.3.3 ships: OpenSearch's own TLS + basic auth for logs/events; plain HTTP
  through the Gateway for OTLP and remote write (upstream: "TODO: Enable mTLS between collectors"). Locally that is
  acceptable (docker network on one machine); before a real cloud installation put TLS on the Gateway's HTTP listener
  and authenticate ingest (bearer token / mTLS at the Gateway, or an OTel collector with an auth extension in front).
- **One OpenSearch** (single node) holds container logs (`container-logs-*`), k8s events (`k8s-events-*`) and traces
  (`otel-traces-*`); index setup Jobs and retention (7d locally) come from the modules. Prometheus keeps 7d.
- Metric alerts: Prometheus rules (from OpenChoreo's `observability-alert-rule` trait, once added to the platform
  component types) -> Alertmanager -> metrics-adapter -> observer; log alerts via OpenSearch alerting -> observer.

## Endpoints, ports, DNS (local)

k3d publishes, in addition to 8080/8443 (control plane):

```
k3d cluster create platform-mgmt ... -p "11080:11080@loadbalancer" -p "11085:11085@loadbalancer"
```

Nothing else on mgmt may bind hostPort 11080/11085.

| URL | Served by | Used by |
|---|---|---|
| http://observer.openchoreo.localhost:11080 (+ `/mcp`) | observer | Backstage (browser + backend), openchoreo-api, MCP clients; `ClusterObservabilityPlane.spec.observerURL` |
| http://opentelemetry.observability.openchoreo.localhost:11080 | trace receiver (OTLP/HTTP, gRPC by content-type) | data-plane OTel collectors |
| http://prometheus.observability.openchoreo.localhost:11080/api/v1/write | Prometheus remote-write receiver | data-plane Prometheus agents (and the collector's OTLP metrics) |
| opensearch.observability.openchoreo.localhost:11085 | OpenSearch (TLS passthrough, SNI) | Fluent Bit, events collector |

Name resolution (`coredns-local`): on workload clusters the existing rule already sends every `*.openchoreo.localhost`
name to `k3d-platform-mgmt-serverlb` (which now also forwards 11080/11085). On mgmt a second rule, placed first, sends
`observer.openchoreo.localhost` and `*.observability.openchoreo.localhost` to
`gateway-default.openchoreo-observability-plane.svc.cluster.local` (Service port == listener == published port), so pod
and browser URLs are identical. Browsers resolve `*.localhost` to loopback.

The literals in the addon values are checked against `openchoreo.controlPlane.host` and
`openchoreo.observability.{httpPort,tlsPort}` at render time; the data-plane collector derives its endpoints from them
(ConfigMap `telemetry-env`).

## Signals

| Signal | Source on the data plane | Path | Backstage / observer |
|---|---|---|---|
| Container logs | Fluent Bit tail `/var/log/containers` (+ kubernetes filter, `openchoreo_cluster_instance=<cluster>`) | OpenSearch `container-logs-*` | Runtime Logs |
| k8s events | events collector (OpenChoreo build, enriched with owner labels) | OpenSearch `k8s-events-*` | events |
| Pod CPU/memory | Prometheus agent: kubelet/cAdvisor + kube-state-metrics with `openchoreo.dev/*` pod labels | remote write -> Prometheus | Metrics, RuntimeHealthCard |
| Traces | apps (OTLP SDK) / OBI -> OTel Collector (k8s_attributes: all pod labels, cluster name) | OTLP/HTTP -> receiver -> OpenSearch `otel-traces-*` | Traces |
| OTLP metrics | apps / OBI / falcosidekick -> OTel Collector | remote write -> Prometheus | (PromQL) |
| Falco alerts | Falco JSON on stdout -> Fluent Bit; falcosidekick -> collector (CloudEvents) | OpenSearch `container-logs-*` (ns falco); Datadog overlay | logs |

Apps send OTLP to the node-local collector: `OTEL_EXPORTER_OTLP_ENDPOINT=http://telemetry-collector.telemetry.svc.cluster.local:4318`
(Service with `internalTrafficPolicy: Local`), or `http://$(HOST_IP):4318` (hostPort).

## Secrets

| Store / key | Properties | Used by |
|---|---|---|
| `platform` / `openchoreo-observability` (mgmt) | `opensearch-username` (must be `admin`), `opensearch-password` (OpenSearch 3 policy: >= 8 chars, upper, lower, digit, special), `observer-client-secret` (== Thunder client `openchoreo-observer-resource-reader-client`) | OpenSearch admin + setup Jobs + adapters + trace receiver; observer UID resolver |
| `default` / `openchoreo-observability` (workload) | `opensearch-username`, `opensearch-password` | Fluent Bit, events collector |
| `default` / `datadog` (workload, optional) | `api-key` | collector datadog exporter (Secret `telemetry-datadog`, env `DD_API_KEY`) |
| `default` or `platform` / `falco-webhook` | `url`, `token` | falcosidekick escalation webhook; addon argo-events validates `token` |
| `default` or `platform` / `falco-slack` (optional) | `webhook-url` | falcosidekick Slack output |

Known gap: data planes use the OpenSearch admin credentials (upstream recipe). A dedicated ingest-only OpenSearch user
(security plugin `internal_users` + role with `create_index`/`write` on `container-logs-*`, `k8s-events-*`) is the
follow-up before a shared/cloud installation.

## Backstage and MCP

- `openchoreo-control-plane` sets `backstage.features.observability.enabled: true`. Backstage gets the observer URL from
  openchoreo-api (the environment's ClusterDataPlane -> `observabilityPlaneRef` -> `observerURL`); nothing else to wire.
  The observer authorizes calls with the user's Thunder JWT (`security.oidc.*` = control plane's issuer/JWKS) and resolves
  UIDs against openchoreo-api with the client-credentials client `openchoreo-observer-resource-reader-client`
  (role binding `observer-resource-reader-binding` ships in the control-plane chart; the Thunder app is upstream
  `values-thunder.yaml` script 59 and must be added to addon `thunder` with the secret from `observer-client-secret`).
- MCP servers in 1.3.3 (no new exposure needed; both are behind existing routes, OAuth 2.0 protected-resource metadata
  pointing at Thunder):
  - **openchoreo-api MCP** `http://api.openchoreo.localhost:8080/mcp` — toolsets namespace, project, component,
    deployment, build, pe, resource (`openchoreoApi.config.mcp`, default on).
  - **observer MCP** `http://observer.openchoreo.localhost:11080/mcp` — logs, metrics, traces, alerts queries.
  - Agent-side MCP consumers (RCA/SRE agent, FinOps agent, portal assistant) are off: they need an LLM endpoint and
    their own Thunder clients (upstream scripts 53, 56, 57, 60). Interactive MCP clients (Claude Code, Cursor) need the
    upstream "user MCP" Thunder app (script 56); service clients the "service MCP" app (57).

## Datadog

Enable per installation, environment or cluster by renaming `installations/local/addons/telemetry/values.yaml.disabled`
to `values.yaml` (or `env-<env>.yaml` / `cluster-<name>.yaml`) and putting the API key under key `datadog`, property
`api-key`, in the backend behind ClusterSecretStore `default` (never in git). It sets `datadog.enabled: true` (renders
ExternalSecret `telemetry-datadog`) and adds the `datadog` exporter + `datadog/connector` (APM stats) to the collector's
pipelines; OpenChoreo keeps receiving everything. Optional in the same file: `presets.logsCollection` /
`presets.kubeletMetrics` to send container logs and node/pod metrics to Datadog too.

**Recommendation:** start with the collector's Datadog exporter. It reuses the single pipeline (one place for sampling,
redaction, attributes), needs no extra privileged agent, and covers traces, OTLP/OBI metrics and Falco events. Switch to
(or add) the **Datadog Agent** DaemonSet only when Datadog-native features are required (live processes/containers,
NPM, Universal Service Monitoring, Datadog security products, log autodiscovery annotations); then point the collector
at the Agent's OTLP intake instead of the API, and turn OBI off if USM provides RED metrics.

## OBI

Opt-in (`addons: { obi: true }` in a cluster file -> label `addons.platform.koorikla.io/obi: "true"`). Privileged
DaemonSet (eBPF, hostPID, hostNetwork). Instruments processes in OpenChoreo app namespaces (`dp-*`) only, skips processes
that already export OTLP (SDK-instrumented apps) and the collectors themselves; exports traces (OTLP gRPC
`${HOST_IP}:4317`) and RED metrics (OTLP/HTTP `${HOST_IP}:4318`) to the node-local collector, which adds the
OpenChoreo pod labels so spans show up in Backstage's Traces tab.

Overlap policy: when OBI is enabled it is the **single L7 RED source** — keep Cilium Hubble L7 metrics (`hubble.metrics`
http/dns/kafka with L7 visibility) off and use Istio for mTLS, authorization and traffic management, not telemetry
(no Istio telemetry/Prometheus merging needed). Hubble flow logs (L3/L4, Backstage "wirelogs") stay useful.

## Falco

Falco on every cluster, driver `modern_ebpf` (CO-RE, no kernel module, no driver-loader init container; needs kernel
>= 5.8 with BTF). Rules: upstream default `falco_rules.yaml` (installed by falcoctl) + `platform-rules.yaml`:

| Rule | Scope | Priority |
|---|---|---|
| Platform shell in app container | `dp-*` namespaces | WARNING |
| Platform write below etc | all containers except platform namespaces (list `platform_namespaces`) | ERROR |
| Platform crypto miner indicators (miner binaries, `stratum+tcp/ssl` in cmdline, mining-pool ports) | `dp-*` namespaces | CRITICAL |

Alerts are JSON on Falco's stdout (Fluent Bit ships them to OpenSearch, so they sit next to the app logs) and go to
falcosidekick, which fans out to Talon, the telemetry collector (CloudEvents -> logs pipeline; OTLP alert counters ->
metrics pipeline) and, when enabled, the escalation webhook and Slack. falcosidekick UI is off. On mgmt there is no
Talon and no collector; Falco's stdout and the optional outputs remain.

Why Falco and not Tetragon: Falco is detection-first with a large maintained ruleset, plain-YAML rules, and the
sidekick/Talon ecosystem for routing and response; it does not depend on the CNI. Tetragon's strength is in-kernel
enforcement (TracingPolicies that kill/override syscalls) and it fits a Cilium datapath; it is the later opt-in when
enforcement (not just detection + response) is needed.

**Local caveat:** k3d and CAPD nodes are containers on one host kernel, so every cluster's Falco (eBPF is kernel-wide)
sees every container's syscalls on the machine, including other clusters' pods (without k8s metadata). Expect duplicate
and foreign alerts locally; on real nodes each Falco sees only its own node.

## Falco response

**Talon** (workload clusters, `falco-talon` 0.5.0) receives every event from falcosidekick but its rules match only the
platform rule names, which fire only in OpenChoreo app namespaces (`dp-*`), so responses never touch platform workloads.

| Falco rule | Talon actions | Default |
|---|---|---|
| Platform crypto miner indicators | `kubernetes:label` (`platform.koorikla.io/falco=suspicious`) + `kubernetes:terminate` (grace 0, DaemonSets ignored) | enabled |
| Platform shell in app container | `kubernetes:label`; `kubernetes:networkpolicy` isolation commented in the rules | enabled (label only) |

Talon's ServiceAccount is trimmed to pods (get/list/update/patch/delete), pods/eviction, events, networkpolicies, leases.
Dry run per environment: rename `installations/local/addons/falco/env-development.yaml.disabled` to
`env-<env>.yaml` (same rules with `dry_run: true`; it replaces `falco-talon.config.rulesOverride` as a whole).

**Escalation** (on): falcosidekick's webhook output POSTs Critical-and-above events to addon `argo-events` on mgmt
(`escalation.enabled: true`, store key `falco-webhook` with `url`, `token`; locally seeded by `make secrets` with
`url=http://events.openchoreo.localhost:8080/falco` and copied to workload clusters by the cluster seed CRS):

```
data plane falcosidekick ── POST http://events.openchoreo.localhost:8080/falco (Bearer) ──► k3d serverlb :8080
  ─► control-plane Gateway (HTTPRoute falco-escalation, ns argo-events) ─► EventSource platform (webhook, authSecret)
  ─► EventBus (JetStream, 1 node) ─► Sensor falco-escalation (priority ∈ Emergency|Alert|Critical, uuid present)
  ─► Workflow falco-<uuid> from WorkflowTemplate falco-response (Argo Workflows of the workflow plane on mgmt)
       enrich: dp-* namespace + pod -> RenderedRelease (control plane) -> project, component, environment, workload,
               Environment -> data plane (read-only RBAC in the org namespace; no data-plane credentials)
       record: Kubernetes Event (reason FalcoCritical) on the OpenChoreo Component
       rca:    POST sre-agent /api/v1alpha1/rca-agent/analyze      (only with falco.response.rca.enabled)
       notify: POST <falco-notify.url>                             (only with falco.response.notify.enabled)
```

Name resolution needs no new rule: `events.openchoreo.localhost` matches the existing `*.openchoreo.localhost` rewrite
of `coredns-local` (workload: to the serverlb; mgmt: to the control-plane Gateway Service). Containment stays with Talon
on the data plane (label/terminate; NetworkPolicy isolation commented); the mgmt workflow holds no data-plane write
credentials by design. Footprint and knobs: `addons/argo-events/values.yaml` (requests ~184Mi). Contract:

- `POST <url>` (e.g. `https://events.openchoreo.<domain>/falco`), `Content-Type: application/json`,
  header `Authorization: Bearer <token>` (the EventSource validates it; rotate by changing the store key).
- Sent only for `priority >= Critical` (`WEBHOOK_MINIMUMPRIORITY=critical`): Critical, Alert, Emergency.
- Body = the falcosidekick/Falco event, fields consumers may rely on:

  | Field | Example |
  |---|---|
  | `uuid` | `"4e1a...` (dedupe key) |
  | `time` | `"2026-11-14T10:00:00.123456789Z"` |
  | `priority` | `"Critical"` |
  | `rule` | `"Platform crypto miner indicators"` |
  | `output` | human-readable line |
  | `source` | `"syscall"` |
  | `hostname` | node name |
  | `tags` | `["platform","cryptomining","mitre_impact","T1496"]` |
  | `output_fields` | map: `k8s.ns.name`, `k8s.pod.name`, `container.name`, `container.image.repository`, `proc.name`, `proc.cmdline`, `fd.name` |

- Delivery is best effort (sidekick retries are limited); the event also stays in OpenSearch (Falco stdout) and Talon has
  already acted. The receiver must be idempotent on `uuid`. Cluster identity: `hostname` + namespace; add
  `customfields: "cluster:<name>"` once the cluster name is plumbed into the falco addon values.

## Argo CD requirements (catalog)

- `ServerSideApply=true` on `openchoreo-observability-plane` and `telemetry` (prometheus-operator CRDs up to ~860 KB).
- The PVC health override from [openchoreo.md](openchoreo.md) (local-path binds on first consumer: OpenSearch,
  Prometheus, observer alert store).
- ESO on mgmt with generic targets for ConfigMaps (`genericTargets.enabled: true` in addon external-secrets, role mgmt)
  for the agent's `cluster-gateway-ca` ConfigMap.
- Helm hooks: the module setup Jobs run on every sync under Argo (idempotent index/template setup); prometheus-operator
  admission webhooks use cert-manager (no hook Jobs).

## Resource budget (requests, local)

| Where | Components | Memory |
|---|---|---|
| mgmt, obs plane | OpenSearch 1 GiB (heap 512 MiB), Prometheus 384 MiB, observer 128, trace receiver 128, controller 96, agent 64, 3 adapters 144, operator 30, Alertmanager 48, + reloader sidecars and the obs Gateway proxy (~150) | **~2.2 GiB** (limits ~5 GiB) |
| per workload node (DaemonSets) | Fluent Bit 64, OTel Collector 64 | **~130 MiB** |
| per workload cluster (singletons) | Prometheus agent 128 (+ reloader), kube-state-metrics 32, operator 30, events collector 48 | **~290 MiB** (≈ 420 MiB total on a single-node cluster) |
| Falco, per node | Falco 192; per cluster sidekick 32 + Talon 32 | ~190 MiB/node + 64 MiB/cluster |
| OBI, per node (opt-in) | 128 MiB | |

Disk: OpenSearch 8 GiB, Prometheus 8 GiB, observer 128 MiB (local-path). OpenSearch needs `vm.max_map_count >= 262144`
on the host kernel (k3d shares it; Arch/systemd default 1048576).

## Known limitations and VERIFY

`grep -rn VERIFY addons/{openchoreo-observability-plane,telemetry,obi,falco}` lists inferred values. Main ones:
OTLP/HTTP and remote write through the kgateway HTTP listener from CAPD pods via the serverlb; the collector's
`webhookevent` receiver name and the CloudEvents payload shape; OpenSearch TLS verification is off for data-plane
shippers (demo certificate); Talon `dry_run` rule field and `kubernetes:networkpolicy` parameters; Falco's container
plugin enriching k8s fields on k3s/CAPD containerd sockets; Backstage tabs with the observer URL on port 11080.
