#!/usr/bin/env bash
# Per-tenant secrets reconcile (addon openbao files/tenant-reconcile.sh, #96) against a fake `bao` CLI that keeps state
# in files, with the environment the chart renders for the CronJob. Checks: no ACL policy, Kubernetes auth role, mesh
# object or secret value is ever touched; per tenant a kv v2 mount, an entity carrying only metadata tenant=<t> and the
# writer alias; per member cluster a JWT mount whose role <t> binds exactly the tenant's namespaces' ServiceAccount
# (alias bound before the role), audience and policy tenant-read; contested namespaces bound to nobody; invalid and
# rejected inputs; prune (roles + entity, never the data mount; departed clusters) and its fail-safe; exit codes.
# The same script runs against a real OpenBao in hack/tests/openbao_integration.sh (opt-in, docker). Also the name
# contracts between addon openbao, addon secret-stores, charts/tenant and the policies in files/policies/.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"
S="$TMP/state"; BIN="$TMP/bin"; IN="$TMP/inputs"
mkdir -p "$S/mounts" "$S/auth" "$S/writes" "$S/entities" "$S/roles" "$BIN" "$IN/tenants" "$IN/clusters"
cat > "$BIN/bao" <<'FAKE'
#!/usr/bin/env bash
# fake bao: state under $FAKE_STATE, every call appended to $FAKE_STATE/calls
set -u
S=$FAKE_STATE
printf '%s %s\n' "${BAO_TOKEN:-none}" "$*" >> "$S/calls"
enc() { printf '%s' "$1" | tr '/' '_'; }
field=""
args=("$@")
cmd=${args[0]}; args=("${args[@]:1}")
if [[ "$cmd" =~ ^(read|write)$ && "${args[0]:-}" == -field=* ]]; then field=${args[0]#-field=}; args=("${args[@]:1}"); fi
case "$cmd" in
  read)
    p=${args[0]}
    case "$p" in
      sys/mounts/*) [[ -e "$S/mounts/$(enc "${p#sys/mounts/}")" ]] ;;
      sys/auth/*) [[ -e "$S/auth/$(enc "${p#sys/auth/}")" ]] && { [[ -z "$field" ]] || echo "acc_${p#sys/auth/}"; } ;;
      identity/entity/name/*) [[ -e "$S/entities/${p##*/}" ]] && echo "id-${p##*/}" ;;
      *) exit 2 ;;
    esac ;;
  write)
    p=${args[0]}; rest=("${args[@]:1}")
    if [[ "$p" == auth/*/config && "${rest[*]}" == *unreachable* ]]; then
      echo "Error writing data to $p: Code: 400. * error checking jwks URL" >&2; exit 2
    fi
    if [[ "${rest[*]:-}" == "-" ]]; then cat > "$S/writes/$(enc "$p")"; else printf '%s\n' "${rest[@]}" > "$S/writes/$(enc "$p")"; fi
    case "$p" in
      auth/kubernetes/login) for a in "${rest[@]}"; do [[ "$a" == role=* ]] && echo "tok-${a#role=}"; done; true ;;
      identity/entity/name/*) touch "$S/entities/${p##*/}" ;;
      identity/entity-alias)
        an=""; ac=""; aa=""
        for a in "${rest[@]}"; do case "$a" in name=*) an=${a#name=} ;; canonical_id=*) ac=${a#canonical_id=} ;; mount_accessor=*) aa=${a#mount_accessor=} ;; esac; done
        # OpenBao: an entity has at most ONE alias per auth mount; an existing alias (name, mount) moves to the new entity
        if awk -v n="$an" -v c="$ac" -v a="$aa" '$2 == a && $3 == c && $1 != n {f=1} END {exit !f}' "$S/aliasmap" 2>/dev/null; then
          echo "Error writing data to identity/entity-alias: Code: 400. * Alias already exists for requested entity and mount accessor" >&2; exit 2
        fi
        { awk -v n="$an" -v a="$aa" '!($1 == n && $2 == a)' "$S/aliasmap" 2>/dev/null; printf '%s %s %s\n' "$an" "$aa" "$ac"; } > "$S/aliasmap.new"
        mv "$S/aliasmap.new" "$S/aliasmap"
        cat "$S/writes/identity_entity-alias" >> "$S/aliases"; echo >> "$S/aliases" ;;
      auth/*/role/*) cp "$S/writes/$(enc "$p")" "$S/roles/$(enc "$p")" ;;
    esac ;;
  delete)
    p=${args[0]}
    case "$p" in
      identity/entity/name/*) rm -f "$S/entities/${p##*/}"; awk -v c="id-${p##*/}" '$3 != c' "$S/aliasmap" > "$S/aliasmap.new" 2>/dev/null; mv "$S/aliasmap.new" "$S/aliasmap" ;;
      auth/*/role/*) rm -f "$S/roles/$(enc "$p")" ;;
      *) exit 2 ;;
    esac ;;
  list)
    p=${args[0]}
    if [[ "$p" == identity/entity/name ]]; then
      found=$(cd "$S/entities" && ls 2>/dev/null)
      [[ -n "$found" ]] || { echo "No value found at $p" >&2; exit 2; }
      printf 'Keys\n----\n%s\n' "$found"; exit 0
    fi
    m=${p#auth/}; m=${m%/role}
    found=$(cd "$S/roles" && ls "auth_${m}_role_"* 2>/dev/null | sed "s/^auth_${m}_role_//")
    [[ -n "$found" ]] || { echo "No value found at $p" >&2; exit 2; }
    printf 'Keys\n----\n%s\n' "$found" ;;
  secrets)
    sub=${args[0]}
    case "$sub" in
      enable) for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/mounts/$(enc "${a#-path=}")"; done; true ;;
      *) echo "fake bao: secrets $sub" >&2; exit 3 ;;
    esac ;;
  auth)
    sub=${args[0]}
    case "$sub" in
      enable) for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/auth/$(enc "${a#-path=}")"; done; true ;;
      disable) rm -f "$S/auth/$(enc "${args[1]}")" ;;
      list) printf 'Path Type Accessor Description\n---- ---- -------- -----------\nkubernetes/ kubernetes auth_kubernetes_a1 n/a\ntoken/ token auth_token_a2 n/a\n'
            for f in "$S"/auth/*; do [[ -e "$f" ]] && printf '%s/ jwt acc_%s n/a\n' "$(basename "$f")" "$(basename "$f")"; done; true ;;
    esac ;;
  policy) echo "fake bao: policy $*" >&2; exit 3 ;;
  *) echo "fake bao: unhandled $*" >&2; exit 3 ;;
esac
FAKE
chmod +x "$BIN/bao"

helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  --set secrets.tenantStores.enabled=true -s templates/tenant-secrets.yaml \
  | yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/env"
run() {
  ( set -a; while IFS= read -r l; do export "${l?}"; done < "$TMP/env"; set +a
    export INPUT_DIR="$IN" TOKEN_FILE="$TMP/token" FAKE_STATE="$S" PATH="$BIN:$PATH" TERMINATION_LOG="$TMP/termination"
    unset BAO_TOKEN
    sh addons/openbao/files/tenant-reconcile.sh ) > "$TMP/out" 2>&1
}
ents() { (cd "$S/entities" && printf '%s\n' *); }
wr() { cat "$S/writes/$(printf '%s' "$1" | tr '/' '_')" 2>/dev/null; }
tenant() { printf '%s' "$2" > "$IN/tenants/$1.namespaces"; }
cluster() { printf 'local' > "$IN/clusters/$1.group"; printf '%s' "${2:-https://172.18.0.9:6443}" > "$IN/clusters/$1.server"; printf -- '-----BEGIN CERTIFICATE-----\n' > "$IN/clusters/$1.ca"; }
printf 'jwt' > "$TMP/token"

D1=dp-default-demo-development-ad621210; D2=dp-default-demo-staging-ba410b48; O1=dp-default-other-development-0badc0de
D3=dp-default-demo-production-7cbe998d
tenant demo "$D1 $D2 $D3"; tenant other "$O1"; tenant rogue "$D2 dp-default-rogue-development-12345678"
tenant Bad_Name "dp-x"; tenant empty ""; printf 'tenant "demo" does not match' > "$IN/tenants/rejected.evil-openbao-tenant"
cluster dev1; cluster prod1
rc=0; run || rc=$?
assert_eq "$rc" 0 "tenant reconcile exits 0"; [[ $rc -eq 0 ]] || cat "$TMP/out" >&2
assert_match "$(sed -n 1p "$S/calls")" '^none write -field=token auth/kubernetes/login role=tenant-config jwt=@' "logs in as tenant-config with the projected token"
assert_match "$(cat "$TMP/out")" 'done: tenants=\[demo other rogue\] failed=\[\] invalid=\[evil-openbao-tenant Bad_Name empty\] clusters=\[dev1 prod1\]' "summary: valid tenants, invalid inputs, clusters"

# never: policies, Kubernetes auth roles, mesh objects, secret values, data mount deletion
assert_eq "$(grep -cE '(^| )policy ' "$S/calls" || true)" 0 "no ACL policy is written, deleted or listed"
assert_eq "$(grep -c 'auth/kubernetes/role' "$S/calls" || true)" 0 "no Kubernetes auth role is written (the policy reconciler owns tenant-writer)"
assert_eq "$(grep -cE 'mesh-|pki-' "$S/calls" || true)" 0 "nothing of the mesh CA is touched"
assert_eq "$(grep -cE 'kv-tenant-[a-z-]+/(data|metadata)' "$S/calls" || true)" 0 "no secret value is read or written"
# per tenant: kv v2 mount, entity with metadata only, writer alias on the Kubernetes mount
assert_match "$(cat "$S/calls")" 'tok-tenant-config secrets enable -path=kv-tenant-demo -version=2 ' "demo: kv v2 mount kv-tenant-demo"
assert_eq "$(wr identity/entity/name/tenant-demo | tr '\n' ' ')" "metadata=tenant=demo " "demo entity: metadata tenant=demo, no policies"
assert_match "$(tr '\n' ' ' < "$S/aliases")" 'name=openbao-tenants/demo-writer canonical_id=id-tenant-demo mount_accessor=auth_kubernetes_a1' "demo writer alias: openbao-tenants/demo-writer on the Kubernetes mount"
# per cluster: JWT mount with the member's JWKS; per tenant aliases before the role; role binds exactly its namespaces
assert_eq "$(wr auth/tenants-dev1/config | tr '\n' ' ')" "jwks_url=https://172.18.0.9:6443/openid/v1/jwks jwks_ca_pem=@$IN/clusters/dev1.ca " "dev1: its API server's JWKS, pinned to its cluster CA"
role=$(cat "$S/roles/auth_tenants-dev1_role_demo")
assert_eq "$(printf '%s' "$role" | yq -p json -o json -I0 '.bound_claims')" "{\"sub\":[\"system:serviceaccount:$D1:openbao-tenant\",\"system:serviceaccount:$D3:openbao-tenant\"]}" "demo role: only demo's uncontested namespaces' openbao-tenant ServiceAccounts"
assert_eq "$(printf '%s' "$role" | yq -p json -r '[.role_type, .user_claim, .bound_claims_type, (.bound_audiences | join(",")), .token_policies, .token_no_default_policy, .token_ttl] | join(" ")')" \
  "jwt sub string openbao-tenant-secrets tenant-read true 10m" "demo role: JWT, audience openbao-tenant-secrets, policy tenant-read only, 10m"
assert_eq "$(yq -p json -o json -I0 '.bound_claims' < "$S/roles/auth_tenants-dev1_role_rogue")" '{"sub":["system:serviceaccount:dp-default-rogue-development-12345678:openbao-tenant"]}' "rogue role: never the namespace it contests"
assert_match "$(cat "$TMP/out")" "namespace $D2 is claimed by several tenants: bound to none" "contested namespace reported"
assert_eq "$(grep -c "$D2" "$S/aliases" || true)" 0 "contested namespace: no alias for anybody"
alias_line=$(grep -n "entity-alias name=system:serviceaccount:$D3:openbao-tenant canonical_id=id-tenant-demo.dev1.$D3 mount_accessor=acc_tenants-dev1" "$S/calls" | head -1 | cut -d: -f1)
role_line=$(grep -n 'write auth/tenants-dev1/role/demo' "$S/calls" | head -1 | cut -d: -f1)
assert_eq "$(( ${alias_line:-999} < ${role_line:-0} ))" 1 "dev1: demo's aliases bound (to entity tenant-demo.dev1.<ns>) before its role exists"
assert_eq "$(wr "identity/entity/name/tenant-demo.dev1.$D1" | tr '\n' ' ')" "metadata=tenant=demo " "namespace entity: metadata tenant=demo only (what tenant-read keys on)"
assert_eq "$(awk -v a=acc_tenants-dev1 '$2 == a && $3 ~ /^id-tenant-demo/' "$S/aliasmap" | wc -l | tr -d ' ')" 2 "two demo namespaces on one mount: two aliases, one entity each (OpenBao: one alias per entity and mount)"
assert_eq "$([[ -e "$S/roles/auth_tenants-prod1_role_other" ]] && echo yes)" yes "every member cluster gets every tenant's role"
assert_eq "$(ents | grep -cvE '^tenant-(demo|other|rogue)(\.(dev1|prod1)\.dp-default-[a-z]+-[a-z]+-[0-9a-f]{8})?$' || true)" 0 "invalid inputs get no entity"
assert_eq "$(ents | grep -c "$D2" || true)" 0 "contested namespace: no entity"

# idempotent
: > "$S/calls"; rc=0; run || rc=$?
assert_eq "$rc" 0 "second run exits 0 (aliases rewritten as they are)"
assert_eq "$(grep -cE 'secrets enable|auth enable|delete' "$S/calls" || true)" 0 "second run: no new mounts, nothing pruned"
# a namespace leaves demo: its entity (and with it the alias) goes, the other namespaces stay
tenant demo "$D1 $D2"
: > "$S/calls"; run
assert_match "$(cat "$TMP/out")" "prune entity tenant-demo.dev1.$D3 \\(no longer bound\\)" "namespace left: its entity is pruned"
assert_eq "$([[ -e "$S/entities/tenant-demo.dev1.$D3" ]] && echo kept || echo pruned)" pruned "namespace left: entity tenant-demo.dev1.<ns> deleted"
assert_eq "$([[ -e "$S/entities/tenant-demo.dev1.$D1" ]] && echo kept || echo pruned)" kept "namespace left: demo's other namespace kept"
tenant demo "$D1 $D2 $D3"

# prune: a departed tenant loses role + entity (data mount kept); a departed cluster loses its JWT mount
rm -f "$IN/tenants/other.namespaces" "$IN"/clusters/prod1.*
: > "$S/calls"; run
assert_eq "$([[ -e "$S/roles/auth_tenants-dev1_role_other" ]] && echo kept || echo pruned)" pruned "departed tenant: role pruned"
assert_eq "$([[ -e "$S/entities/tenant-other" ]] && echo kept || echo pruned)" pruned "departed tenant: entity (and its aliases) deleted"
assert_eq "$(ents | grep -c '^tenant-other\.' || true)" 0 "departed tenant: its namespace entities deleted"
assert_eq "$(ents | grep -c '\.prod1\.' || true)" 0 "departed cluster: its namespace entities deleted"
assert_eq "$(grep -c 'secrets disable' "$S/calls" || true)" 0 "departed tenant: its data mount is never deleted"
assert_eq "$([[ -e "$S/auth/tenants-prod1" ]] && echo kept || echo pruned)" pruned "departed cluster: tenants-prod1 disabled"
assert_eq "$([[ -e "$S/roles/auth_tenants-dev1_role_demo" ]] && echo kept || echo pruned)" kept "remaining tenant untouched"

# per-cluster fail-safe: unreachable cluster reported, the others configured; every cluster failing fails the run
cluster down1 https://unreachable.test:6443
rc=0; run || rc=$?
assert_eq "$rc" 0 "one unreachable cluster: exit 0"
assert_match "$(cat "$TMP/out")" 'clusters=\[dev1\] failed-clusters=\[down1\]' "unreachable cluster reported"
rm -f "$IN"/clusters/dev1.*
rc=0; run || rc=$?
assert_eq "$rc" 1 "every cluster unreachable: exit 1 (CronJob fails visibly)"
assert_match "$(cat "$TMP/termination")" '^ERROR: no member cluster could be configured' "termination message names it"
assert_eq "$([[ -e "$S/auth/tenants-dev1" ]] && echo kept || echo pruned)" pruned "a cluster that left is pruned even then"
# empty tenant list: nothing pruned (an ESO outage must not cut every tenant off); only invalid inputs: failure
rm -f "$IN"/tenants/*; cluster dev1; : > "$S/calls"
rc=0; run || rc=$?
assert_eq "$rc" 0 "no tenant inputs: exit 0"
assert_match "$(cat "$TMP/out")" 'no tenant inputs: nothing configured, nothing pruned' "no tenant inputs: fail-safe message"
assert_eq "$(grep -cE 'delete|disable' "$S/calls" || true)" 0 "no tenant inputs: nothing deleted"
tenant Bad_Name x
rc=0; run || rc=$?
assert_eq "$rc" 1 "only invalid tenant inputs: exit 1"

# name contracts across charts (a mismatch silently breaks every tenant login or the descriptor discovery)
V=addons/openbao/values.yaml; SS=addons/secret-stores/values.yaml; TV=charts/tenant/values.yaml
assert_eq "$(yq .tenantSecrets.readerServiceAccount $V)" "$(yq .tenantStores.serviceAccount $SS)" "reader ServiceAccount: addon openbao == addon secret-stores"
assert_eq "$(yq .tenantSecrets.audience $V)" "$(yq .tenantStores.audience $SS)" "token audience: addon openbao == addon secret-stores"
assert_eq "$(yq .tenantSecrets.inputsNamespace $V)" "$(yq .tenantSecrets.namespace $TV)" "descriptor namespace: addon openbao == charts/tenant"
assert_eq "$(yq .tenantSecrets.label $V)" "$(yq .tenantSecrets.label $TV)" "descriptor label: addon openbao == charts/tenant"
assert_eq "$(yq .tenantStoreName addons/openchoreo-platform/values.yaml)" "$(yq .tenantStores.storeName $SS)" "store name: component types == generated SecretStore"
assert_eq "$([[ -f addons/openbao/files/policies/$(yq .tenantSecrets.readerPolicy $V).hcl ]] && echo yes)" yes "tenantSecrets.readerPolicy has its file in files/policies/ (written by the policy reconciler)"
# login role / ServiceAccount of this CronJob == the role the policy reconciler writes (test_openbao_policy_reconcile.sh)

finish
