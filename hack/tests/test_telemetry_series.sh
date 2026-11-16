#!/usr/bin/env bash
# Telemetry Prometheus agent load (#83): the kubelet /metrics endpoint of k3s also serves its embedded control plane,
# ~90% of the agent's active series. Renders addon telemetry and applies the kubelet ServiceMonitor's metricRelabelings
# to sample metric names with Prometheus semantics (drop on a fully anchored RE2 match of the joined source labels):
# the control-plane families go, everything OpenChoreo or the kubelet itself needs stays.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
pick_python

echo "== test_telemetry_series =="
out="$TMP/telemetry.yaml"
helm template telemetry addons/telemetry --namespace telemetry --set-string cluster.name=sample > "$out"
yq -o json -I0 'select(.kind == "ServiceMonitor" and .metadata.name == "openchoreo-observability-kubelet")
  | .spec.endpoints[] | select(.path == null) | .metricRelabelings // []' "$out" > "$TMP/rules.json"

# Sample samples as "<__name__>;<le>"; verdict "drop" or "keep".
cat > "$TMP/samples.txt" <<'EOF'
drop apiserver_request_duration_seconds_bucket;0.1
drop apiserver_request_total;
drop etcd_request_duration_seconds_bucket;0.005
drop workqueue_queue_duration_seconds_bucket;1
drop scheduler_plugin_execution_duration_seconds_bucket;0.01
drop aggregator_unavailable_apiservice;
drop apiextensions_openapi_v2_regeneration_count;
drop authentication_attempts;
drop authorization_attempts_total;
drop kube_apiserver_pod_logs_backend_tls_failure_total;
drop field_validation_request_duration_seconds_bucket;0.5
drop watch_cache_capacity;
drop storage_operation_duration_seconds_bucket;2.5
keep storage_operation_duration_seconds_bucket;1
keep kubelet_running_pods;
keep kubelet_volume_stats_used_bytes;
keep kubelet_runtime_operations_duration_seconds_bucket;0.1
keep prober_probe_total;
keep volume_operation_total_seconds_bucket;1
keep process_resident_memory_bytes;
keep go_goroutines;
keep rest_client_requests_total;
keep container_cpu_usage_seconds_total;
keep kubernetes_build_info;
EOF

verdicts=$(py - "$TMP/rules.json" "$TMP/samples.txt" <<'PY'
import json, re, sys
rules = json.load(open(sys.argv[1]))
for line in open(sys.argv[2]):
    want, sample = line.split()
    name, le = sample.split(";")
    labels = {"__name__": name, "le": le}
    verdict = "keep"
    for r in rules:
        value = r.get("separator", ";").join(labels.get(l, "") for l in r["sourceLabels"])
        if r.get("action", "replace") == "drop" and re.fullmatch(r["regex"], value):
            verdict = "drop"
            break
    print("%s %s %s" % (want, verdict, name))
PY
)
assert_eq "$(yq -r 'length' "$TMP/rules.json")" 2 "kubelet /metrics: two drop rules (chart bucket drop + control plane)"
while read -r want got name; do
  assert_eq "$got" "$want" "kubelet /metrics: $name"
done <<<"$verdicts"

# Data-plane kgateway Envoy (#104): PodMonitor kgateway-http keeps only envoy_cluster_upstream_rq (not _total/_xx/_time).
yq -o json -I0 'select(.kind == "PodMonitor" and .metadata.name == "kgateway-http")
  | .spec.podMetricsEndpoints[0].metricRelabelings // []' "$out" > "$TMP/gw-rules.json"
[[ -s "$TMP/gw-rules.json" ]] || echo '[]' > "$TMP/gw-rules.json"
assert_eq "$(yq -r 'length' "$TMP/gw-rules.json")" 1 "kgateway-http: one keep rule"
cat > "$TMP/gw-samples.txt" <<'EOF'
keep envoy_cluster_upstream_rq
drop envoy_cluster_upstream_rq_total
drop envoy_cluster_upstream_rq_xx
drop envoy_cluster_upstream_rq_time_bucket
drop envoy_cluster_upstream_rq_completed
drop envoy_http_downstream_rq_total
EOF
gw_verdicts=$(py - "$TMP/gw-rules.json" "$TMP/gw-samples.txt" <<'PY'
import json, re, sys
rules = json.load(open(sys.argv[1]))
for line in open(sys.argv[2]):
    want, name = line.split()
    labels = {"__name__": name}
    verdict = "keep"
    for r in rules:
        value = r.get("separator", ";").join(labels.get(l, "") for l in r["sourceLabels"])
        act = r.get("action", "replace")
        if act == "drop" and re.fullmatch(r["regex"], value):
            verdict = "drop"
            break
        if act == "keep" and not re.fullmatch(r["regex"], value):
            verdict = "drop"
            break
    print("%s %s %s" % (want, verdict, name))
PY
)
while read -r want got name; do
  assert_eq "$got" "$want" "kgateway-http /metrics: $name"
done <<<"$gw_verdicts"
finish
