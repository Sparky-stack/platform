#!/usr/bin/env bash
# Demo tenant secrets seed (charts/tenant templates/demo-secrets.yaml + files/seed-demo-secrets.sh): a clean bootstrap
# starts with an empty OpenBao, so every value the demo app's SecretReferences point to must be seeded with no manual step.
# Checks:
#   1. contract: every remoteRef (key, property) of the vendored hello-world SecretReferences
#      (hack/tests/fixtures/hello-world/) is in the SEEDS of the CronJob the local demo tenant renders, and the CronJob
#      runs as the tenant's own writer ServiceAccount against its own mount
#   2. name/pin contracts with addon openbao: image, BAO_ADDR, audience, login role, CA Secret (ExternalSecret in the
#      writer namespace + ClusterSecretStore condition)
#   3. the script against a fake `bao` CLI: login only as tenant-writer with the projected token; a missing value is
#      created with cas=0 (demo-only-<hex>, never printed); a re-run keeps it (idempotent, no write); a key without the
#      property is patched; nothing outside the tenant's mount; invalid seed and failed login exit non-zero
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_tenant_demo_secrets =="
cd "$ROOT"

R="$TMP/tenant.yaml"
helm template tenant-demo charts/tenant -f installations/local/installation.yaml -f installations/local/tenants/demo.yaml \
  -s templates/demo-secrets.yaml > "$R"
cj() { yq ea "select(.kind == \"CronJob\" and .metadata.name == \"demo-demo-secrets\") | $1" "$R"; }
cenv() { cj ".spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value"; }

# --- 1. every SecretReference remoteRef of the demo app is seeded -------------------------------------------------------
refs=$(yq ea 'select(.kind == "SecretReference") | .spec.data[].remoteRef | .key + "/" + .property' \
  hack/tests/fixtures/hello-world/*.yaml | sort -u)
assert_nonempty "$refs" "vendored hello-world SecretReference has remoteRefs"
seeds=" $(cenv SEEDS) "
for r in $refs; do
  assert_match "$seeds" " $r " "demo tenant seeds SecretReference remoteRef $r"
done
assert_eq "$(cenv MOUNT)" kv-tenant-demo "seed writes the tenant's own mount"
assert_eq "$(cj .metadata.namespace)" openbao-tenants "CronJob in the writer namespace"
assert_eq "$(cj .spec.jobTemplate.spec.template.spec.serviceAccountName)" demo-writer "runs as the tenant's writer ServiceAccount"
assert_eq "$(cj .spec.jobTemplate.spec.template.spec.automountServiceAccountToken)" false "no Kubernetes API token"
assert_eq "$(cj .spec.concurrencyPolicy)" Forbid "one run at a time"
assert_eq "$(yq ea 'select(.kind == "ServiceAccount" and .metadata.name == "demo-writer") | .metadata.name' \
  <(helm template t charts/tenant -f installations/local/installation.yaml -f installations/local/tenants/demo.yaml -s templates/secrets.yaml))" \
  demo-writer "writer ServiceAccount rendered by the same chart"
n=$(helm template t charts/tenant -f installations/local/installation.yaml --set project=demo -s templates/demo-secrets.yaml 2>/dev/null | grep -c '^kind:' || true)
assert_eq "$n" 0 "no demoSecrets -> no seed CronJob"
n=$(helm template t charts/tenant -f installations/local/tenants/demo.yaml -s templates/demo-secrets.yaml 2>/dev/null | grep -c '^kind:' || true)
assert_eq "$n" 0 "tenantStores off -> no seed CronJob"
if helm template t charts/tenant -f installations/local/installation.yaml -f installations/local/tenants/demo.yaml \
    --set 'demoSecrets[0].key=a/b' --set 'demoSecrets[0].property=x' -s templates/demo-secrets.yaml >/dev/null 2>&1; then
  assert_eq rendered fails "demoSecrets key with a slash is refused"
else assert_eq ok ok "demoSecrets key with a slash is refused"; fi

# --- 2. contracts with addon openbao ------------------------------------------------------------------------------------
OV=addons/openbao/values.yaml
oimg=$(yq '.openbao.server.image | .registry + "/" + .repository + ":" + .tag' "$OV")
assert_eq "$(cj '.spec.jobTemplate.spec.template.spec.containers[0].image')" "$oimg" "seed image == addon openbao server image (bao CLI pin)"
assert_eq "$(cenv BAO_ADDR)" "https://openbao-active.openbao.svc:8200" "BAO_ADDR == addon openbao active service"
assert_eq "$(cj '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "token") | .projected.sources[0].serviceAccountToken.audience')" \
  "$(yq .reconcile.audience "$OV")" "token audience == addon openbao reconcile.audience (role tenant-writer)"
assert_eq "$(cenv LOGIN_ROLE)" tenant-writer "login role tenant-writer"
assert_match "$(cat addons/openbao/files/policy-reconcile.sh)" 'ensure_role tenant-writer ' "policy reconciler writes role tenant-writer"
OR="$TMP/openbao.yaml"
helm template openbao addons/openbao --namespace openbao --set secrets.tenantStores.enabled=true \
  -s templates/tenant-secrets.yaml -s templates/ca-store.yaml > "$OR"
ca=$(cj '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "tls-ca") | .secret.secretName')
assert_eq "$(yq ea "select(.kind == \"ExternalSecret\" and .metadata.namespace == \"openbao-tenants\") | .spec.target.name" "$OR")" "$ca" \
  "addon openbao provides the CA Secret the seed mounts"
assert_match "$(yq ea 'select(.kind == "ClusterSecretStore") | .spec.conditions[0].namespaces[]' "$OR" | tr '\n' ' ')" 'openbao-tenants' \
  "ClusterSecretStore mgmt-openbao serves the writer namespace"

# --- 3. the script against a fake bao -----------------------------------------------------------------------------------
S="$TMP/state"; BIN="$TMP/bin"; mkdir -p "$S/kv" "$BIN"
cat > "$BIN/bao" <<'FAKE'
#!/usr/bin/env bash
# fake bao: kv state in $FAKE_STATE/kv/<mount>__<key>/<property>; every call appended to $FAKE_STATE/calls
set -u
S=$FAKE_STATE
printf '%s %s\n' "${BAO_TOKEN:-none}" "$*" >> "$S/calls"
case "$1 ${2:-}" in
  "write -field=token")
    [[ -e "$S/login-fails" ]] && { echo "Code: 403" >&2; exit 2; }
    [[ "$*" == *"jwt=projected-sa-token"* ]] || exit 2
    for a in "$@"; do [[ "$a" == role=* ]] && echo "tok-${a#role=}"; done; true ;;
  "token revoke") ;;
  "kv get"|"kv metadata"|"kv put"|"kv patch")
    sub=$2; shift 2; [[ "$sub" == metadata ]] && { sub="metadata-$1"; shift; }
    mount="" field="" cas=""
    while [[ "$1" == -* ]]; do
      case "$1" in -mount=*) mount=${1#-mount=} ;; -field=*) field=${1#-field=} ;; -cas=*) cas=${1#-cas=} ;; esac; shift
    done
    d="$S/kv/${mount}__$1"
    case "$sub" in
      get) [[ -e "$d/$field" ]] && cat "$d/$field" ;;
      metadata-get) [[ -d "$d" ]] ;;
      put)
        [[ "$cas" == 0 && -d "$d" ]] && { echo "check-and-set parameter did not match" >&2; exit 2; }
        rm -rf "$d"; mkdir -p "$d"; p=${2%%=*}; v=${2#*=}; [[ "$v" == - ]] && v=$(cat); printf '%s' "$v" > "$d/$p" ;;
      patch)
        [[ -d "$d" ]] || exit 2; p=${2%%=*}; v=${2#*=}; [[ "$v" == - ]] && v=$(cat); printf '%s' "$v" > "$d/$p" ;;
      *) exit 2 ;;
    esac ;;
  *) echo "unexpected: $*" >&2; exit 2 ;;
esac
FAKE
chmod +x "$BIN/bao"
printf 'projected-sa-token' > "$TMP/token"
run() {
  env PATH="$BIN:$PATH" FAKE_STATE="$S" TOKEN_FILE="$TMP/token" LOGIN_ROLE="$(cenv LOGIN_ROLE)" MOUNT="$(cenv MOUNT)" \
    SEEDS="${SEEDS_OVERRIDE:-$(cenv SEEDS)}" sh charts/tenant/files/seed-demo-secrets.sh > "$S/out" 2>&1
}

rc=0; run || rc=$?
assert_eq "$rc" 0 "first run on an empty mount succeeds"
v=$(cat "$S/kv/kv-tenant-demo__hello-world/greeting" 2>/dev/null || true)
assert_match "$v" '^demo-only-[0-9a-f]{24}$' "generated demo-only value written to kv-tenant-demo/hello-world greeting"
assert_match "$(cat "$S/calls")" 'tok-tenant-writer kv put -mount=kv-tenant-demo -cas=0 hello-world greeting=-' "new key written with cas=0, value on stdin"
assert_eq "$(grep -c -- "$v" "$S/out" "$S/calls" | awk -F: '{s+=$2} END {print s}')" 0 "the value is never printed or passed as an argument"
assert_match "$(cat "$S/out")" 'seeded=\[hello-world/greeting\] kept=\[\]' "status: seeded"
assert_eq "$(awk '$1 != "tok-tenant-writer" && $2 != "write"' "$S/calls")" "" "every call after login uses the writer's token (never root)"
assert_eq "$(grep -c 'role=tenant-writer' "$S/calls")" 1 "logs in as role tenant-writer"
assert_eq "$(grep -vE 'auth/kubernetes/login|token revoke|-mount=kv-tenant-demo ' "$S/calls" || true)" "" "nothing outside kv-tenant-demo"

: > "$S/calls"; rc=0; run || rc=$?
assert_eq "$rc" 0 "re-run succeeds"
assert_eq "$(cat "$S/kv/kv-tenant-demo__hello-world/greeting")" "$v" "re-run keeps the existing value"
assert_eq "$(grep -cE 'kv (put|patch)' "$S/calls" || true)" 0 "re-run writes nothing (idempotent)"
assert_match "$(cat "$S/out")" 'seeded=\[\] kept=\[hello-world/greeting\]' "status: kept"

rm -rf "$S/kv"/*; mkdir -p "$S/kv/kv-tenant-demo__hello-world"; printf other > "$S/kv/kv-tenant-demo__hello-world/other"
: > "$S/calls"; rc=0; run || rc=$?
assert_eq "$rc" 0 "key without the property: succeeds"
assert_match "$(cat "$S/calls")" 'kv patch -mount=kv-tenant-demo hello-world greeting=-' "key without the property is patched"
assert_eq "$(cat "$S/kv/kv-tenant-demo__hello-world/other")" other "other properties of the key are kept"

rc=0; SEEDS_OVERRIDE="nokey" run || rc=$?
assert_eq "$rc" 1 "invalid seed exits 1"
touch "$S/login-fails"; rc=0; run || rc=$?
assert_eq "$rc" 1 "failed login exits 1 (retried next schedule)"
assert_eq "$(grep -cE 'kv ' <(tail -n 2 "$S/calls") || true)" 0 "no kv call without a token"

finish
