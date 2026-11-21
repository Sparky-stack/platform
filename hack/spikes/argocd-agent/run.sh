#!/usr/bin/env bash
# Spike for #20: argocd-agent managed mode on two throwaway k3d clusters (never the platform clusters).
#   mise exec -- bash hack/spikes/argocd-agent/run.sh up       # clusters, Argo CD 3.6.1 hub+spoke, principal, agent
#   mise exec -- bash hack/spikes/argocd-agent/run.sh addons   # real addon ApplicationSets from charts/platform
#   mise exec -- bash hack/spikes/argocd-agent/run.sh down     # delete both clusters and the network
# Linux/macOS only (argocd-agentctl ships no Windows build). ~2.4 GiB RAM with the addons. Findings: README.md.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=../../lib/portable.sh
. "$ROOT/hack/lib/portable.sh"
ARGOCD=v3.6.1                    # = addons/argo-cd image tag
AGENT=v0.11.0                    # argocd-agent release built against Argo CD v3.6.1 (go.mod)
K3S=docker.io/rancher/k3s:v1.35.10-k3s1@sha256:8262ca99a558dca0c0437443421986480b2359f9118f2371359f88a41514522f
NET=k3d-spike20; HUB=spike-principal; SPOKE=spike-agent; NAME=spike-agent-agent
WORK=${SPIKE_DIR:-${TMPDIR:-/tmp}/argocd-agent-spike}; mkdir -p "$WORK"; umask 077
KC="$WORK/$HUB.kubeconfig:$WORK/$SPOKE.kubeconfig"
h() { KUBECONFIG=$KC kubectl --context "k3d-$HUB" "$@"; }
s() { KUBECONFIG=$KC kubectl --context "k3d-$SPOKE" "$@"; }
ctl() { KUBECONFIG=$KC "$WORK/argocd-agentctl" --principal-context "k3d-$HUB" --principal-namespace argocd "$@"; }
raw() { curl -fsSL "https://raw.githubusercontent.com/$1"; }

agentctl() {
  local arch; arch=$(uname -m); case $arch in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  [ -x "$WORK/argocd-agentctl" ] && return 0
  gh release download "$AGENT" -R argoproj-labs/argocd-agent -D "$WORK" --clobber \
    -p "argocd-agentctl-$(os_name)-$arch" -p "argocd-agentctl_${AGENT#v}_checksums.txt"
  (cd "$WORK" && grep "argocd-agentctl-$(os_name)-$arch\$" "argocd-agentctl_${AGENT#v}_checksums.txt" | shasum -a 256 -c -)
  mv "$WORK/argocd-agentctl-$(os_name)-$arch" "$WORK/argocd-agentctl"; chmod +x "$WORK/argocd-agentctl"
}

cluster() {
  k3d cluster create "$1" --servers 1 --agents 0 --no-lb --network "$NET" --image "$K3S" --wait \
    --k3s-arg '--disable=traefik,servicelb@server:*' --kubeconfig-update-default=false --kubeconfig-switch-context=false
  k3d kubeconfig get "$1" > "$WORK/$1.kubeconfig"
}

up() {
  agentctl; cluster "$HUB"; cluster "$SPOKE"
  local ip; ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "k3d-$HUB-server-0")
  # Hub = full Argo CD (as on mgmt today) + principal alongside ("hybrid architecture" upstream).
  mkdir -p "$WORK/hub" "$WORK/spoke"
  printf 'resources:\n- https://github.com/argoproj/argo-cd/manifests/cluster-install?ref=%s\n' "$ARGOCD" > "$WORK/hub/kustomization.yaml"
  raw "argoproj-labs/argocd-agent/$AGENT/install/kubernetes/argo-cd/agent-managed/kustomization.yaml" \
    | sed "s#ref=stable#ref=$ARGOCD#" > "$WORK/spoke/kustomization.yaml"   # upstream floats on Argo CD "stable"
  h create ns argocd; s create ns argocd
  h apply -n argocd --server-side -k "$WORK/hub"; s apply -n argocd --server-side -k "$WORK/spoke"
  h -n argocd patch cm argocd-cmd-params-cm --type merge \
    -p '{"data":{"application.namespaces":"*","redis.server":"argocd-agent-redis-proxy:6379"}}'
  h apply -n argocd -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/principal?ref=$AGENT"
  h -n argocd patch cm argocd-agent-params --type merge -p '{"data":{"principal.listen.host":"",
    "principal.label-selector":"argocd-agent=true","principal.destination-based-mapping":"true","principal.allowed-namespaces":"*"}}'
  # Argo CD's redis NetworkPolicy must admit the principal, or hub Application status silently stops updating.
  h -n argocd patch netpol argocd-redis-network-policy --type=json -p='[{"op":"add","path":"/spec/ingress/0/from/-",
    "value":{"podSelector":{"matchLabels":{"app.kubernetes.io/name":"argocd-agent-principal"}}}}]'
  # The shipped NetworkPolicy admits agents only from pods of the same cluster: open gRPC for remote agents.
  h -n argocd patch netpol argocd-agent-redis-proxy --type=json \
    -p='[{"op":"add","path":"/spec/ingress/-","value":{"ports":[{"protocol":"TCP","port":8443}]}}]'
  h -n argocd patch svc argocd-agent-principal -p '{"spec":{"type":"NodePort","ports":[{"port":443,"nodePort":30443}]}}'
  ctl pki init   # NON-PROD CA; production: cert-manager Issuer backed by OpenBao PKI (README.md)
  ctl pki issue principal --ip "127.0.0.1,$ip" --dns localhost,argocd-agent-principal.argocd.svc.cluster.local --upsert
  ctl pki issue resource-proxy --ip 127.0.0.1 --dns localhost,argocd-agent-resource-proxy --upsert
  ctl jwt create-key --upsert
  h -n argocd rollout restart deploy argocd-agent-principal argocd-server
  ctl agent create "$NAME" --resource-proxy-server argocd-agent-resource-proxy:9090 --key-algorithm ecdsa-p256
  ctl pki issue agent "$NAME" --agent-context "k3d-$SPOKE" --agent-namespace argocd --upsert
  s apply -n argocd -k "https://github.com/argoproj-labs/argocd-agent/install/kubernetes/agent?ref=$AGENT"
  s -n argocd patch cm argocd-agent-params --type merge -p "{\"data\":{\"agent.server.address\":\"$ip\",
    \"agent.server.port\":\"30443\",\"agent.mode\":\"managed\",\"agent.creds\":\"mtls:any\",\"agent.label-selector\":\"argocd-agent=true\",
    \"agent.destination-based-mapping\":\"true\",\"agent.create-namespace\":\"true\",\"agent.allowed-namespaces\":\"*\"}}"
  s -n argocd rollout restart deploy argocd-agent-agent
  s apply --server-side -f "$ROOT/hack/spikes/argocd-agent/proxy-rbac.yaml"
  s -n argocd wait --for=condition=Ready pod --all --timeout=300s
  until s -n argocd logs deploy/argocd-agent-agent | grep -q "Starting to receive events"; do sleep 5; done
}

# Real catalog ApplicationSets (installations/local), changed only where the agent needs it: destination.name instead
# of destination.server, and the principal's label selector on generated Applications and the AppProject.
APPSETS='addon-gateway-api-crds addon-cert-manager addon-priority-classes addon-reloader addon-keda'
addons() {
  local sel="" a
  for a in $APPSETS; do sel="$sel or .metadata.name==\"$a\""; done
  (cd "$ROOT" && helm template platform charts/platform -f installations/local/installation.yaml) | yq \
    "select((.kind==\"AppProject\" and .metadata.name==\"platform\") or (.kind==\"ApplicationSet\" and (false $sel)))
     | .metadata.labels.argocd-agent=\"true\"
     | (select(.kind==\"ApplicationSet\") | .spec.template.metadata.labels.argocd-agent) = \"true\"
     | (select(.kind==\"ApplicationSet\") | .spec.template.spec.destination) |= {\"name\": \"{{ .name }}\", \"namespace\": .namespace}" \
    > "$WORK/appsets.yaml"
  # dev1-like labels on the agent's cluster secret: the cluster generator selects it like a push-mode cluster secret.
  h -n argocd label secret "cluster-$NAME" --overwrite platform.koorikla.io/name=$SPOKE platform.koorikla.io/role=workload \
    platform.koorikla.io/provider=docker platform.koorikla.io/region=local platform.koorikla.io/environment=development \
    platform.koorikla.io/installation=local platform.koorikla.io/cni=flannel addons.platform.koorikla.io/keda=true
  # Stand-ins for addons left out to save RAM: telemetry (ServiceMonitor CRDs), openchoreo-data-plane (namespace).
  for a in servicemonitors podmonitors; do
    s apply --server-side -f "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.87.0/example/prometheus-operator-crd/monitoring.coreos.com_$a.yaml"
  done
  s create ns openchoreo-data-plane --dry-run=client -o yaml | s apply -f -
  h apply --server-side -f "$WORK/appsets.yaml"
  # Application status is copied from the hub at first: judge convergence by the workloads on the spoke.
  for a in cert-manager reloader keda; do
    until s get deploy -n "$a" -o name 2>/dev/null | grep -q .; do sleep 10; done
    s wait -n "$a" --for=condition=Available deploy --all --timeout=900s
  done
  h -n argocd get applications
}

down() { k3d cluster delete "$HUB" "$SPOKE"; docker network rm "$NET" >/dev/null 2>&1 || true; }

case "${1:-}" in
  up|addons|down) "$1" ;;
  *) echo "usage: $0 up|addons|down" >&2; exit 2 ;;
esac
