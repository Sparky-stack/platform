#!/usr/bin/env bash
# Demo tenant secrets seed (charts/tenant templates/demo-secrets.yaml): a clean bootstrap starts with an empty OpenBao,
# so every value the demo app's SecretReferences point to must be seeded with no manual step, declaratively with ESO
# (SecretStore <project>-openbao-writer + Password generator + one PushSecret per demoSecrets key).
# Checks:
#   1. contract: every remoteRef (key, property) of the vendored hello-world SecretReferences
#      (hack/tests/fixtures/hello-world/) is pushed by a PushSecret the local demo tenant renders, through the store that
#      logs in as the tenant's own writer ServiceAccount against its own mount; nothing rendered without demoSecrets or
#      tenantStores; invalid and duplicate keys refused
#   2. never overwrite, never delete: updatePolicy IfNotExists, deletionPolicy None, check-and-set; demo-only-<24 hex>
#      from the Password generator; final sync wave; kubeconform -strict against the ESO CRD schemas
#   3. name/pin contracts with addon openbao: server, audience, login role, CA Secret (ExternalSecret in the writer
#      namespace + ClusterSecretStore condition), policy tenant-write lets the writer mark keys (ESO custom_metadata)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"
SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
if [[ ! -f "$SCHEMAS_DIR/external-secrets.io/pushsecret_v1alpha1.json" ]]; then
  SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
fi

LOCAL=(-f installations/local/installation.yaml -f installations/local/tenants/demo.yaml)
R="$TMP/tenant.yaml"
helm template tenant-demo charts/tenant "${LOCAL[@]}" -s templates/demo-secrets.yaml > "$R"
obj() { yq ea "select(.kind == \"$1\" and .metadata.name == \"$2\") | $3" "$R"; }
ss() { obj SecretStore demo-openbao-writer "$1"; }
gen() { obj Password demo-demo-value "$1"; }
ps() { yq ea "select(.kind == \"PushSecret\") | $1" "$R"; }

# --- 1. every SecretReference remoteRef of the demo app is seeded -------------------------------------------------------
refs=$(yq ea 'select(.kind == "SecretReference") | .spec.data[].remoteRef | .key + "/" + .property' \
  hack/tests/fixtures/hello-world/*.yaml | sort -u)
assert_nonempty "$refs" "vendored hello-world SecretReference has remoteRefs"
pushed=" $(ps '.spec.data[].match.remoteRef | .remoteKey + "/" + .property' | tr '\n' ' ') "
for r in $refs; do
  assert_match "$pushed" " $r " "demo tenant seeds SecretReference remoteRef $r"
done
assert_eq "$(ps .metadata.name)" demo-seed-hello-world "one PushSecret per key, named <project>-seed-<key>"
assert_eq "$(yq -N ea '.metadata.namespace' "$R" | sort -u)" openbao-tenants "everything in the writer namespace"
assert_eq "$(ps '.spec.secretStoreRefs | to_json(0)')" '[{"kind":"SecretStore","name":"demo-openbao-writer"}]' \
  "PushSecret writes only through the tenant's writer store (no ClusterSecretStore, no label selector)"
assert_eq "$(ss .spec.provider.vault.path)" kv-tenant-demo "store writes the tenant's own mount"
assert_eq "$(ss .spec.provider.vault.version)" v2 "kv v2"
assert_eq "$(ss .spec.provider.vault.auth.kubernetes.serviceAccountRef.name)" demo-writer "logs in as the tenant's writer ServiceAccount"
helm template t charts/tenant "${LOCAL[@]}" -s templates/secrets.yaml > "$TMP/tenant-secrets.yaml"
assert_eq "$(yq ea 'select(.kind == "ServiceAccount" and .metadata.name == "demo-writer") | .metadata.namespace' "$TMP/tenant-secrets.yaml")" \
  openbao-tenants "writer ServiceAccount rendered by the same chart, same namespace"
n=$(helm template t charts/tenant -f installations/local/installation.yaml --set project=demo -s templates/demo-secrets.yaml 2>/dev/null | grep -c '^kind:' || true)
assert_eq "$n" 0 "no demoSecrets -> nothing rendered"
n=$(helm template t charts/tenant -f installations/local/tenants/demo.yaml -s templates/demo-secrets.yaml 2>/dev/null | grep -c '^kind:' || true)
assert_eq "$n" 0 "tenantStores off -> nothing rendered"
refused() { # refused <description> <--set args...>: the chart must not render
  if helm template t charts/tenant "${LOCAL[@]}" "${@:2}" -s templates/demo-secrets.yaml >/dev/null 2>&1; then
    assert_eq rendered refused "$1"
  else assert_eq refused refused "$1"; fi
}
refused "demoSecrets key with a slash is refused" --set 'demoSecrets[0].key=a/b' --set 'demoSecrets[0].property=x'
refused "demoSecrets key that is no DNS label (it names the PushSecret) is refused" --set 'demoSecrets[0].key=Db_Pass'
out=$(helm template t charts/tenant "${LOCAL[@]}" --set 'demoSecrets[1].key=hello-world' --set 'demoSecrets[1].property=other' 2>&1 || true)
assert_match "$out" 'demoSecrets\[1\]: key "hello-world" is listed twice' "a key listed twice is refused"

# --- 2. never overwrite, never delete, generated in the cluster ---------------------------------------------------------
assert_eq "$(ps .spec.updatePolicy)" IfNotExists "an existing value is never overwritten (updatePolicy IfNotExists)"
assert_eq "$(ps .spec.deletionPolicy)" None "removing the entry or the tenant never deletes the value (deletionPolicy None)"
assert_eq "$(ss .spec.provider.vault.checkAndSet.required)" true "new keys are written with check-and-set 0"
assert_eq "$(ps '.spec.selector | to_json(0)')" \
  '{"generatorRef":{"apiVersion":"generators.external-secrets.io/v1alpha1","kind":"Password","name":"demo-demo-value"}}' \
  "value comes from the Password generator, never from a Secret or git"
assert_eq "$(ps '.spec.data[0].match.secretKey')" password "pushes the generator's key"
assert_eq "$(gen '[.spec.prefix, .spec.encoding, .spec.length] | join(" ")')" "demo-only- hex 12" \
  "format demo-only-<24 hex> (12 characters, hex-encoded)"
assert_eq "$(yq -N ea '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$R" | sort -u)" 10 \
  "every seed object in sync wave 10 (not Ready before tenant-reconcile ran)"
assert_eq "$(helm template t charts/tenant "${LOCAL[@]}" | yq -N ea '.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"' | sort -n | tail -n 1)" 10 \
  "wave 10 is the chart's final wave (a not-yet-Ready seed never holds the sync)"
assert_eq "$(kc_valid "$R")" yes "kubeconform -strict against the ESO CRD schemas"

# --- 3. contracts with addon openbao ------------------------------------------------------------------------------------
OV=addons/openbao/values.yaml
assert_eq "$(ss .spec.provider.vault.server)" "https://openbao-active.openbao.svc:8200" "server == addon openbao active service"
assert_eq "$(ss '.spec.provider.vault.auth.kubernetes.serviceAccountRef.audiences[0]')" "$(yq .reconcile.audience "$OV")" \
  "token audience == addon openbao reconcile.audience (role tenant-writer)"
assert_eq "$(ss .spec.provider.vault.auth.kubernetes.role)" tenant-writer "login role tenant-writer"
assert_eq "$(ss .spec.provider.vault.auth.kubernetes.mountPath)" kubernetes "mgmt Kubernetes auth mount"
assert_match "$(cat addons/openbao/files/policy-reconcile.sh)" 'ensure_role tenant-writer ' "policy reconciler writes role tenant-writer"
assert_match "$(cat addons/openbao/files/policies/tenant-write.hcl)" \
  'kv-tenant-\{\{identity\.entity\.metadata\.tenant\}\}/metadata/\*" \{ capabilities = \[[^]]*"create", "update"' \
  "tenant-write lets the writer set custom_metadata (ESO marks pushed keys managed-by=external-secrets)"
OR="$TMP/openbao.yaml"
helm template openbao addons/openbao --namespace openbao --set secrets.tenantStores.enabled=true \
  -s templates/tenant-secrets.yaml -s templates/ca-store.yaml > "$OR"
assert_eq "$(yq ea "select(.kind == \"ExternalSecret\" and .metadata.namespace == \"openbao-tenants\") | .spec.target.name" "$OR")" \
  "$(ss .spec.provider.vault.caProvider.name)" "addon openbao provides the CA Secret the store trusts"
assert_eq "$(ss '.spec.provider.vault.caProvider | .type + "/" + .key')" Secret/ca.crt "CA from Secret key ca.crt"
assert_match "$(yq ea 'select(.kind == "ClusterSecretStore") | .spec.conditions[0].namespaces[]' "$OR" | tr '\n' ' ')" 'openbao-tenants' \
  "ClusterSecretStore mgmt-openbao serves the writer namespace"

finish
