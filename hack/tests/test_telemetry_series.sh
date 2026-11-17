#!/usr/bin/env bash
# Telemetry Prometheus agent load (#83): the kubelet /metrics endpoint of k3s also serves its embedded control plane
# (~100k samples per scrape), so the agent does not scrape it at all; dropping the families with metricRelabelings
# still cost the agent fetching, parsing and caching every sample. Renders addon telemetry and checks, with Prometheus
# relabel semantics (fully anchored RE2 match of the joined source labels), that the scrape set is cAdvisor + probes
# and that every series OpenChoreo's metrics adapter (observability-metrics-prometheus 0.8.0) queries is still kept.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
pick_python

echo "== test_telemetry_series =="
out="$TMP/telemetry.yaml"
helm template telemetry addons/telemetry --namespace telemetry --set-string cluster.name=sample > "$out"

# verdicts <rules.json> <samples.txt>: samples are "<want> <__name__>"; prints "<want> <got> <__name__>".
verdicts() {
  py - "$1" "$2" <<'PY'
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
}

# Kubelet ServiceMonitor: /metrics/cadvisor and /metrics/probes only - no path-less (/metrics) endpoint, no
# /metrics/resource (duplicates cAdvisor's container series).
kubelet_sm='select(.kind == "ServiceMonitor" and .metadata.name == "openchoreo-observability-kubelet")'
assert_eq "$(yq ea -r "[$kubelet_sm] | .[0].spec.endpoints | map(.path // \"/metrics\") | join(\",\")" "$out")" \
  "/metrics/cadvisor,/metrics/probes" "kubelet ServiceMonitor: cAdvisor + probes only (no kubelet /metrics)"

# cAdvisor keeps the container series the adapter's CPU/memory queries read; the chart's own drops still apply.
yq -o json -I0 "$kubelet_sm | .spec.endpoints[] | select(.path == \"/metrics/cadvisor\") | .metricRelabelings // []" \
  "$out" > "$TMP/cadvisor-rules.json"
cat > "$TMP/cadvisor-samples.txt" <<'EOF'
keep container_cpu_usage_seconds_total
keep container_memory_working_set_bytes
drop container_cpu_user_seconds_total
drop container_cpu_load_average_10s
EOF
while read -r want got name; do
  assert_eq "$got" "$want" "kubelet /metrics/cadvisor: $name"
done <<<"$(verdicts "$TMP/cadvisor-rules.json" "$TMP/cadvisor-samples.txt")"

# kube-state-metrics: the kube_pod_* families the adapter queries are in its metric allowlist.
ksm_args=$(yq ea -r '[select(.kind == "Deployment" and .metadata.name == "kube-state-metrics")]
  | .[0].spec.template.spec.containers[0].args[]' "$out")
allow=$(printf '%s\n' "$ksm_args" | sed -n 's/^--metric-allowlist=//p')
for m in kube_pod_labels kube_pod_status_phase kube_pod_container_resource_limits kube_pod_container_resource_requests; do
  case ",$allow," in
    *",$m,"*) assert_eq ok ok "kube-state-metrics allowlist: $m" ;;
    *) assert_eq missing ok "kube-state-metrics allowlist: $m" ;;
  esac
done

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
while read -r want got name; do
  assert_eq "$got" "$want" "kgateway-http /metrics: $name"
done <<<"$(verdicts "$TMP/gw-rules.json" "$TMP/gw-samples.txt")"
finish
