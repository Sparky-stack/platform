#!/usr/bin/env bash
# Environment placement over the fleet files (#115, docs/dev-environment.md "Local profiles"), for every installation in
# its default profile (clusters/*.yaml) and, where it has disabled fleet files, in its multicluster profile (every
# clusters/*.yaml.disabled enabled and its environments taken off the other files: the documented switch):
#   1. every environment is placed on exactly one enabled data plane, and every environment the platform needs
#      (addon openchoreo-platform deploymentPipeline, promotion.gatedEnvironments, promotion.freezeWindows) is placed
#   2. charts/cluster renders each Environment exactly once across the profile, bound to its cluster's ClusterDataPlane;
#      a disabled fleet file renders a complete cluster once enabled
#   3. the production policy follows the environment, not the cluster: addon kyverno-policies renders the same policies
#      on every workload cluster whatever its name or cluster-level `environment`, and the cluster that hosts production
#      gets the Deny pair scoped to cell namespaces labelled openchoreo.dev/environment=production
#   4. the cross-cluster example (examples.eastwest) is enabled only with two or more mesh members, and the multicluster
#      profile has them (its switch may turn the example on)
# Negative cases: a duplicated or missing placement, an Audit-only production and the example on a lone member fail.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

echo "== test_local_profiles =="

# placement <fleet file>... -> "<environment> <cluster>" per environment of every enabled data plane
placement() {
  local cf
  for cf in "$@"; do
    # shellcheck disable=SC2016  # yq variables, not shell
    yq -r 'select(.openchoreo.dataPlane.enabled == true) | .name as $n | (.openchoreo.dataPlane.environments // [])[] | . + " " + $n' "$cf" | tr -d '\r'
  done
}

# required_envs <inst dir> -> environments the platform references (one per line, sorted)
required_envs() {
  local inst_dir=$1 ov="$1/addons/openchoreo-platform/values.yaml" pipe
  pipe=$(yq -r '.deploymentPipeline.environments // [] | .[]' addons/openchoreo-platform/values.yaml)
  if [[ -f "$ov" ]] && [[ "$(yq -r '.deploymentPipeline.environments // "" | tag' "$ov")" == '!!seq' ]]; then
    pipe=$(yq -r '.deploymentPipeline.environments[]' "$ov")
  fi
  { printf '%s\n' "$pipe"
    yq -r '(.promotion.gatedEnvironments // [])[], ((.promotion.freezeWindows // [])[].environments // [])[]' "$inst_dir/installation.yaml"
  } | tr -d '\r' | grep . | LC_ALL=C sort -u
}

# placement_errors <inst dir> <fleet file>... -> one line per violation of check 1 (empty: ok)
placement_errors() {
  local inst_dir=$1 p e n; shift
  p=$(placement "$@")
  while read -r e n; do
    [[ -n "$e" ]] && echo "environment $e is on $n enabled clusters: $(printf '%s\n' "$p" | awk -v e="$e" '$1 == e { print $2 }' | paste -sd, -)"
  done < <(printf '%s\n' "$p" | awk 'NF { print $1 }' | LC_ALL=C sort | uniq -c | awk '$1 > 1 { print $2, $1 }')
  while read -r e; do
    [[ -n "$e" ]] || continue
    printf '%s\n' "$p" | awk -v e="$e" '$1 == e { f = 1 } END { exit !f }' || echo "environment $e is on no enabled cluster"
  done < <(required_envs "$inst_dir")
}

# multicluster_profile <inst dir> <out dir> -> fleet files of the multicluster profile in <out dir> (none: no switch)
multicluster_profile() {
  local inst_dir=$1 out=$2 d cf moved
  mkdir -p "$out"
  for cf in "$inst_dir"/clusters/*.yaml; do [[ -f "$cf" ]] && cp "$cf" "$out/"; done
  for d in "$inst_dir"/clusters/*.yaml.disabled; do
    [[ -f "$d" ]] || continue
    moved=$(yq -o=json -I=0 '.openchoreo.dataPlane.environments // []' "$d" | tr -d '\r')
    for cf in "$out"/*.yaml; do
      M="$moved" yq -i '.openchoreo.dataPlane.environments |= ((. // []) - (strenv(M) | from_json))' "$cf"
    done
    d=$(basename "$d"); cp "$inst_dir/clusters/$d" "$out/${d%.disabled}"
  done
}

# deny_errors <kyverno-policies render> -> violations of the production Deny policies (empty: ok)
deny_errors() {
  local r=$1 k n sel
  # signature + one policy per required attestation (#136: separate policies run in parallel) + trusted registries
  for k in ImageValidatingPolicy/openchoreo-verify-images-enforce ImageValidatingPolicy/openchoreo-attest-sbom-enforce \
    ImageValidatingPolicy/openchoreo-attest-provenance-enforce ImageValidatingPolicy/openchoreo-attest-vuln-enforce \
    ValidatingPolicy/openchoreo-trusted-registries-enforce; do
    n=$(K="${k%/*}" N="${k#*/}" yq -r 'select(.kind == strenv(K) and .metadata.name == strenv(N)) | .spec.validationActions | join(",")' "$r")
    [[ "$n" == Deny ]] || { echo "$k: validationActions '${n:-missing}', want Deny"; continue; }
    sel=$(K="${k%/*}" N="${k#*/}" yq -o=json -I=0 'select(.kind == strenv(K) and .metadata.name == strenv(N)) | .spec.matchConstraints.namespaceSelector.matchExpressions[] | select(.key == "openchoreo.dev/environment" and .operator == "In") | .values' "$r")
    [[ "$sel" == *'"production"'* ]] || echo "$k: not scoped to namespaces labelled openchoreo.dev/environment=production"
  done
}

# eastwest_errors <enabled true|false> <fleet file>... -> violation of check 4 (empty: ok)
eastwest_errors() {
  local on=$1 cf n=0; shift
  [[ "$on" == true ]] || return 0
  for cf in "$@"; do [[ -n "$(yq -r '.mesh.group // ""' "$cf")" ]] && n=$((n + 1)); done
  (( n >= 2 )) || echo "examples.eastwest is enabled with $n mesh member(s); it needs two (echo and callers on different clusters)"
}

# kyverno_render <inst> <inst dir> <platform render> <fleet file> [helm args...] -> addon kyverno-policies as Argo renders it there
kyverno_render() {
  local inst=$1 inst_dir=$2 prender=$3 cf=$4 n args=(); shift 4
  n=$(yq -r '.name' "$cf")
  if (( $# == 0 )) && [[ "$cf" == "$inst_dir/clusters/$n.yaml" ]]; then
    render_layered_addon "$inst" kyverno-policies "$TMP/kp-raw-$inst-$n.yaml" "$prender" workload "$n" \
      "$(yq -r '.provider // "docker"' "$cf")" "$(yq -r '.environment // "development"' "$cf")" \
      "$(yq -r '.region // "local"' "$cf")" "$(yq -r '.cni // "cilium"' "$cf")" https://192.0.2.10:6443
    yq 'select(.kind == "ImageValidatingPolicy" or .kind == "ValidatingPolicy" or .kind == "MutatingPolicy")' "$TMP/kp-raw-$inst-$n.yaml"
    return
  fi
  read_lines args addon_helm_args kyverno-policies "$inst_dir" "$prender" workload "$n" \
    "$(yq -r '.provider // "docker"' "$cf")" "$(yq -r '.environment // "development"' "$cf")" \
    "$(yq -r '.region // "local"' "$cf")" "$(yq -r '.cni // "cilium"' "$cf")" https://192.0.2.10:6443
  helm template kyverno-policies addons/kyverno-policies --namespace kyverno "${args[@]}" "$@" \
    | yq 'select(.kind == "ImageValidatingPolicy" or .kind == "ValidatingPolicy" or .kind == "MutatingPolicy")'
}

profiles=0
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  prender="$TMP/platform-$inst.yaml"
  render_platform "$inst" "$prender"
  multi="$TMP/$inst-multicluster"
  multicluster_profile "$inst_dir" "$multi"
  for profile in default multicluster; do
    files=()
    if [[ "$profile" == default ]]; then
      for cf in "$inst_dir"/clusters/*.yaml; do [[ -f "$cf" ]] && files+=("$cf"); done
    else
      ls "$inst_dir"/clusters/*.yaml.disabled >/dev/null 2>&1 || continue
      for cf in "$multi"/*.yaml; do [[ -f "$cf" ]] && files+=("$cf"); done
    fi
    profiles=$((profiles + 1))
    tag="$inst/$profile"

    # 1. placement
    assert_eq "$(placement_errors "$inst_dir" "${files[@]}")" "" "$tag: every environment on exactly one enabled cluster"

    # 4. cross-cluster example
    ew=$(yq -r '.examples.eastwest.enabled // false' "$inst_dir/installation.yaml")
    assert_eq "$(eastwest_errors "$ew" "${files[@]}")" "" "$tag: examples.eastwest only with two mesh members (enabled: $ew)"
    if [[ "$profile" == multicluster ]]; then
      assert_eq "$(eastwest_errors true "${files[@]}")" "" "$tag: the multicluster profile can run examples.eastwest"
    fi

    # 2. rendered Environments
    envs=""
    for cf in "${files[@]}"; do
      n=$(yq -r '.name' "$cf")
      out="$TMP/$inst-$profile-$n.yaml"
      if [[ "$profile" == default ]]; then
        render_cluster "$inst" "$n" "$out"
        assert_eq "$(N="$n" yq -r 'select(.kind == "Cluster" and .metadata.name == strenv(N)) | .metadata.name' "$out")" "$n" "$tag: $n renders its CAPI Cluster"
      elif helm template "cluster-$n" charts/cluster --namespace fleet --values "$inst_dir/installation.yaml" --values "$cf" > "$out" 2> "$out.err"; then
        assert_eq "$(N="$n" yq -r 'select(.kind == "Cluster" and .metadata.name == strenv(N)) | .metadata.name' "$out")" "$n" "$tag: $n renders its CAPI Cluster"
      else
        assert_eq "$(cat "$out.err")" "" "$tag: charts/cluster renders $n"
        continue
      fi
      envs="$envs$(yq -r 'select(.kind == "Environment") | .metadata.name + " " + .spec.dataPlaneRef.name' "$out")"$'\n'
    done
    assert_eq "$(printf '%s' "$envs" | grep -v '^---$' | grep . | LC_ALL=C sort)" "$(placement "${files[@]}" | LC_ALL=C sort)" \
      "$tag: one Environment per placed environment, bound to its cluster's ClusterDataPlane"

    # 3. production policy follows the environment
    prod_cluster=$(placement "${files[@]}" | awk '$1 == "production" { print $2 }')
    [[ -n "$prod_cluster" ]] || continue
    ref=""; ref_name=""
    for cf in "${files[@]}"; do
      n=$(yq -r '.name' "$cf")
      kr="$TMP/$inst-$profile-$n-kyverno.yaml"
      kyverno_render "$inst" "$inst_dir" "$prender" "$cf" > "$kr"
      if [[ -z "$ref" ]]; then
        ref=$kr; ref_name=$n
      else
        assert_eq "$(cmp -s "$ref" "$kr" && echo same || echo differs)" same "$tag: kyverno-policies on $n == on $ref_name (policy by namespace environment, not by cluster)"
      fi
      if [[ "$n" == "$prod_cluster" ]]; then
        assert_eq "$(deny_errors "$kr")" "" "$tag: production Deny policies active on $n (hosts production)"
        # cluster-level facts do not move the gate: the same render with another name / cluster environment
        kyverno_render "$inst" "$inst_dir" "$prender" "$cf" --set-string cluster.name=elsewhere,cluster.environment=development > "$kr.other"
        assert_eq "$(cmp -s "$kr" "$kr.other" && echo same || echo differs)" same "$tag: Deny policies independent of cluster name and cluster environment"
      fi
    done
  done
done
assert_eq "$((profiles >= 4))" 1 "default profiles of every installation and local's multicluster profile were checked ($profiles)"
ndis=0; for d in installations/local/clusters/*.yaml.disabled; do [[ -f "$d" ]] && ndis=$((ndis + 1)); done
assert_eq "$ndis" 1 "local keeps exactly one disabled fleet file (the multicluster switch)"

# --- negatives ---------------------------------------------------------------------------------------------------
L=installations/local
neg="$TMP/neg"; mkdir -p "$neg"
cp "$L"/clusters/*.yaml "$neg/"
for d in "$L"/clusters/*.yaml.disabled; do b=$(basename "$d"); cp "$d" "$neg/${b%.disabled}"; done   # enabled, not moved
assert_match "$(placement_errors "$L" "$neg"/*.yaml)" 'environment production is on 2 enabled clusters' "neg: half switch (prod1 enabled, production left on dev1) fails"
yq -i '.openchoreo.dataPlane.environments = ["development", "staging"]' "$neg/dev1.yaml"; rm -f "$neg/prod1.yaml"
assert_match "$(placement_errors "$L" "$neg"/*.yaml)" 'environment production is on no enabled cluster' "neg: production placed nowhere fails"
kyverno_render local "$L" "$TMP/platform-local.yaml" "$L/clusters/dev1.yaml" --set imageVerification.environments.production=Audit > "$TMP/kyverno-audit.yaml"
assert_match "$(deny_errors "$TMP/kyverno-audit.yaml")" 'openchoreo-verify-images-enforce: validationActions' "neg: production Audit-only fails the Deny check"
assert_match "$(eastwest_errors true "$L"/clusters/*.yaml)" 'with 1 mesh member' "neg: examples.eastwest on the lean profile (one member) fails"
finish
