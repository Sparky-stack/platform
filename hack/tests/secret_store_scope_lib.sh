# shellcheck shell=bash disable=SC2034  # SS_* are read by the tests that source this
# Shared by test_secret_store_scope.sh (cross-chart: stores, aggregates, negatives; full suite only) and
# test_secret_store_scope_chart.sh (every consumer in the rendered charts; also scoped PR runs). Sourced after lib.sh,
# from $ROOT, with hack/lib/portable.sh and hack/lib/addons.sh loaded.
# Fixture: the stores' rendered scope, so a scoped run that did not render addons/secret-stores still knows it.
# test_secret_store_scope.sh asserts it == the renders; regenerate with SECRET_STORE_FIXTURE_UPDATE=1 task test.
SS_FIXTURE="$ROOT/hack/tests/fixtures/secret-store-scope.txt"

# wp_store <file>... -> ClusterWorkflowPlane.spec.secretStoreRef.name (default: workflows)
wp_store() {
  local s=""
  local -a wf_files=()
  read_lines wf_files bash -c 'grep -l "ClusterWorkflowPlane" "$@" 2>/dev/null || true' _ "$@"
  if [[ ${#wf_files[@]} -gt 0 ]]; then
    s=$(yq -N 'select(.kind == "ClusterWorkflowPlane") | .spec.secretStoreRef.name' "${wf_files[@]}" 2>/dev/null | sed -n 1p || true)
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
# n_dns_store <secret-stores render> -> number of ClusterSecretStore/dns
n_dns_store() {
  yq -N 'select(.kind == "ClusterSecretStore" and .metadata.name == "dns") | .metadata.name' "$1" | grep -c . || true
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
# es_reading <store> <file>... -> "<namespace> <name> <remote keys>" for every ExternalSecret using that store.
es_reading() {
  local store=$1; shift
  local -a es_files=()
  read_lines es_files bash -c 'grep -l "ExternalSecret" "$@" 2>/dev/null || true' _ "$@"
  [[ ${#es_files[@]} -gt 0 ]] || return 0
  S="$store" yq -N 'select(.kind == "ExternalSecret" and .spec.secretStoreRef.name == strenv(S))
    | (.metadata.namespace // "<none>") + " " + .metadata.name + " " + ([.spec.data[]?.remoteRef.key] | join(","))' "${es_files[@]}" 2>/dev/null | grep -v '^$' || true
}
ns_of() { yq ".addons[\"$1\"].namespace" charts/platform/values.yaml; }

# --- what hack/test.sh rendered: label = an installation (its mgmt cluster + CAPI clusters) or standalone ------------
ss_labels() {
  local d
  for d in installations/*; do [[ -f "$d/installation.yaml" ]] && basename "$d"; done
  echo standalone
}
ss_store() { if [[ "$1" == standalone ]]; then echo "$RENDERED_DIR/addon-secret-stores-standalone.yaml"; else echo "$RENDERED_DIR/addon-secret-stores-$1-mgmt.yaml"; fi; }
ss_org_ns() { if [[ "$1" == standalone ]]; then echo default; else yq '.openchoreo.orgNamespace // "default"' "installations/$1/installation.yaml"; fi; }
# ss_files <label> -> the label's renders present in RENDERED_DIR (a scoped run: only the changed charts' + cluster-*)
ss_files() {
  local f
  if [[ "$1" == standalone ]]; then
    for f in "$RENDERED_DIR"/addon-*-standalone.yaml; do [[ -f "$f" ]] && echo "$f"; done
  else
    for f in "$RENDERED_DIR"/addon-*-"$1"-mgmt.yaml "$RENDERED_DIR"/cluster-"$1"-*.yaml; do [[ -f "$f" ]] && echo "$f"; done
  fi
  return 0
}
# ss_fixture_now -> the fixture as the renders say: "platform <label> <ns>" and "dns <inst>/<cluster>" (store dns exists)
ss_fixture_now() {
  local l inst cf c store
  for l in $(ss_labels); do
    store=$(ss_store "$l")
    [[ -f "$store" ]] && allowed "$store" | sed "s|^|platform $l |"
  done
  for inst in $(ss_labels | grep -vx standalone); do
    for cf in installations/"$inst"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      c=$(yq '.name' "$cf") store="$RENDERED_DIR/addon-secret-stores-$inst-$c.yaml"
      [[ -f "$store" && "$(n_dns_store "$store")" == 1 ]] && echo "dns $inst/$c"
    done
  done
  return 0
}
# ss_allowed <label> -> store platform's namespaces: from its render when present, else from the fixture
ss_allowed() {
  local store
  store=$(ss_store "$1")
  if [[ -f "$store" ]]; then allowed "$store"; else awk -v l="$1" '$1 == "platform" && $2 == l { print $3 }' "$SS_FIXTURE"; fi
}
# ss_dns_clusters <inst> -> cluster files of the workload clusters with store dns: from their store render when
# present, else the fixture
ss_dns_clusters() {
  local cf c store
  for cf in installations/"$1"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf") store="$RENDERED_DIR/addon-secret-stores-$1-$c.yaml"
    if [[ -f "$store" ]]; then [[ "$(n_dns_store "$store")" == 1 ]] && echo "$cf"
    else grep -qx "dns $1/$c" "$SS_FIXTURE" && echo "$cf"; fi
  done
  return 0
}

# --- consumers the default renders leave out ------------------------------------------------------------------------
# ss_render_opt_in <dir>: falco's sidekick outputs on mgmt -> <dir>/falco-mgmt-outputs.yaml; the opt-in mgmt consumers
# (catalog default false: external-dns with Cloudflare, agentgateway's provider key, the observability plane's AI
# agents) -> <dir>/{external-dns-mgmt,agentgateway-mgmt,obs-ai-agents}.yaml
ss_render_opt_in() {
  local d=$1 falco_ns
  falco_ns=$(yq '.addons.falco.namespace // "falco"' charts/platform/values.yaml)
  helm template falco addons/falco --namespace "$falco_ns" -f addons/falco/values.yaml -f addons/falco/values/role-mgmt.yaml \
    --set escalation.enabled=true --set slack.enabled=true > "$d/falco-mgmt-outputs.yaml"
  helm template external-dns addons/external-dns --namespace "$(ns_of external-dns)" -f addons/external-dns/values.yaml \
    -f addons/external-dns/values/role-mgmt.yaml -f addons/external-dns/values/dns-cloudflare.yaml \
    --set dns.provider=cloudflare --set 'dns.domainFilters={example.com}' --set 'external-dns.domainFilters={example.com}' \
    --set-string external-dns.txtOwnerId=sample --show-only templates/secrets.yaml > "$d/external-dns-mgmt.yaml"
  render_standalone_addon agentgateway "$d/agentgateway-mgmt.yaml"
  helm template openchoreo-observability-plane addons/openchoreo-observability-plane \
    --namespace "$(ns_of openchoreo-observability-plane)" --show-only templates/secrets.yaml \
    --set openchoreo-observability-plane.rca.enabled=true --set openchoreo-observability-plane.rca.llm.modelName=m \
    --set openchoreo-observability-plane.finOpsAgent.enabled=true --set openchoreo-observability-plane.finOpsAgent.llmName=m \
    > "$d/obs-ai-agents.yaml"
}
SS_OPT_IN_LABEL="opt-in mgmt consumers (external-dns, agentgateway, AI agents)"

# ss_dns_files <inst> <cluster file> <platform render> <out dir> -> files to check on a Cloudflare workload cluster: external-dns
# forced on, rendered like its ApplicationSet (<out dir>/edns-<inst>-<c>.yaml), plus every addon render present
ss_dns_files() {
  local inst=$1 cf=$2 prender=$3 d=$4 c f
  local -a args=()
  c=$(yq '.name' "$cf")
  read_lines args addon_helm_args external-dns "installations/$inst" "$prender" workload "$c" "$(yq '.provider' "$cf")" \
    "$(yq '.environment // "development"' "$cf")" "$(yq '.region // "local"' "$cf")" "$(yq '.cni // "cilium"' "$cf")" https://192.0.2.10:6443
  helm template external-dns addons/external-dns --namespace "$(ns_of external-dns)" "${args[@]}" > "$d/edns-$inst-$c.yaml"
  echo "$d/edns-$inst-$c.yaml"
  for f in "$RENDERED_DIR"/addon-*-"$inst"-"$c".yaml; do [[ -f "$f" ]] && echo "$f"; done
  return 0
}
