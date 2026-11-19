#!/usr/bin/env bash
# ClusterSecretStore `platform` (addon secret-stores) is limited by spec.conditions to platformStore.namespaces. Every
# ExternalSecret that reads it must live in one of those namespaces, every listed namespace must have a consumer
# (no stale grants), and no `workflows-*` run namespace may ever read `platform`: workflow runs use the key-scoped
# `ClusterSecretStore/workflows` (Role resourceNames = workflowStore.keys). On workload clusters, store `dns`
# (invariant 5 exception: the external-dns Cloudflare token) is limited to namespace external-dns, and that token is
# never read through the tenant store `default`. Uses the manifests hack/test.sh rendered for each installation's mgmt
# cluster and CAPI clusters (RENDERED_DIR), plus opt-in consumers rendered here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_secret_store_scope =="
# scoped-ci renders: addons/secret-stores
if [[ -z "${RENDERED_DIR:-}" || ! -d "${RENDERED_DIR:-}" ]]; then
  echo "  SKIP: needs the renders from hack/test.sh (RENDERED_DIR)"
  exit 0
fi
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

# wp_store <file>... -> ClusterWorkflowPlane.spec.secretStoreRef.name (default: workflows)
wp_store() {
  local s=""
  local -a wf_files=()
  read_lines wf_files bash -c 'grep -l "ClusterWorkflowPlane" "$@" 2>/dev/null || true' _ "$@"
  if [[ ${#wf_files[@]} -gt 0 ]]; then
    s=$(yq -N 'select(.kind == "ClusterWorkflowPlane") | .spec.secretStoreRef.name' "${wf_files[@]}" 2>/dev/null | head -n1 || true)
  fi
  printf '%s\n' "${s:-workflows}"
}
# consumers <file>... -> "<namespace> <kind>/<name>" for every object that reads store `platform`. Includes the
# ExternalSecrets OpenChoreo renders per WorkflowRun from ClusterWorkflow/Workflow spec.resources: namespace
# ${metadata.namespace} is workflows-<org ns> (ORG_NS), store ${workflowplane.secretStore} is the plane's (WP_STORE).
consumers() {
  local wps
  wps=${WP_STORE:-$(wp_store "$@")}
  local -a es_files=() wf_files=()
  read_lines es_files bash -c 'grep -lE "ExternalSecret|PushSecret" "$@" 2>/dev/null || true' _ "$@"
  if [[ ${#es_files[@]} -gt 0 ]]; then
    yq -N 'select(.kind == "ExternalSecret" or .kind == "ClusterExternalSecret" or .kind == "PushSecret")
      | select(([.spec.secretStoreRef.name, .spec.externalSecretSpec.secretStoreRef.name,
                 .spec.secretStoreRefs[]?.name, .spec.data[]?.sourceRef.storeRef.name,
                 .spec.dataFrom[]?.sourceRef.storeRef.name] | any_c(. == "platform")))
      | (.metadata.namespace // "<none>") + " " + .kind + "/" + .metadata.name' "${es_files[@]}" 2>/dev/null | grep -v '^$' || true
  fi
  read_lines wf_files bash -c 'grep -l "Workflow" "$@" 2>/dev/null || true' _ "$@"
  if [[ ${#wf_files[@]} -gt 0 ]]; then
    # shellcheck disable=SC2016  # yq variables ($wf, $k), not shell
    ORG_NS="${ORG_NS:-default}" WP_STORE="$wps" yq -N '
      select(.kind == "ClusterWorkflow" or .kind == "Workflow") | .metadata.name as $wf | .kind as $k
      | .spec.resources[]?.template | select(.kind == "ExternalSecret")
      | select((.spec.secretStoreRef.name | sub("\\$\\{workflowplane.secretStore\\}", strenv(WP_STORE))) == "platform")
      | (.metadata.namespace | sub("\\$\\{metadata.namespace\\}", "workflows-" + strenv(ORG_NS))) + " ExternalSecret/"
        + $k + ":" + $wf + ":" + .metadata.name' "${wf_files[@]}" 2>/dev/null | grep -v '^$' || true
  fi
}
# allowed <secret-stores render> -> namespaces of store platform's conditions, one per line
allowed() {
  yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "platform") | .spec.conditions[].namespaces[]' "$1"
}
# platform_workflow_conds <secret-stores render> -> any workflows-* namespace or regex on store platform
platform_workflow_conds() {
  yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "platform")
    | (.spec.conditions[].namespaces[]?, .spec.conditions[].namespaceRegexes[]?)
    | select(test("(^|\^)workflows-"))' "$1" 2>/dev/null | grep -v '^$' || true
}

USED=""
check() {   # check <label> <store render> <render>...
  local label=$1 store=$2; shift 2
  local ok ns what n=0
  ok=$(allowed "$store")
  assert_nonempty "$ok" "$label: store platform has namespace conditions"
  assert_eq "$(platform_workflow_conds "$store")" "" "$label: store platform never admits workflows-* namespaces"
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

# --- mgmt store `workflows` (ClusterWorkflowPlane secretStoreRef, key-scoped in workflows-*) ------------------------
# wf_es_records <wp_store> <file>... -> "<ns> <wf>/<es> <store> <dataFrom count> <keys csv>" per workflow ExternalSecret
# (<store> = generator:<kind> for a store-less ExternalSecret fed by generators; generatorRef entries are not counted
# as dataFrom extract/find)
wf_es_records() {
  local wps=$1; shift
  local -a wf_files=()
  read_lines wf_files bash -c 'grep -l "Workflow" "$@" 2>/dev/null || true' _ "$@"
  [[ ${#wf_files[@]} -gt 0 ]] || return 0
  # shellcheck disable=SC2016  # yq variables ($wf, $k), not shell
  ORG_NS="${ORG_NS:-default}" WP_STORE="$wps" yq -N '
    select(.kind == "ClusterWorkflow" or .kind == "Workflow") | .metadata.name as $wf | .kind as $k
    | .spec.resources[]?.template | select(.kind == "ExternalSecret")
    | (.metadata.namespace | sub("\\$\\{metadata.namespace\\}", "workflows-" + strenv(ORG_NS))) + " "
      + $k + ":" + $wf + ":" + .metadata.name + " "
      + ((.spec.secretStoreRef.name // ("generator:" + ([.spec.dataFrom[]?.sourceRef.generatorRef.kind] | unique | join("+"))))
         | sub("\\$\\{workflowplane.secretStore\\}", strenv(WP_STORE))) + " "
      + ([.spec.dataFrom[]? | select(.sourceRef.generatorRef == null)] | length | tostring) + " "
      + ([.spec.data[]?.remoteRef.key] | join(","))' "${wf_files[@]}" 2>/dev/null | grep -v '^$' || true
}
check_workflows() {   # check_workflows <label> <store render> <render>...
  local label=$1 store=$2; shift 2
  local wps ns what s df keys k used_keys="" role_keys role_verbs
  assert_eq "$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore" and .metadata.name == "workflows") | .spec.conditions' "$store")" \
    '[{"namespaceRegexes":["^workflows-.+$"]}]' "$label: store workflows admits workflows-* namespaces only"
  wps=$(wp_store "$@")
  assert_eq "$wps" workflows "$label: ClusterWorkflowPlane secretStoreRef is workflows"
  while read -r ns what s df keys; do
    [[ -n "$ns" ]] || continue
    assert_match "$ns" '^workflows-.+$' "$label: $what runs in a workflows-* namespace ($ns)"
    assert_eq "$df" 0 "$label: $what uses explicit spec.data keys (no dataFrom extract/find)"
    case "$s" in
      workflows)
        for k in ${keys//,/ }; do
          [[ -n "$k" ]] && used_keys="${used_keys:+$used_keys$'\n'}$k"
        done
        ;;
      mgmt-harbor) assert_eq "$keys" harbor-ca-bundle "$label: $what reads only harbor-ca-bundle from mgmt-harbor" ;;
      # per-run GitHub App installation token (#34): generator output only, no store, no store key
      generator:GithubAccessToken) assert_eq "$keys" "" "$label: $what (GitHub App token generator) reads no store key" ;;
      *) assert_eq "$s" workflows "$label: $what uses store workflows (got $s)" ;;
    esac
  done <<EOF
$(wf_es_records "$wps" "$@")
EOF
  used_keys=$(printf '%s\n' "$used_keys" | LC_ALL=C sort -u | paste -sd, -)
  assert_nonempty "$used_keys" "$label: workflow ExternalSecrets read keys from store workflows"
  role_verbs=$(yq -N -o json -I0 'select(.kind == "Role" and .metadata.name == "eso-workflows") | .rules[0].verbs' "$store" 2>/dev/null || true)
  if [[ -n "$role_verbs" && "$role_verbs" != "null" ]]; then
    assert_eq "$(yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "workflows") | .spec.provider.kubernetes.auth.serviceAccount.name' "$store")" \
      eso-workflows "$label: store workflows authenticates as eso-workflows"
    assert_eq "$role_verbs" '["get"]' "$label: Role eso-workflows grants get only (no list/watch)"
    role_keys=$(yq -N 'select(.kind == "Role" and .metadata.name == "eso-workflows") | .rules[0].resourceNames[]' "$store" | LC_ALL=C sort -u | paste -sd, -)
    assert_eq "$role_keys" "$used_keys" "$label: Role eso-workflows resourceNames == exact keys read by workflows"
  else
    local wf_sa pf_sa
    wf_sa=$(yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "workflows") | (.spec.provider.aws.auth.jwt.serviceAccountRef.name // .spec.provider.vault.auth.kubernetes.serviceAccountRef.name)' "$store")
    pf_sa=$(yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "platform") | (.spec.provider.aws.auth.jwt.serviceAccountRef.name // .spec.provider.vault.auth.kubernetes.serviceAccountRef.name)' "$store")
    assert_nonempty "$wf_sa" "$label: store workflows has a dedicated provider ServiceAccount"
    assert_eq "$([[ "$wf_sa" != "$pf_sa" ]] && echo distinct || echo same)" distinct "$label: store workflows ServiceAccount ($wf_sa) != store platform ($pf_sa)"
  fi
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
  ORG_NS=$(yq '.openchoreo.orgNamespace // "default"' "$inst_dir/installation.yaml") check_workflows "$inst" "$store" "${files[@]}"
done

files=()
for f in "$RENDERED_DIR"/addon-*-standalone.yaml; do [[ -f "$f" ]] && files+=("$f"); done
check standalone "$RENDERED_DIR/addon-secret-stores-standalone.yaml" "${files[@]}"
check_workflows standalone "$RENDERED_DIR/addon-secret-stores-standalone.yaml" "${files[@]}"

# Opt-in consumers that the default renders leave out: falco's sidekick outputs on mgmt.
falco_ns=$(yq '.addons.falco.namespace // "falco"' charts/platform/values.yaml)
helm template falco addons/falco --namespace "$falco_ns" -f addons/falco/values.yaml -f addons/falco/values/role-mgmt.yaml \
  --set escalation.enabled=true --set slack.enabled=true > "$TMP/falco-mgmt-outputs.yaml"
check "falco outputs (mgmt)" "$RENDERED_DIR/addon-secret-stores-standalone.yaml" "$TMP/falco-mgmt-outputs.yaml"

# Opt-in consumers on mgmt (catalog default false): external-dns with Cloudflare, agentgateway's provider key, and the
# observability plane's AI agents.
ns_of() { yq ".addons[\"$1\"].namespace" charts/platform/values.yaml; }
helm template external-dns addons/external-dns --namespace "$(ns_of external-dns)" -f addons/external-dns/values.yaml \
  -f addons/external-dns/values/role-mgmt.yaml -f addons/external-dns/values/dns-cloudflare.yaml \
  --set dns.provider=cloudflare --set 'dns.domainFilters={example.com}' --set 'external-dns.domainFilters={example.com}' \
  --set-string external-dns.txtOwnerId=sample --show-only templates/secrets.yaml > "$TMP/external-dns-mgmt.yaml"
render_standalone_addon agentgateway "$TMP/agentgateway-mgmt.yaml"
helm template openchoreo-observability-plane addons/openchoreo-observability-plane \
  --namespace "$(ns_of openchoreo-observability-plane)" --show-only templates/secrets.yaml \
  --set openchoreo-observability-plane.rca.enabled=true --set openchoreo-observability-plane.rca.llm.modelName=m \
  --set openchoreo-observability-plane.finOpsAgent.enabled=true --set openchoreo-observability-plane.finOpsAgent.llmName=m \
  > "$TMP/obs-ai-agents.yaml"
check "opt-in mgmt consumers (external-dns, agentgateway, AI agents)" "$RENDERED_DIR/addon-secret-stores-standalone.yaml" \
  "$TMP/external-dns-mgmt.yaml" "$TMP/agentgateway-mgmt.yaml" "$TMP/obs-ai-agents.yaml"

# --- workload store `dns` -------------------------------------------------------------------------------------------
# es_reading <store> <file>... -> "<namespace> <name> <remote keys>" for every ExternalSecret using that store.
es_reading() {
  local store=$1; shift
  local -a es_files=()
  read_lines es_files bash -c 'grep -l "ExternalSecret" "$@" 2>/dev/null || true' _ "$@"
  [[ ${#es_files[@]} -gt 0 ]] || return 0
  S="$store" yq -N 'select(.kind == "ExternalSecret" and .spec.secretStoreRef.name == strenv(S))
    | (.metadata.namespace // "<none>") + " " + .metadata.name + " " + ([.spec.data[]?.remoteRef.key] | join(","))' "${es_files[@]}" 2>/dev/null | grep -v '^$' || true
}
dns_checked=0
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir") dnsp=$(yq '.dns.provider // "none"' "$inst_dir/installation.yaml")
  render_platform "$inst" "$TMP/platform-$inst.yaml"
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf") store="$RENDERED_DIR/addon-secret-stores-$inst-$c.yaml"
    [[ -f "$store" ]] || continue
    n_dns=$(yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "dns") | .metadata.name' "$store" | grep -c . || true)
    if [[ "$dnsp" != cloudflare ]]; then
      assert_eq "$n_dns" 0 "$inst/$c: no store dns without dns.provider cloudflare"
      continue
    fi
    assert_eq "$n_dns" 1 "$inst/$c: store dns exists (dns.provider cloudflare)"
    assert_eq "$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore" and .metadata.name == "dns") | .spec.conditions' "$store")" \
      '[{"namespaces":["external-dns"]}]' "$inst/$c: store dns readable from namespace external-dns only"
    # external-dns forced on, rendered like its ApplicationSet; every other workload addon as test.sh rendered it
    args=()
    read_lines args addon_helm_args external-dns "$inst_dir" "$TMP/platform-$inst.yaml" workload "$c" "$(yq '.provider' "$cf")" \
      "$(yq '.environment // "development"' "$cf")" "$(yq '.region // "local"' "$cf")" "$(yq '.cni // "cilium"' "$cf")" https://192.0.2.10:6443
    helm template external-dns addons/external-dns --namespace "$(ns_of external-dns)" "${args[@]}" > "$TMP/edns-$inst-$c.yaml"
    files=("$TMP/edns-$inst-$c.yaml")
    for f in "$RENDERED_DIR"/addon-*-"$inst"-"$c".yaml; do [[ -f "$f" ]] && files+=("$f"); done
    while read -r ns name _keys; do
      [[ -n "$ns" ]] || continue
      dns_checked=$((dns_checked + 1))
      assert_eq "$ns" external-dns "$inst/$c: ExternalSecret $name reads store dns from namespace external-dns"
    done <<EOF
$(es_reading dns "${files[@]}")
EOF
    assert_eq "$(es_reading default "${files[@]}" | awk '$3 ~ /(^|,)external-dns-/' | head -1)" "" \
      "$inst/$c: no external-dns credential through the tenant store default"
  done
done
assert_match "$dns_checked" '^[1-9]' "store dns consumers found (hetzner-example, Cloudflare)"

# Negative: an overlay pointing the Cloudflare token at the tenant store is refused at render time.
mkdir -p "$TMP/neg/clusters" "$TMP/neg/addons/external-dns"
cp installations/hetzner-example/installation.yaml "$TMP/neg/"
printf 'secrets:\n  store: default\n' > "$TMP/neg/addons/external-dns/values.yaml"
args=()
read_lines args addon_helm_args external-dns "$TMP/neg" "$TMP/platform-hetzner-example.yaml" workload dev-fsn1 hetzner development fsn1 cilium https://192.0.2.10:6443
if helm template external-dns addons/external-dns --namespace external-dns "${args[@]}" > /dev/null 2> "$TMP/neg.err"; then
  assert_eq rendered fails "workload Cloudflare token via store default is refused"
else
  assert_match "$(cat "$TMP/neg.err")" 'only store dns' "workload Cloudflare token via store default is refused"
fi

# Negative: workflows-* regaining the full platform store (via platformStore.namespaces, ClusterWorkflowPlane
# secretStoreRef, or a mutated ClusterSecretStore/platform condition) is refused.
if helm template secret-stores addons/secret-stores --namespace external-secrets \
  --set 'platformStore.namespaces={argocd,workflows-default}' > /dev/null 2> "$TMP/neg-ss.err"; then
  assert_eq rendered fails "workflows-default in platformStore.namespaces is refused at render time"
else
  assert_match "$(cat "$TMP/neg-ss.err")" 'must not include workflow run namespace' "workflows-default in platformStore.namespaces is refused at render time"
fi
if helm template openchoreo-workflow-plane addons/openchoreo-workflow-plane --namespace openchoreo-workflow-plane \
  --set clusterWorkflowPlane.secretStore=platform > /dev/null 2> "$TMP/neg-wp.err"; then
  assert_eq rendered fails "clusterWorkflowPlane.secretStore=platform is refused at render time"
else
  assert_match "$(cat "$TMP/neg-wp.err")" 'never the full platform store' "clusterWorkflowPlane.secretStore=platform is refused at render time"
fi
yq '(. | select(.kind == "ClusterSecretStore" and .metadata.name == "platform") | .spec.conditions[0].namespaces) += ["workflows-default"]' \
  "$RENDERED_DIR/addon-secret-stores-standalone.yaml" > "$TMP/neg-platform-wf.yaml"
assert_eq "$(platform_workflow_conds "$TMP/neg-platform-wf.yaml")" "workflows-default" \
  "negative: platform_workflow_conds catches workflows-default added to ClusterSecretStore/platform"
assert_match "$(WP_STORE=platform consumers "$RENDERED_DIR/addon-openchoreo-platform-standalone.yaml")" '^workflows-default ExternalSecret/' \
  "negative: consumers() catches workflows-default if ClusterWorkflowPlane points at store platform"

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
