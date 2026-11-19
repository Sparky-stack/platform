#!/usr/bin/env bash
# Contract test (#287): Istio ambient kubelet-probe SNAT CIDRs are single-sourced in addons/mesh/values.yaml
# (ambient.probeSourceCIDRs), mirrored in addons/kyverno-policies/values.yaml (mesh.probeSourceCIDRs), and rendered
# into the GeneratingPolicy openchoreo-cell-hbone NetworkPolicy (addons/kyverno-policies/templates/cell-mesh.yaml).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_mesh_probe_cidrs =="

mesh_cidrs=$(yq '.ambient.probeSourceCIDRs[]' "$ROOT/addons/mesh/values.yaml")
policy_cidrs=$(yq '.mesh.probeSourceCIDRs[]' "$ROOT/addons/kyverno-policies/values.yaml")

assert_match "$mesh_cidrs" '.+' "addons/mesh/values.yaml ambient.probeSourceCIDRs is non-empty"
assert_eq "$policy_cidrs" "$mesh_cidrs" \
  "addons/kyverno-policies/values.yaml mesh.probeSourceCIDRs == addons/mesh/values.yaml ambient.probeSourceCIDRs"

helm template kyverno-policies "$ROOT/addons/kyverno-policies" --namespace kyverno \
  -s templates/cell-mesh.yaml > "$TMP/cell-mesh.yaml"
gen_np=$(yq 'select(.metadata.name == "openchoreo-cell-hbone") | .spec.generate[0].template.value' "$TMP/cell-mesh.yaml")
rendered_cidrs=$(printf '%s\n' "$gen_np" | yq '.spec.ingress[].from[]?.ipBlock.cidr | select(. != null)')

assert_eq "$rendered_cidrs" "$mesh_cidrs" \
  "rendered openchoreo-cell-hbone NetworkPolicy ipBlock.cidr list matches ambient.probeSourceCIDRs"
while IFS= read -r cidr; do
  [[ -n "$cidr" ]] || continue
  assert_match "$gen_np" "${cidr//./\.}" "rendered openchoreo-cell-hbone contains probe CIDR $cidr"
done <<<"$mesh_cidrs"

finish
