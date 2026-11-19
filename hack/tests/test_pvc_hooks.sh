#!/usr/bin/env bash
# A PersistentVolumeClaim that Argo CD runs as a hook is deleted by Argo CD itself: Argo maps every helm.sh/hook to a
# sync hook (argocd.argoproj.io/hook can only re-type it, or Skip it = never applied) and knows three hook delete
# policies - HookSucceeded, HookFailed, BeforeHookCreation, the default when none is set. Addon thunder's upstream chart
# hardcodes its PVCs as hooks; with hook-failed they survive successful syncs, but a failed sync deleted them (the
# thunder-setup outage). Contract, for every addon render of every installation (hack/test.sh RENDERED_DIR) and the
# standalone renders made here: a hook PVC
#   1. has exactly the delete policy hook-failed (none = deleted before EVERY sync, hook-succeeded = after every
#      successful one),
#   2. carries platform.koorikla.io/delete-protection: enabled, and
#   3. its render contains a ValidatingAdmissionPolicy (+ Deny binding) that denies DELETE of such PVCs in its
#      namespace and outlives a failed sync: a PreSync hook with before-hook-creation only, or a normal resource.
# Non-hook PVCs are normal Argo resources (deleted only when removed from git) and out of scope.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"

# violations <render> -> one line per broken rule, empty when the render keeps the contract
violations() {
  local f=$1 key pol prot ns vap
  grep -q 'PersistentVolumeClaim' "$f" || return 0
  # \x1f (unit separator), not tab: tab is IFS whitespace, so an empty policy field would collapse into the next one.
  # shellcheck disable=SC2016  # yq variables ($a, $p, ...), not shell
  while IFS=$'\x1f' read -r key pol prot; do
    [[ -n "$key" ]] || continue
    ns=${key%%/*}
    if [[ "$pol" != "HookFailed" ]]; then
      echo "$key: Argo CD hook with delete policy '${pol:-<none> = BeforeHookCreation}', want exactly hook-failed"
    fi
    if [[ "$prot" != "enabled" ]]; then
      echo "$key: hook PVC without annotation platform.koorikla.io/delete-protection: enabled"
    fi
    # shellcheck disable=SC2016  # yq variables, not shell
    vap=$(NS="$ns" yq -N '
      select(.kind == "ValidatingAdmissionPolicy")
      | select([.spec.matchConstraints.resourceRules[]? | select(([.operations[]] | any_c(. == "DELETE" or . == "*")) and ([.resources[]] | any_c(. == "persistentvolumeclaims" or . == "*")))] | length > 0)
      | select((.spec.matchConstraints.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] // strenv(NS)) == strenv(NS))
      | select([.spec.matchConditions[]?.expression] | join(" ") | test("platform.koorikla.io/delete-protection"))
      | select(((.metadata.annotations["helm.sh/hook"] // "") == "" and (.metadata.annotations["argocd.argoproj.io/hook"] // "") == "")
               or (.metadata.annotations["helm.sh/hook-delete-policy"] // "") == "before-hook-creation"
               or (.metadata.annotations["argocd.argoproj.io/hook-delete-policy"] // "") == "BeforeHookCreation")
      | .metadata.name' "$f" | tr -d '\r' | head -1)
    if [[ -z "$vap" ]]; then
      echo "$key: no ValidatingAdmissionPolicy in the render denies its deletion (DELETE persistentvolumeclaims, namespace $ns, delete-protection matchCondition, surviving a failed sync)"
    elif [[ -z "$(P="$vap" yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == strenv(P) and ([.spec.validationActions[]] | any_c(. == "Deny"))) | .metadata.name' "$f" | tr -d '\r')" ]]; then
      echo "$key: ValidatingAdmissionPolicy $vap has no Deny binding"
    fi
  done < <(SEP=$'\x1f' yq -N '
    select(.kind == "PersistentVolumeClaim")
    | (.metadata.annotations // {}) as $a
    | ($a["argocd.argoproj.io/hook"] // "") as $ah | ($a["helm.sh/hook"] // "") as $hh
    | select(($ah != "" and $ah != "Skip") or ($ah == "" and $hh != "" and $hh != "crd-install"))
    | ([($a["argocd.argoproj.io/hook-delete-policy"] // "") | split(",") | .[] | select(. != "")]
       + [($a["helm.sh/hook-delete-policy"] // "") | split(",") | .[] | select(. != "")
          | sub("^hook-succeeded$"; "HookSucceeded") | sub("^hook-failed$"; "HookFailed") | sub("^before-hook-creation$"; "BeforeHookCreation")]) as $p
    | (.metadata.namespace // "") + "/" + .metadata.name + strenv(SEP) + ($p | unique | join(",")) + strenv(SEP)
      + ($a["platform.koorikla.io/delete-protection"] // "")
  ' "$f" | tr -d '\r')
}

# 1. Every addon render: hack/test.sh's per-installation renders, else standalone renders made here.
n=0
if [[ -n "${RENDERED_DIR:-}" && -d "${RENDERED_DIR:-}" ]]; then
  for r in "$RENDERED_DIR"/addon-*.yaml; do
    [[ -f "$r" ]] || continue
    n=$((n + 1))
    assert_eq "$(violations "$r")" "" "$(basename "$r" .yaml): hook PVCs are hook-failed, annotated and delete-protected"
  done
else
  echo "  (no RENDERED_DIR: standalone render of addon thunder only)"
fi
render_standalone_addon thunder "$TMP/thunder.yaml"
assert_eq "$(violations "$TMP/thunder.yaml")" "" "addons/thunder (standalone): hook PVCs are hook-failed, annotated and delete-protected"
assert_eq "$(yq -N 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$TMP/thunder.yaml" | tr -d '\r' | sort | tr '\n' ' ')" \
  "thunder-certs-pvc thunder-database-pvc thunder-secrets-pvc " "addon thunder still renders its three PVCs (the contract is not vacuous)"
echo "  checked $n addon renders from hack/test.sh"

# 2. Negative: each way back to the outage is caught.
neg() { # neg <label> <yq edit of the thunder render> <expected violation regex>
  yq "$2" "$TMP/thunder.yaml" > "$TMP/neg.yaml"   # no -N: keep the document separators
  assert_match "$(violations "$TMP/neg.yaml")" "$3" "negative: $1"
}
# shellcheck disable=SC2016
neg "no delete policy (Argo default BeforeHookCreation)" \
  '(select(.kind == "PersistentVolumeClaim" and .metadata.name == "thunder-database-pvc") | .metadata.annotations) |= del(.["helm.sh/hook-delete-policy"])' \
  'thunder/thunder-database-pvc: Argo CD hook with delete policy .<none> = BeforeHookCreation'
neg "hook-succeeded" \
  '(select(.kind == "PersistentVolumeClaim" and .metadata.name == "thunder-certs-pvc") | .metadata.annotations["helm.sh/hook-delete-policy"]) = "hook-succeeded"' \
  "thunder/thunder-certs-pvc: Argo CD hook with delete policy 'HookSucceeded'"
neg "argocd hook re-typed without a policy" \
  '(select(.kind == "PersistentVolumeClaim" and .metadata.name == "thunder-secrets-pvc") | .metadata.annotations) |= (. + {"argocd.argoproj.io/hook": "Sync", "argocd.argoproj.io/hook-delete-policy": "BeforeHookCreation"} | del(.["helm.sh/hook-delete-policy"]))' \
  "thunder/thunder-secrets-pvc: Argo CD hook with delete policy 'BeforeHookCreation'"
neg "annotation missing" \
  '(select(.kind == "PersistentVolumeClaim" and .metadata.name == "thunder-database-pvc") | .metadata.annotations) |= del(.["platform.koorikla.io/delete-protection"])' \
  'thunder/thunder-database-pvc: hook PVC without annotation'
neg "policy removed" 'select(.kind != "ValidatingAdmissionPolicy")' \
  'thunder/thunder-database-pvc: no ValidatingAdmissionPolicy'
neg "policy deleted with a failed sync (hook-failed)" \
  '(select(.kind == "ValidatingAdmissionPolicy") | .metadata.annotations["helm.sh/hook-delete-policy"]) = "hook-failed"' \
  'thunder/thunder-database-pvc: no ValidatingAdmissionPolicy'
neg "policy for another namespace" \
  '(select(.kind == "ValidatingAdmissionPolicy") | .spec.matchConstraints.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]) = "elsewhere"' \
  'thunder/thunder-database-pvc: no ValidatingAdmissionPolicy'
neg "binding in Warn/Audit only" \
  '(select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions) = ["Warn", "Audit"]' \
  'has no Deny binding'
# A normal (non-hook) PVC is out of scope; a Skip-ped one too (Argo never applies it).
yq '(select(.kind == "PersistentVolumeClaim") | .metadata.annotations) |= del(.["helm.sh/hook"], .["helm.sh/hook-delete-policy"])' "$TMP/thunder.yaml" > "$TMP/plain.yaml"
assert_eq "$(violations "$TMP/plain.yaml")" "" "non-hook PVCs are not subject to the hook contract"
yq '(select(.kind == "PersistentVolumeClaim") | .metadata.annotations) |= (. + {"argocd.argoproj.io/hook": "Skip"} | del(.["platform.koorikla.io/delete-protection"]))' "$TMP/thunder.yaml" > "$TMP/skip.yaml"
assert_eq "$(violations "$TMP/skip.yaml")" "" "argocd.argoproj.io/hook: Skip PVCs are not hooks"

finish
