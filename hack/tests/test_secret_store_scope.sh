#!/usr/bin/env bash
# ClusterSecretStore `platform` (addon secret-stores) is limited by spec.conditions to platformStore.namespaces, which
# must never admit a `workflows-*` run namespace (workflow runs use the key-scoped `ClusterSecretStore/workflows`, Role
# resourceNames = workflowStore.keys), and every listed namespace must have a consumer (no stale grants). On workload
# clusters, store `dns` (invariant 5 exception: the external-dns Cloudflare token) is limited to namespace external-dns.
# Cross-chart, so it needs every render (RENDERED_DIR from hack/test.sh): runs in the full suite (push, merge_group) and
# in a scoped PR run only when a changed chart defines a store or workflow (full-if below). Each consumer's own check
# (in scope of its store) is test_secret_store_scope_chart.sh, which scoped PR runs include.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# scoped-ci full-if: ^(platformStore|workflowStore):|^kind: (ClusterWorkflowPlane|ClusterWorkflow|Workflow) *$|only store dns
if [[ -z "${RENDERED_DIR:-}" || ! -d "${RENDERED_DIR:-}" ]]; then
  echo "  SKIP: needs the renders from hack/test.sh (RENDERED_DIR)"
  exit 0
fi
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh
# shellcheck source=secret_store_scope_lib.sh
source hack/tests/secret_store_scope_lib.sh

# The fixture test_secret_store_scope_chart.sh uses when a scoped run did not render the stores.
if [[ -n "${SECRET_STORE_FIXTURE_UPDATE:-}" ]]; then ss_fixture_now > "$SS_FIXTURE"; fi
assert_eq "$(ss_fixture_now)" "$(cat "$SS_FIXTURE")" \
  "hack/tests/fixtures/secret-store-scope.txt == rendered store scope (regenerate: SECRET_STORE_FIXTURE_UPDATE=1 task test)"

USED=""
check_store() {   # check_store <label> <store render> [<render>...]: no <render> = store only (consumers counted elsewhere)
  local label=$1 store=$2 n c; shift 2
  assert_nonempty "$(allowed "$store")" "$label: store platform has namespace conditions"
  assert_eq "$(platform_workflow_conds "$store")" "" "$label: store platform never admits workflows-* namespaces"
  [[ $# -gt 0 ]] || return 0
  c=$(consumers "$@")
  n=$(printf '%s\n' "$c" | grep -c . || true)
  USED="$USED $(printf '%s\n' "$c" | awk '{ print $1 }' | tr '\n' ' ')"
  assert_match "$n" '^[1-9]' "$label: consumers found"
}
check_workflows_store() {   # check_workflows_store <label> <store render> <render>...
  local label=$1 store=$2 wps used_keys role_keys role_verbs; shift 2
  assert_eq "$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore" and .metadata.name == "workflows") | .spec.conditions' "$store")" \
    '[{"namespaceRegexes":["^workflows-.+$"]}]' "$label: store workflows admits workflows-* namespaces only"
  wps=$(wp_store "$@")
  assert_eq "$wps" workflows "$label: ClusterWorkflowPlane secretStoreRef is workflows"
  used_keys=$(wf_es_records "$wps" "$@" | awk '$3 == "workflows" { gsub(",", "\n", $5); print $5 }' | grep -v '^$' | LC_ALL=C sort -u | paste -sd, - || true)
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

for l in $(ss_labels); do
  store=$(ss_store "$l")
  [[ -f "$store" ]] || { assert_eq missing present "$l: secret-stores mgmt render"; continue; }
  files=()
  read_lines files ss_files "$l"
  ORG_NS=$(ss_org_ns "$l") check_store "$l" "$store" "${files[@]}"
  ORG_NS=$(ss_org_ns "$l") check_workflows_store "$l" "$store" "${files[@]}"
done
# Opt-in consumers (their per-consumer checks: test_secret_store_scope_chart.sh); their namespaces count as used.
ss_render_opt_in "$TMP"
check_store "falco outputs (mgmt)" "$RENDERED_DIR/addon-secret-stores-standalone.yaml"
check_store "$SS_OPT_IN_LABEL" "$RENDERED_DIR/addon-secret-stores-standalone.yaml"
USED="$USED $(consumers "$TMP/falco-mgmt-outputs.yaml" "$TMP/external-dns-mgmt.yaml" "$TMP/agentgateway-mgmt.yaml" \
  "$TMP/obs-ai-agents.yaml" | awk '{ print $1 }' | tr '\n' ' ')"

# --- workload store `dns` -------------------------------------------------------------------------------------------
dns_checked=0
for inst in $(ss_labels | grep -vx standalone); do
  dnsp=$(yq '.dns.provider // "none"' "installations/$inst/installation.yaml")
  render_platform "$inst" "$TMP/platform-$inst.yaml"
  for cf in installations/"$inst"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf") store="$RENDERED_DIR/addon-secret-stores-$inst-$c.yaml"
    [[ -f "$store" ]] || continue
    n_dns=$(n_dns_store "$store")
    if [[ "$dnsp" != cloudflare ]]; then
      assert_eq "$n_dns" 0 "$inst/$c: no store dns without dns.provider cloudflare"
      continue
    fi
    assert_eq "$n_dns" 1 "$inst/$c: store dns exists (dns.provider cloudflare)"
    assert_eq "$(yq -N -o json -I0 'select(.kind == "ClusterSecretStore" and .metadata.name == "dns") | .spec.conditions' "$store")" \
      '[{"namespaces":["external-dns"]}]' "$inst/$c: store dns readable from namespace external-dns only"
    files=()
    read_lines files ss_dns_files "$inst" "$cf" "$TMP/platform-$inst.yaml" "$TMP"
    dns_checked=$((dns_checked + $(es_reading dns "${files[@]}" | grep -c . || true)))
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
