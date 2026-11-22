#!/usr/bin/env bash
# Every secret consumer in the charts hack/test.sh rendered (RENDERED_DIR; a scoped PR run renders only the changed
# charts) stays inside its store's scope: an ExternalSecret reading ClusterSecretStore `platform` lives in one of
# platformStore.namespaces (never a ClusterExternalSecret/PushSecret), a workflow-run ExternalSecret runs in workflows-*
# with explicit keys from store `workflows`, and on Cloudflare workload clusters store `dns` is read only from
# namespace external-dns and the external-dns token never through the tenant store `default`. The stores' scope comes
# from their render, else hack/tests/fixtures/secret-store-scope.txt. The stores themselves, the aggregates (every
# grant used, Role keys == keys read) and the negatives: test_secret_store_scope.sh (full suite).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

need_renders
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh
# shellcheck source=secret_store_scope_lib.sh
source hack/tests/secret_store_scope_lib.sh

N=0
check_consumers() {   # check_consumers <label> <allowed namespaces> <render>...; N = consumers of store platform
  local label=$1 ok=$2 ns what; shift 2
  N=0
  while read -r ns what; do
    [[ -n "$ns" ]] || continue
    N=$((N + 1))
    case "$what" in
      ClusterExternalSecret/*|PushSecret/*) assert_eq "$what" "an ExternalSecret" "$label: $what reads store platform (not covered by namespace conditions)" ;;
    esac
    if grep -qx -- "$ns" <<<"$ok"; then   # not printf | grep -q: an early grep exit fails printf (pipefail)
      assert_eq ok ok "$label: $ns $what allowed"
    else
      assert_eq "$ns not allowed" "$ns allowed" "$label: $what reads store platform from $ns: add it to addons/secret-stores platformStore.namespaces"
    fi
  done <<EOF
$(consumers "$@")
EOF
}
check_workflow_records() {   # check_workflow_records <label> <render>...
  local label=$1 ns what s df keys; shift
  while read -r ns what s df keys; do
    [[ -n "$ns" ]] || continue
    assert_match "$ns" '^workflows-.+$' "$label: $what runs in a workflows-* namespace ($ns)"
    assert_eq "$df" 0 "$label: $what uses explicit spec.data keys (no dataFrom extract/find)"
    case "$s" in
      workflows) ;;   # keys == Role eso-workflows resourceNames: test_secret_store_scope.sh
      mgmt-harbor) assert_eq "$keys" harbor-ca-bundle "$label: $what reads only harbor-ca-bundle from mgmt-harbor" ;;
      # per-run GitHub App installation token (#34): generator output only, no store, no store key
      generator:GithubAccessToken) assert_eq "$keys" "" "$label: $what (GitHub App token generator) reads no store key" ;;
      *) assert_eq "$s" workflows "$label: $what uses store workflows (got $s)" ;;
    esac
  done <<EOF
$(wf_es_records "$(wp_store "$@")" "$@")
EOF
}

for l in $(ss_labels); do
  files=()
  read_lines files ss_files "$l"
  [[ ${#files[@]} -gt 0 ]] || continue
  ORG_NS=$(ss_org_ns "$l") check_consumers "$l" "$(ss_allowed "$l")" "${files[@]}"
  ORG_NS=$(ss_org_ns "$l") check_workflow_records "$l" "${files[@]}"
done

ss_render_opt_in "$TMP"
check_consumers "falco outputs (mgmt)" "$(ss_allowed standalone)" "$TMP/falco-mgmt-outputs.yaml"
assert_match "$N" '^[1-9]' "falco outputs (mgmt): consumers found"
check_consumers "$SS_OPT_IN_LABEL" "$(ss_allowed standalone)" "$TMP/external-dns-mgmt.yaml" "$TMP/agentgateway-mgmt.yaml" "$TMP/obs-ai-agents.yaml"
assert_match "$N" '^[1-9]' "$SS_OPT_IN_LABEL: consumers found"

# --- workload store `dns` (hetzner-example, Cloudflare) -------------------------------------------------------------
for inst in $(ss_labels | grep -vx standalone); do
  [[ "$(yq '.dns.provider // "none"' "installations/$inst/installation.yaml")" == cloudflare ]] || continue
  render_platform "$inst" "$TMP/platform-$inst.yaml"
  for cf in $(ss_dns_clusters "$inst"); do
    c=$(yq '.name' "$cf") files=()
    read_lines files ss_dns_files "$inst" "$cf" "$TMP/platform-$inst.yaml" "$TMP"
    while read -r ns name _keys; do
      [[ -n "$ns" ]] || continue
      assert_eq "$ns" external-dns "$inst/$c: ExternalSecret $name reads store dns from namespace external-dns"
    done <<EOF
$(es_reading dns "${files[@]}")
EOF
    assert_eq "$(es_reading default "${files[@]}" | awk '$3 ~ /(^|,)external-dns-/' | head -1)" "" \
      "$inst/$c: no external-dns credential through the tenant store default"
  done
done

finish
