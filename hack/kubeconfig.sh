#!/usr/bin/env bash
# Write a host-usable kubeconfig for a CAPD workload cluster of the local installation.
# Usage: hack/kubeconfig.sh <cluster> [out-file]          (task kubeconfig CLUSTER=dev1)
#
# CAPD records the API endpoint as the <cluster>-lb container IP on docker network `kind` (docs/providers.md). The
# native Linux host routes to that IP; Docker Desktop (macOS, Windows), Colima, OrbStack and WSL2-with-Docker-Desktop
# hosts do not. There the server is rewritten to the port the LB publishes on the host (127.0.0.1:<port>, a k3s
# certificate SAN). Force a mode with KUBECONFIG_MODE=direct|published. Read-only against the mgmt cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

CLUSTER="${1:-${CLUSTER:-}}"
[[ -n "$CLUSTER" ]] || { echo "usage: $0 <cluster> [out-file]" >&2; exit 2; }
OUT="${2:-$CLUSTER.kubeconfig}"   # *.kubeconfig is gitignored
CTX="${KUBE_CTX:-k3d-platform-mgmt}"

kubectl --context "$CTX" -n fleet get secret "$CLUSTER-kubeconfig" -o jsonpath='{.data.value}' | b64dec > "$OUT"
chmod 600 "$OUT"

server=$(yq '.clusters[0].cluster.server' "$OUT")
host=${server#https://}; host=${host%:*}

mode="${KUBECONFIG_MODE:-}"
if [[ -z "$mode" ]]; then
  # Probe the recorded endpoint (2s budget, no `timeout` on macOS): reachable -> keep it.
  if curl -sk --connect-timeout 2 -o /dev/null "https://$host:6443/version"; then mode=direct; else mode=published; fi
fi

if [[ "$mode" == published ]]; then
  port=$(docker port "$CLUSTER-lb" 6443/tcp | head -n1 | sed 's/.*://')
  [[ -n "$port" ]] || { echo "container $CLUSTER-lb publishes no 6443/tcp port" >&2; exit 1; }
  SERVER="https://127.0.0.1:$port" yq -i '.clusters[0].cluster.server = strenv(SERVER)' "$OUT"
  server="https://127.0.0.1:$port"
fi
echo "Wrote $OUT (server $server, mode $mode)"
echo "  kubectl --kubeconfig $OUT get nodes"
