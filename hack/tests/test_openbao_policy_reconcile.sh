#!/usr/bin/env bash
# Policy reconciler (addon openbao files/policy-reconcile.sh, #96) against a fake `bao` CLI that keeps state in files,
# with the environment the chart renders for the CronJob. Checks: login as the self-init identity; every
# files/policies/*.hcl written as policy <name> verbatim, only when the stored text differs; drift restored; stale
# tenant-* policies pruned, other policies never touched; fail-safe on zero files; non-tenant files refused (script
# and render); the two tenant roles written with exactly the values the self-init policy pins (a mismatch = 403 and
# no tenant reconcile ever logs in); its own token revoked at the end. Also the name contracts between the addon
# values, the CronJob and self-initialisation. The same script runs against a real OpenBao in
# hack/tests/openbao_integration.sh (opt-in, docker), which also proves the 403s.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"
S="$TMP/state"; BIN="$TMP/bin"; PD="$TMP/policies"
mkdir -p "$S/policies" "$S/roles" "$BIN" "$PD"
cat > "$BIN/bao" <<'FAKE'
#!/usr/bin/env bash
# fake bao: state under $FAKE_STATE, every call appended to $FAKE_STATE/calls
set -u
S=$FAKE_STATE
printf '%s %s\n' "${BAO_TOKEN:-none}" "$*" >> "$S/calls"
case "$1 ${2:-}" in
  "write -field=token")
    [[ -e "$S/login-fails" ]] && { echo "Code: 400. * invalid role name" >&2; exit 2; }
    for a in "$@"; do [[ "$a" == role=* ]] && echo "tok-${a#role=}"; done; true ;;
  "read -field=policy") n=${3##*/}; [[ -e "$S/policies/$n" ]] || exit 2; cat "$S/policies/$n" ;;
  "policy write") cp "$4" "$S/policies/$3" ;;
  "policy delete") rm -f "$S/policies/$3" ;;
  "list sys/policies/acl") printf 'Keys\n----\n'; ls "$S/policies" ;;
  "token revoke") ;;
  write\ auth/kubernetes/role/*) r=${2##*/}; shift 2; printf '%s\n' "$@" > "$S/roles/$r" ;;
  *) echo "fake bao: unhandled $*" >&2; exit 3 ;;
esac
FAKE
chmod +x "$BIN/bao"

helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  --set secrets.tenantStores.enabled=true -s templates/policy-reconcile.yaml \
  | yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/env"
run() {
  ( set -a; while IFS= read -r l; do export "${l?}"; done < "$TMP/env"; set +a
    export POLICY_DIR="${PDIR:-$PD}" TOKEN_FILE="$TMP/token" FAKE_STATE="$S" PATH="$BIN:$PATH" TERMINATION_LOG="$TMP/termination"
    unset BAO_TOKEN
    sh addons/openbao/files/policy-reconcile.sh ) > "$TMP/out" 2>&1
}
printf 'jwt' > "$TMP/token"
cp addons/openbao/files/policies/*.hcl "$PD/"
printf 'path "x" { capabilities = ["read"] }\n' > "$S/policies/default"
printf 'path "y" { capabilities = ["read"] }\n' > "$S/policies/platform-mesh-config"

rc=0; run || rc=$?
assert_eq "$rc" 0 "policy reconcile exits 0"; [[ $rc -eq 0 ]] || cat "$TMP/out" >&2
assert_match "$(sed -n 1p "$S/calls")" '^none write -field=token auth/kubernetes/login role=platform-policy-reconciler jwt=@' "logs in as platform-policy-reconciler with the projected token"
assert_match "$(cat "$TMP/out")" 'done: policies=\[tenant-config tenant-read tenant-write\] written=\[tenant-config tenant-read tenant-write\] pruned=\[\] roles=\[tenant-config tenant-writer\]' "first run: 3 policies, 2 roles"
for f in addons/openbao/files/policies/*.hcl; do
  assert_eq "$(cat "$S/policies/$(basename "$f" .hcl)")" "$(cat "$f")" "policy $(basename "$f" .hcl) == $f (verbatim)"
done
assert_match "$(tail -n1 "$S/calls")" '^tok-platform-policy-reconciler token revoke -self' "its own token is revoked at the end"
assert_eq "$(grep -cE 'policy (write|delete) (default|platform-)' "$S/calls" || true)" 0 "non-tenant policies are never written or deleted"
assert_eq "$(grep -cE 'pki-|mesh-|kv-tenant-|identity/|sys/mounts|sys/auth|auth/tenants-' "$S/calls" || true)" 0 "nothing outside policies and the two roles is touched"

: > "$S/calls"; run
assert_match "$(cat "$TMP/out")" 'written=\[\] pruned=\[\]' "second run writes no policy (idempotent)"
assert_eq "$(grep -c 'policy write' "$S/calls" || true)" 0 "second run: no policy write call"

printf 'path "*" { capabilities = ["sudo"] }\n' > "$S/policies/tenant-read"; cp "$S/policies/tenant-read" "$S/policies/tenant-stale"
run
assert_match "$(cat "$TMP/out")" 'written=\[tenant-read\] pruned=\[tenant-stale\]' "drift restored from git, stale tenant-* policy pruned"
assert_eq "$([[ -e "$S/policies/platform-mesh-config" && -e "$S/policies/default" ]] && echo kept)" kept "non-tenant policies untouched by the prune"

# fail-safe and refusals
mkdir -p "$TMP/empty"; : > "$S/calls"
rc=0; PDIR="$TMP/empty" run || rc=$?
assert_eq "$rc" 1 "zero policy files: exit 1"
assert_eq "$(grep -cE 'policy (write|delete)' "$S/calls" || true)" 0 "zero policy files: nothing written, nothing pruned"
printf 'path "*" { capabilities = ["sudo"] }\n' > "$PD/admin.hcl"; : > "$S/calls"
rc=0; run || rc=$?
assert_eq "$rc" 1 "a non-tenant policy file: exit 1"
assert_match "$(cat "$TMP/out")" 'only tenant-\* policies' "a non-tenant policy file: refused with the reason"
assert_eq "$(grep -c 'policy write admin' "$S/calls" || true)" 0 "a non-tenant policy file is never written"
rm -f "$PD/admin.hcl"
touch "$S/login-fails"
rc=0; run || rc=$?; rm -f "$S/login-fails"
assert_eq "$rc" 1 "failed login: exit 1"
assert_match "$(cat "$TMP/termination")" 'no policy reconciler identity .*/break-glass.md#openbao-local-re-initialization' "failed login: points at the one-time re-initialisation"

# render guard: a non-tenant file in files/policies/ fails the render
C="$TMP/chart"; cp -R addons/openbao "$C"; printf 'path "*" { capabilities = ["sudo"] }\n' > "$C/files/policies/mesh-admin.hcl"
out=$(helm template openbao "$C" --namespace openbao --values installations/local/installation.yaml --set secrets.tenantStores.enabled=true -s templates/policy-reconcile.yaml 2>&1 || true)
assert_match "$out" 'files/policies/mesh-admin.hcl: the policy reconciler may only write tenant-\* policies' "render fails for a non-tenant policy file"

# the role writes == the self-init pins (allowed_parameters): a value drift here is a 403 for every run
cfg=$(helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  -s charts/openbao/templates/server-config-configmap.yaml | yq '.data["extraconfig-from-values.hcl"]')
pins() { printf '%s\n' "$cfg" | awk -v p="path \"auth/kubernetes/role/$1\" {" 'index($0, p) {f=1} f && /allowed_parameters/ {print; exit}'; }
for r in tenant-config tenant-writer; do
  line=$(pins "$r")
  assert_match "$line" 'allowed_parameters' "self-init pins the parameters of role $r"
  keys=$(printf '%s' "$line" | grep -oE '"[a-z_]+" = \[' | sed -E 's/"([a-z_]+)".*/\1/' | sort | tr '\n' ' ')
  assert_eq "$(sed 's/=.*//' "$S/roles/$r" | sort | tr '\n' ' ')" "$keys" "role $r: the reconciler sends exactly the pinned parameters"
  while IFS= read -r kv; do
    k=${kv%%=*}; v=${kv#*=}
    assert_eq "$(printf '%s' "$line" | grep -oE "\"$k\" = \[\"[^\"]*\"\]" | sed -E 's/.*\["(.*)"\]/\1/')" "$v" "role $r: $k=$v is the pinned value"
  done < "$S/roles/$r"
done
V=addons/openbao/values.yaml
assert_eq "$(yq .tenantSecrets.loginRole $V)" tenant-config "tenant-reconcile logs in with the role the policy reconciler writes"
role_field() { printf '%s\n' "$cfg" | awk -v p="auth/kubernetes/role/$1" -v k="$2" '$0 ~ "path *= \"" p "\"" {f=1} f && $1 == k {sub(/.*= /, ""); print; exit}'; }
assert_eq "$(role_field "$(yq .policyReconciler.loginRole $V)" bound_service_account_names)" "[\"$(yq .policyReconciler.serviceAccount $V)\"]" "self-init: policyReconciler.loginRole bound to policyReconciler.serviceAccount only"
assert_eq "$(role_field "$(yq .policyReconciler.loginRole $V)" bound_service_account_namespaces)" '["openbao"]' "self-init: ... in namespace openbao"
assert_eq "$(role_field "$(yq .policyReconciler.loginRole $V)" token_policies)" "[\"$(yq .policyReconciler.loginRole $V)\"]" "self-init: ... with its own policy only"
assert_eq "$(role_field "$(yq .policyReconciler.loginRole $V)" audience)" "\"$(yq .reconcile.audience $V)\"" "self-init: ... audience == reconcile.audience (projected token)"

finish
