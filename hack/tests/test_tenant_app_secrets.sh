#!/usr/bin/env bash
# Application secrets (#250): what a Workload relies on when it reads an OpenBao value through an OpenChoreo
# SecretReference (docs/openchoreo.md "Secrets"), and the guards that keep one tenant out of another's secrets.
#   1. every ExternalSecret a component type renders for a SecretReference uses the cell namespace's
#      SecretStore openbao-tenant (never a ClusterSecretStore) and has a refreshInterval (rotation): a SecretReference
#      has no store field, so a developer cannot point it at another store; installation local turns this on;
#   2. an app repo (tenant AppProject) may sync SecretReferences but no ESO object (ExternalSecret, SecretStore,
#      PushSecret, ...): it cannot bring its own store through git either;
#   3. OpenBao: the tenant read policy is templated on the caller's identity entity, never a wildcard over
#      kv-tenant-*; so tenant A's SecretStore cannot read tenant B's path whatever key a SecretReference names.
# Live proof of 3 against a real OpenBao: `task test:openbao` (tenant A's token denied on B's mount); data-plane VAP
# that denies a tenant ExternalSecret on any other store: addons/secret-stores/tests/vap (kyverno CLI).
# Each check runs on the real render and on a mutated copy (the negative must be reported).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

echo "== test_tenant_app_secrets =="

# store_violations <render>: "<type> <resource id> <store kind>/<name> refresh=<interval>" for every ExternalSecret
# template of a ClusterComponentType that is not on SecretStore openbao-tenant or has no refreshInterval.
store_violations() {
  local n
  n=$(yq ea '[select(.kind == "ClusterComponentType") | .spec.resources[] | select(.template.kind == "ExternalSecret")] | length' "$1")
  [[ "$n" -gt 0 ]] || { echo "no ExternalSecret templates in any ClusterComponentType"; return; }
  # shellcheck disable=SC2016 # $t / $s are yq variables
  yq ea 'select(.kind == "ClusterComponentType") | .metadata.name as $t | .spec.resources[]
    | select(.template.kind == "ExternalSecret") | .template.spec as $s
    | select(($s.secretStoreRef.kind != "SecretStore") or ($s.secretStoreRef.name != "openbao-tenant") or (($s.refreshInterval // "") == ""))
    | $t + " " + .id + " " + ($s.secretStoreRef.kind // "") + "/" + ($s.secretStoreRef.name // "") + " refresh=" + ($s.refreshInterval // "")' "$1"
}

# whitelist_violations <render>: tenant AppProject entries outside group openchoreo.dev (or a kind wildcard; yq `== "*"` is a glob, hence test), and a
# missing SecretReference.
whitelist_violations() {
  yq ea 'select(.kind == "AppProject") | .spec.namespaceResourceWhitelist[]
    | select((.group != "openchoreo.dev") or (.kind | test("[*]"))) | "not allowed: " + .group + "/" + .kind' "$1"
  [[ -n "$(yq ea 'select(.kind == "AppProject") | .spec.namespaceResourceWhitelist[] | select(.kind == "SecretReference")' "$1")" ]] \
    || echo "SecretReference is not syncable from app repos"
}

# policy_violations <hcl>: path rules that are not scoped to the caller's own tenant mount.
policy_violations() {
  grep -E '^[[:space:]]*path[[:space:]]+"kv-' "$1" | grep -vE '^[[:space:]]*path[[:space:]]+"kv-tenant-\{\{identity\.entity\.metadata\.tenant\}\}/' || true
}

# 1. component types (addon openchoreo-platform as installation local renders it on mgmt)
prender="$TMP/platform-local.yaml"
render_platform local "$prender"
assert_eq "$(yq '.secrets.tenantStores.enabled' installations/local/installation.yaml)" true "installation local enables tenant stores"
ocp="$TMP/ocp.yaml"
render_layered_addon local openchoreo-platform "$ocp" "$prender" mgmt mgmt docker mgmt local flannel https://kubernetes.default.svc
assert_eq "$(store_violations "$ocp")" "" "local: every component-type ExternalSecret uses SecretStore openbao-tenant with a refreshInterval"
helm template openchoreo-platform addons/openchoreo-platform --namespace default > "$TMP/ocp-off.yaml"
assert_match "$(store_violations "$TMP/ocp-off.yaml")" "ClusterSecretStore/" "negative: tenant stores off -> component types on the data plane's ClusterSecretStore are reported"
yq ea '(select(.kind == "ClusterComponentType") | .spec.resources[] | select(.template.kind == "ExternalSecret") | .template.spec) |= del(.refreshInterval)' "$ocp" > "$TMP/ocp-norefresh.yaml"
assert_match "$(store_violations "$TMP/ocp-norefresh.yaml")" "refresh=$" "negative: an ExternalSecret without refreshInterval (rotation never picked up) is reported"

# 2. tenant AppProject (charts/tenant with the local installation + demo tenant)
helm template t charts/tenant --values installations/local/installation.yaml --values installations/local/tenants/demo.yaml \
  -s templates/appproject.yaml > "$TMP/ap.yaml"
assert_eq "$(whitelist_violations "$TMP/ap.yaml")" "" "app repos may sync SecretReference and only openchoreo.dev developer kinds"
helm template t charts/tenant --values installations/local/installation.yaml --values installations/local/tenants/demo.yaml \
  --set 'developerKinds={Component,Workload}' -s templates/appproject.yaml > "$TMP/ap-nosr.yaml"
assert_match "$(whitelist_violations "$TMP/ap-nosr.yaml")" "SecretReference is not syncable" "negative: SecretReference dropped from developerKinds is reported"
yq ea '(select(.kind == "AppProject") | .spec.namespaceResourceWhitelist) += [{"group": "external-secrets.io", "kind": "ExternalSecret"}]' "$TMP/ap.yaml" > "$TMP/ap-eso.yaml"
assert_match "$(whitelist_violations "$TMP/ap-eso.yaml")" "not allowed: external-secrets.io/ExternalSecret" "negative: an ESO kind in the tenant AppProject is reported"

# 3. OpenBao tenant read policy (files/policies, written by the policy reconciler)
pol=addons/openbao/files/policies/tenant-read.hcl
assert_eq "$(policy_violations "$pol")" "" "tenant-read reaches only kv-tenant-<caller's entity tenant>"
sed 's/kv-tenant-{{identity.entity.metadata.tenant}}\/data/kv-tenant-+\/data/' "$pol" > "$TMP/wild.hcl"
assert_match "$(policy_violations "$TMP/wild.hcl")" 'kv-tenant-\+/data' "negative: a wildcard over every tenant mount is reported"

finish
