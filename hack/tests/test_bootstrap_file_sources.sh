#!/usr/bin/env bash
# Bootstrap file sources: every Secret a ClusterClass writes to nodes via KThreesConfig files[].contentFrom (today
# <cluster>-registries: registries.yaml, registry-ca.crt) must be rendered by charts/cluster as an ExternalSecret that
# Argo syncs in an earlier wave than the Cluster. cluster-api-k3s v0.5.0 does not watch those Secrets, so a late one
# stalls the Machine's bootstrap on controller backoff (docs/providers.md "Node registry config"). Checked for every
# installation x cluster file, plus a negative case (wave annotation removed -> must fail).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"

# jsonl <in.yaml> <out.jsonl>: one compact JSON document per line; ClusterClass patch templates also parsed
jsonl() {
  yq -o=json -I=0 'with(select(.kind == "ClusterClass") | .spec.patches[].definitions[].jsonPatches[]
      | select(.valueFrom.template != null); .valueFrom.parsed = (.valueFrom.template | from_yaml))' "$1" > "$2"
}

check() {   # check <label> <fleet-scope.jsonl> <cluster.jsonl> <expect: pass|fail>
  local label=$1 cc=$2 cl=$3 expect=$4 verdict=pass
  capture py "$ROOT/hack/tests/bootstrap_file_sources.py" "$cc" "$cl"
  (( RC == 0 )) || verdict=fail
  assert_eq "$verdict" "$expect" "$label (exit $RC: $OUT)"
}

refs_total=0
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  helm template cluster-fleet charts/cluster --namespace fleet \
    --values "$inst_dir/installation.yaml" --set scope=fleet > "$TMP/cc-$inst.yaml"
  jsonl "$TMP/cc-$inst.yaml" "$TMP/cc-$inst.jsonl"
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    cname=$(yq '.name' "$cf")
    helm template "cluster-$cname" charts/cluster --namespace fleet \
      --values "$inst_dir/installation.yaml" --values "$cf" > "$TMP/cl-$inst-$cname.yaml"
    jsonl "$TMP/cl-$inst-$cname.yaml" "$TMP/cl-$inst-$cname.jsonl"
    check "$inst/$cname: contentFrom Secrets rendered before the Cluster" \
      "$TMP/cc-$inst.jsonl" "$TMP/cl-$inst-$cname.jsonl" pass
    n=$(py "$ROOT/hack/tests/bootstrap_file_sources.py" "$TMP/cc-$inst.jsonl" "$TMP/cl-$inst-$cname.jsonl" 2>/dev/null \
      | sed -n 's/^ *\([0-9][0-9]*\) reference(s) checked.*/\1/p' || true)
    refs_total=$((refs_total + ${n:-0}))
  done
done
# the local installation (Harbor + CA) must actually exercise the check, or it proves nothing
assert_match "$refs_total" '^[1-9][0-9]*$' "contentFrom references checked across installations ($refs_total)"

# negative: the registries ExternalSecret in the Cluster's wave (annotation dropped) must be reported
yq 'del(select(.kind == "ExternalSecret").metadata.annotations["argocd.argoproj.io/sync-wave"])' \
  "$TMP/cl-local-dev1.yaml" > "$TMP/neg-wave.yaml"
jsonl "$TMP/neg-wave.yaml" "$TMP/neg-wave.jsonl"
check "negative: registries ExternalSecret not before the Cluster" "$TMP/cc-local.jsonl" "$TMP/neg-wave.jsonl" fail
# negative: no ExternalSecret for the referenced Secret at all
yq 'select(.kind != "ExternalSecret" or .metadata.name != "dev1-registries")' \
  "$TMP/cl-local-dev1.yaml" > "$TMP/neg-missing.yaml"
jsonl "$TMP/neg-missing.yaml" "$TMP/neg-missing.jsonl"
check "negative: referenced Secret not rendered" "$TMP/cc-local.jsonl" "$TMP/neg-missing.jsonl" fail

finish
