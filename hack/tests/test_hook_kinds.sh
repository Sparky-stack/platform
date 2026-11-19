#!/usr/bin/env bash
# No real config as an Argo CD hook (#221). Argo CD never diffs hooks: a changed hook alone never makes the app
# OutOfSync (and self-heal never repairs one), so ExternalSecret thunder-bootstrap kept its old spec after #218.
# Contract, for every addon render (hack/test.sh RENDERED_DIR, else standalone renders of every addon made here):
#   1. a non-Job object that Argo CD runs as a hook (argocd.argoproj.io/hook other than Skip, or a helm.sh/hook other
#      than crd-install/test*) is listed in hack/tests/hook_allowlist.yaml for its addon, with a reason;
#   2. a hook ConfigMap/Secret/ExternalSecret has a key <kind>.<name> in a NORMAL ConfigMap labelled
#      platform.koorikla.io/hook-inputs=true in the same render (its checksum changes with the hook, so Argo CD syncs);
#   3. every allowlist entry still renders somewhere (no stale exemptions).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"
ALLOW=hack/tests/hook_allowlist.yaml

# Effective Argo CD hook? (yq expression on an object)
# shellcheck disable=SC2016  # yq variables, not shell
IS_HOOK='(.metadata.annotations // {}) as $a | ($a["argocd.argoproj.io/hook"] // "") as $ah | ($a["helm.sh/hook"] // "") as $hh
  | (($ah != "" and $ah != "Skip") or ($ah == "" and $hh != "" and $hh != "crd-install" and ($hh | test("^test") | not)))'

# violations <addon> <render> -> one line per broken rule; also appends "<addon> <kind> <name>" of every hook to $TMP/seen
violations() {
  local addon=$1 f=$2 kind name lk
  # shellcheck disable=SC2016  # yq variables, not shell
  local keys; keys=$(yq -N "select(.kind == \"ConfigMap\" and .metadata.labels[\"platform.koorikla.io/hook-inputs\"] == \"true\")
    | select(($IS_HOOK) | not) | .data // {} | keys | .[]" "$f" | tr -d '\r')
  while IFS=$'\t' read -r kind name; do
    [[ -n "$kind" ]] || continue
    echo "$addon $kind $name" >> "$TMP/seen"
    if [[ -z "$(A="$addon" K="$kind" N="$name" yq -N '.[] | select(.addon == strenv(A) and .kind == strenv(K) and .name == strenv(N) and (.reason // "") != "") | .name' "$ALLOW")" ]]; then
      echo "$addon: $kind/$name is rendered as an Argo CD hook (never diffed): make it a normal resource ordered by sync waves, or allowlist it with a reason in $ALLOW"
      continue
    fi
    case $kind in
      ConfigMap | Secret | ExternalSecret)
        lk=$(echo "$kind" | tr '[:upper:]' '[:lower:]')
        grep -qxF "$lk.$name" <<< "$keys" ||
          echo "$addon: hook $kind/$name has no change detector (key $lk.$name in a normal ConfigMap labelled platform.koorikla.io/hook-inputs=true)" ;;
    esac
  done < <(yq -N "select(.kind != null and .kind != \"Job\" and .kind != \"Pod\") | select($IS_HOOK) | [.kind, .metadata.name] | join(\"	\")" "$f" | tr -d '\r')
}

# addon_of <render file name>: the longest addon name the file name starts with (kyverno vs kyverno-policies)
addon_of() {
  local base best="" a
  base=$(basename "$1" .yaml); base=${base#addon-}
  for a in addons/*/; do a=$(basename "$a"); [[ "$base" == "$a"-* && ${#a} -gt ${#best} ]] && best=$a; done
  echo "$best"
}

: > "$TMP/seen"; : > "$TMP/rendered"
n=0
if [[ -n "${RENDERED_DIR:-}" && -d "${RENDERED_DIR:-}" ]]; then
  for r in "$RENDERED_DIR"/addon-*.yaml; do
    [[ -f "$r" ]] || continue
    a=$(addon_of "$r"); [[ -n "$a" ]] || continue
    n=$((n + 1)); echo "$a" >> "$TMP/rendered"
    assert_eq "$(violations "$a" "$r")" "" "$(basename "$r" .yaml): no unlisted hook, every hook config has a change detector"
  done
else
  echo "  (no RENDERED_DIR: standalone renders of every addon)"
  for d in addons/*/; do
    a=$(basename "$d")
    ns=$(yq ".addons[\"$a\"].namespace // \"$a\"" charts/platform/values.yaml)
    helm template "$a" "$d" --namespace "$ns" > "$TMP/addon-$a-standalone.yaml" 2>/dev/null || { echo "  (skip $a: no standalone render)"; continue; }
    n=$((n + 1)); echo "$a" >> "$TMP/rendered"
    assert_eq "$(violations "$a" "$TMP/addon-$a-standalone.yaml")" "" "addons/$a (standalone): no unlisted hook, every hook config has a change detector"
  done
fi
echo "  checked $n addon renders"

# 3. No stale or reason-less allowlist entries.
while IFS=$'\t' read -r a k nm reason; do
  assert_nonempty "$reason" "allowlist $a $k/$nm has a reason"
  # Scoped PR CI (task test:changed) renders only the changed addons: judge staleness only for addons rendered here.
  grep -qxF "$a" "$TMP/rendered" || continue
  grep -qxF "$a $k $nm" "$TMP/seen" && seen=yes || seen=no
  assert_eq "$seen" "yes" "allowlist $a $k/$nm still renders as a hook"
done < <(yq -N '.[] | [.addon, .kind, .name, (.reason // "")] | join("	")' "$ALLOW" | tr -d '\r')

# 4. Negative: each way back to #221 is caught (on addon thunder's render).
render_standalone_addon thunder "$TMP/thunder.yaml"
neg() { # neg <label> <yq edit of the thunder render> <expected violation regex>
  yq "$2" "$TMP/thunder.yaml" > "$TMP/neg.yaml"   # no -N: keep the document separators
  assert_match "$(violations thunder "$TMP/neg.yaml")" "$3" "negative: $1"
}
# shellcheck disable=SC2016
neg "change detector key missing" 'del(select(.metadata.name == "thunder-setup-inputs") | .data["externalsecret.thunder-bootstrap"])' \
  'hook ExternalSecret/thunder-bootstrap has no change detector'
neg "change detector is itself a hook (never diffed either)" \
  '(select(.metadata.name == "thunder-setup-inputs") | .metadata.annotations["helm.sh/hook"]) = "pre-install"' \
  'hook ConfigMap/thunder-ai-agent-clients has no change detector'
neg "new helm hook on real config" \
  '(select(.kind == "Deployment") | .metadata.annotations["helm.sh/hook"]) = "pre-upgrade"' \
  'Deployment/thunder-deployment is rendered as an Argo CD hook'
neg "argocd hook on real config" \
  '(select(.metadata.name == "thunder-setup-inputs") | .metadata.annotations["argocd.argoproj.io/hook"]) = "PreSync"' \
  'ConfigMap/thunder-setup-inputs is rendered as an Argo CD hook'
violations kube-system "$TMP/thunder.yaml" > "$TMP/other.txt" || true
assert_match "$(cat "$TMP/other.txt")" 'kube-system: ExternalSecret/thunder-bootstrap is rendered as an Argo CD hook' \
  "negative: allowlist entries are per addon"
# Skip and crd-install are not hooks.
yq '(select(.kind == "Deployment") | .metadata.annotations) |= (. + {"argocd.argoproj.io/hook": "Skip", "helm.sh/hook": "crd-install"})' \
  "$TMP/thunder.yaml" > "$TMP/skip.yaml"
assert_eq "$(violations thunder "$TMP/skip.yaml")" "" "argocd.argoproj.io/hook Skip / helm.sh/hook crd-install are not hooks"

# 5. The change detectors really change: a values change that alters a hook changes the normal ConfigMap (= OutOfSync).
detector() { # detector <addon> <configmap> <key> [helm args...] -> checksum
  local a=$1 cm=$2 key=$3; shift 3
  helm template "$a" "addons/$a" --namespace "$a" "$@" |
    C="$cm" K="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(C)) | .data[strenv(K)]' | tr -d '\r'
}
es=$(detector thunder thunder-setup-inputs externalsecret.thunder-bootstrap)
assert_nonempty "$es" "thunder-setup-inputs carries the ExternalSecret checksum"
assert_eq "$([[ "$(detector thunder thunder-setup-inputs externalsecret.thunder-bootstrap --set bootstrapSecret.observabilityRemoteKey=other)" != "$es" ]] && echo changed)" \
  changed "a changed ExternalSecret thunder-bootstrap spec changes thunder-setup-inputs (#221)"
ai=$(detector thunder thunder-setup-inputs configmap.thunder-ai-agent-clients)
assert_eq "$([[ "$(detector thunder thunder-setup-inputs configmap.thunder-ai-agent-clients --set 'bootstrapSecret.aiAgentClients={rca}')" != "$ai" ]] && echo changed)" \
  changed "a changed ConfigMap thunder-ai-agent-clients changes thunder-setup-inputs"
up=$(detector thunder thunder-setup-inputs configmap.thunder-bootstrap)
assert_eq "$([[ "$(detector thunder thunder-setup-inputs configmap.thunder-bootstrap --set 'thunderid.bootstrap.scripts.99-x\.yaml=a: b')" != "$up" ]] && echo changed)" \
  changed "a changed upstream bootstrap script changes thunder-setup-inputs"
az=$(detector openchoreo-control-plane openchoreo-authz-bootstrap-inputs configmap.openchoreo-authz-bootstrap)
assert_nonempty "$az" "openchoreo-authz-bootstrap-inputs carries the authz bootstrap checksum"
assert_eq "$([[ "$(detector openchoreo-control-plane openchoreo-authz-bootstrap-inputs configmap.openchoreo-authz-bootstrap \
  --set openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.image=other)" != "$az" ]] && echo changed)" \
  changed "a changed authz bootstrap value changes openchoreo-authz-bootstrap-inputs"

finish
