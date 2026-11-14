#!/usr/bin/env bash
# ClusterSecretStore `platform` (addon secret-stores) is limited by spec.conditions to platformStore.namespaces. Every
# ExternalSecret that reads it must live in one of those namespaces, and every listed namespace must have a consumer
# (no stale grants). Uses the manifests hack/test.sh rendered for each installation's mgmt cluster and CAPI clusters
# (RENDERED_DIR), plus opt-in consumers rendered here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_secret_store_scope =="
if [[ -z "${RENDERED_DIR:-}" || ! -d "${RENDERED_DIR:-}" ]]; then
  echo "  SKIP: needs the renders from hack/test.sh (RENDERED_DIR)"
  exit 0
fi
cd "$ROOT"

# consumers <file>... -> "<namespace> <kind>/<name>" for every object that reads store `platform`. Includes the
# ExternalSecrets OpenChoreo renders per WorkflowRun from ClusterWorkflow/Workflow spec.resources: namespace
# ${metadata.namespace} is workflows-<org ns> (ORG_NS), store ${workflowplane.secretStore} is the plane's (WP_STORE).
consumers() {
  yq -N 'select(.kind == "ExternalSecret" or .kind == "ClusterExternalSecret" or .kind == "PushSecret")
    | select(([.spec.secretStoreRef.name, .spec.externalSecretSpec.secretStoreRef.name,
               .spec.secretStoreRefs[]?.name, .spec.data[]?.sourceRef.storeRef.name,
               .spec.dataFrom[]?.sourceRef.storeRef.name] | any_c(. == "platform")))
    | (.metadata.namespace // "<none>") + " " + .kind + "/" + .metadata.name' "$@" 2>/dev/null | grep -v '^$' || true
  ORG_NS="${ORG_NS:-default}" WP_STORE="${WP_STORE:-platform}" yq -N '
    select(.kind == "ClusterWorkflow" or .kind == "Workflow") | .metadata.name as $wf | .kind as $k
    | .spec.resources[]?.template | select(.kind == "ExternalSecret")
    | select((.spec.secretStoreRef.name | sub("\\$\\{workflowplane.secretStore\\}", strenv(WP_STORE))) == "platform")
    | (.metadata.namespace | sub("\\$\\{metadata.namespace\\}", "workflows-" + strenv(ORG_NS))) + " ExternalSecret/"
      + $k + ":" + $wf + ":" + .metadata.name' "$@" 2>/dev/null | grep -v '^$' || true
}
# allowed <secret-stores render> -> namespaces of store platform's conditions, one per line
allowed() {
  yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "platform") | .spec.conditions[].namespaces[]' "$1"
}

USED=""
check() {   # check <label> <store render> <render>...
  local label=$1 store=$2; shift 2
  local ok ns what n=0
  ok=$(allowed "$store")
  assert_nonempty "$ok" "$label: store platform has namespace conditions"
  while read -r ns what; do
    [[ -n "$ns" ]] || continue
    n=$((n + 1))
    USED="$USED $ns"
    case "$what" in
      ClusterExternalSecret/*|PushSecret/*) assert_eq "$what" "an ExternalSecret" "$label: $what reads store platform (not covered by namespace conditions)" ;;
    esac
    if printf '%s\n' "$ok" | grep -qx -- "$ns"; then
      assert_eq ok ok "$label: $ns $what allowed"
    else
      assert_eq "$ns not allowed" "$ns allowed" "$label: $what reads store platform from $ns: add it to addons/secret-stores platformStore.namespaces"
    fi
  done <<EOF
$(consumers "$@")
EOF
  assert_match "$n" '^[1-9]' "$label: consumers found"
}

for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  store="$RENDERED_DIR/addon-secret-stores-$inst-mgmt.yaml"
  [[ -f "$store" ]] || { assert_eq missing present "$inst: secret-stores mgmt render"; continue; }
  files=()
  for f in "$RENDERED_DIR"/addon-*-"$inst"-mgmt.yaml "$RENDERED_DIR"/cluster-"$inst"-*.yaml; do
    [[ -f "$f" ]] && files+=("$f")
  done
  ORG_NS=$(yq '.openchoreo.orgNamespace // "default"' "$inst_dir/installation.yaml") check "$inst" "$store" "${files[@]}"
done

files=()
for f in "$RENDERED_DIR"/addon-*-standalone.yaml; do [[ -f "$f" ]] && files+=("$f"); done
check standalone "$RENDERED_DIR/addon-secret-stores-standalone.yaml" "${files[@]}"

# Opt-in consumers that the default renders leave out: falco's sidekick outputs on mgmt.
falco_ns=$(yq '.addons.falco.namespace // "falco"' charts/platform/values.yaml)
helm template falco addons/falco --namespace "$falco_ns" -f addons/falco/values.yaml -f addons/falco/values/role-mgmt.yaml \
  --set escalation.enabled=true --set slack.enabled=true > "$TMP/falco-mgmt-outputs.yaml"
check "falco outputs (mgmt)" "$RENDERED_DIR/addon-secret-stores-standalone.yaml" "$TMP/falco-mgmt-outputs.yaml"

# No stale grants: every allowed namespace has a consumer somewhere.
while read -r ns; do
  [[ -n "$ns" ]] || continue
  case " $USED " in
    *" $ns "*) assert_eq ok ok "platformStore namespace $ns has a consumer" ;;
    *) assert_eq "unused" "used" "platformStore namespace $ns has no consumer: drop it" ;;
  esac
done <<EOF
$(allowed "$RENDERED_DIR/addon-secret-stores-standalone.yaml")
EOF

finish
