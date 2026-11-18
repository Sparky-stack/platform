#!/usr/bin/env bash
# Sync-wave order of every cluster app (charts/cluster, #192): a resource that waits on another object of the same app
# (Certificate -> Issuer, Issuer -> CA Secret, ExternalSecret -> Secret, ClusterResourceSet -> payload + Cluster, and
# CAPI's <name>-kubeconfig / <name>-cca for the Cluster) must come in a later wave, or one failed apply (CAPI webhook
# down) hangs the Argo CD operation forever; a ClusterResourceSet for the peers belongs in the final wave.
# Model: hack/tests/cluster_sync_order.py. Checked for every installation x cluster file (disabled ones too), plus the
# #192 layout (no waves) as a negative case.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"
echo "== test_cluster_sync_order =="
pick_python || { echo "  SKIP: python3 not found"; exit 0; }
cd "$ROOT"

jsonl() { yq -o=json -I=0 'select(. != null)' "$1" > "$2"; }
model() { py hack/tests/cluster_sync_order.py "$1"; }

n=0
for cf in installations/*/clusters/*.yaml installations/*/clusters/*.yaml.disabled; do
  [[ -f "$cf" ]] || continue
  inst=$(basename "$(dirname "$(dirname "$cf")")")
  cname=$(yq '.name' "$cf")
  helm template "cluster-$cname" charts/cluster --namespace fleet --values "installations/$inst/installation.yaml" \
    --values "$cf" > "$TMP/c.yaml"
  jsonl "$TMP/c.yaml" "$TMP/c.jsonl"
  res=$(model "$TMP/c.jsonl" 2>&1) || true
  assert_match "$res" '^ok [0-9]+ edges$' "$inst/$(basename "$cf"): every consumer syncs after its producer"
  n=$((n + 1))
done
assert_match "$n" '^[1-9][0-9]*$' "cluster files found"

# local dev1 is a mesh member with an OpenChoreo data plane: both chains are present and modelled
helm template cluster-dev1 charts/cluster --namespace fleet --values installations/local/installation.yaml \
  --values installations/local/clusters/dev1.yaml > "$TMP/dev1.yaml"
jsonl "$TMP/dev1.yaml" "$TMP/dev1.jsonl"
assert_eq "$(model "$TMP/dev1.jsonl")" "ok 22 edges" "dev1: mesh-reader, agent PKI, kubeconfig and ClusterResourceSet edges modelled"

# Negative: the #192 layout (everything but the registries in wave 0) is caught where it hung live
yq 'del(select(.kind != "ExternalSecret" or .metadata.name != "dev1-registries") | .metadata.annotations["argocd.argoproj.io/sync-wave"])' \
  "$TMP/dev1.yaml" > "$TMP/pr192.yaml"
jsonl "$TMP/pr192.yaml" "$TMP/pr192.jsonl"
res=$(model "$TMP/pr192.jsonl" 2>&1) || true
assert_match "$res" 'FAIL Issuer/dev1-client-ca \(wave 0\) consumes Cluster/dev1 \(wave 0\)' \
  "negative: Issuer dev1-client-ca in the Cluster's wave is caught"
assert_match "$res" 'FAIL Certificate/dev1-mesh-reader \(wave 0\) consumes Issuer/dev1-client-ca \(wave 0\)' \
  "negative: Certificate dev1-mesh-reader in its Issuer's wave is caught"
assert_match "$res" 'FAIL ExternalSecret/dev1-argocd-cluster \(wave 0\) consumes Cluster/dev1' \
  "negative: a kubeconfig consumer in the Cluster's wave is caught"
# Negative: the layout of #195 (live: cluster-dev1 hung in wave 0) - the remote-secret CRS, which matches only peers
# (none on the lean local profile), outside the final wave, and the agent CRS before its payload ExternalSecret
yq '(select(.kind == "ClusterResourceSet") | .metadata.annotations["argocd.argoproj.io/sync-wave"]) = "0"' \
  "$TMP/dev1.yaml" > "$TMP/pr195.yaml"
jsonl "$TMP/pr195.yaml" "$TMP/pr195.jsonl"
res=$(model "$TMP/pr195.jsonl" 2>&1) || true
assert_match "$res" 'FAIL ClusterResourceSet/dev1-mesh-remote-secret \(wave 0\) selects other clusters than this one: must be in the final wave' \
  "negative: a peers-only ClusterResourceSet outside the final wave is caught"
assert_match "$res" 'FAIL ClusterResourceSet/dev1-openchoreo-agent \(wave 0\) consumes ExternalSecret/dev1-openchoreo-agent \(wave 4\)' \
  "negative: a ClusterResourceSet before its payload ExternalSecret is caught"
assert_match "$res" 'FAIL ClusterResourceSet/dev1-mesh-trust \(wave 0\) consumes Cluster/dev1 \(wave 0\)' \
  "negative: a ClusterResourceSet in its Cluster's wave is caught"
# Negative: one step too early (Certificate back in its Issuer's wave)
yq '(select(.kind == "Certificate" and .metadata.name == "dev1-agent-tls") | .metadata.annotations["argocd.argoproj.io/sync-wave"]) = "2"' \
  "$TMP/dev1.yaml" > "$TMP/same.yaml"
jsonl "$TMP/same.yaml" "$TMP/same.jsonl"
res=$(model "$TMP/same.jsonl" 2>&1) || true
assert_match "$res" 'FAIL Certificate/dev1-agent-tls \(wave 2\) consumes Issuer/dev1-agent-ca \(wave 2\)' \
  "negative: Certificate dev1-agent-tls in its Issuer's wave is caught"

finish
