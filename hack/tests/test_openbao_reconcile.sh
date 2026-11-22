#!/usr/bin/env bash
# Mesh PKI reconcile (addon openbao files/mesh-reconcile.sh) against a fake `bao` CLI that keeps state in files: what
# OpenBao is told to do per group and per member, with the environment the chart renders for the Job and the CronJob.
# Checks: no ACL policy is ever written (static templated policy mesh-member + entity metadata cluster/group give the
# per-cluster scope), group CAs only with the bootstrap token (Job), the SPIFFE-only PKI role, audience/subject-bound
# JWT auth, internal (never exported) CA keys, input validation, prune + fail-safe, Sync-hook Job vs CronJob exit codes.
# The same script runs against a real OpenBao in hack/tests/openbao_integration.sh (opt-in, docker).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"
S="$TMP/state"; BIN="$TMP/bin"; IN="$TMP/inputs"
mkdir -p "$S/mounts" "$S/certs" "$S/auth" "$S/policies" "$S/roles" "$S/writes" "$S/entities" "$BIN" "$IN"
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
      sys/auth/*) [[ -e "$S/auth/$(enc "${p#sys/auth/}")" ]] && { [[ -z "$field" ]] || echo "auth_jwt_${p#sys/auth/}"; } ;;
      identity/entity/name/*) [[ -e "$S/entities/${p##*/}" ]] && echo "id-${p##*/}" ;;
      */cert/ca) m=${p%/cert/ca}; [[ -e "$S/certs/$(enc "$m")" ]] && echo "-----BEGIN CERTIFICATE----- $m" ;;
      *) exit 2 ;;
    esac ;;
  write)
    p=${args[0]}; rest=("${args[@]:1}")
    # a member whose JWKS OpenBao cannot fetch (API server down / issuer discovery not public): the config write fails
    if [[ "$p" == auth/*/config && "${rest[*]}" == *unreachable* ]]; then
      echo "Error writing data to $p: Code: 400. * error checking jwks URL: 403 system:anonymous" >&2; exit 2
    fi
    printf '%s\n' "${rest[@]}" > "$S/writes/$(enc "$p")"
    case "$p" in
      auth/kubernetes/login) for a in "${rest[@]}"; do [[ "$a" == role=* ]] && echo "tok-${a#role=}"; done; true ;;
      identity/entity/name/*) touch "$S/entities/${p##*/}" ;;
      */root/generate/internal) touch "$S/certs/$(enc "${p%/root/generate/internal}")" ;;
      */intermediate/generate/internal) echo "-----BEGIN CERTIFICATE REQUEST-----" ;;
      */root/sign-intermediate) echo "-----BEGIN CERTIFICATE----- int" ;;
      */intermediate/set-signed) touch "$S/certs/$(enc "${p%/intermediate/set-signed}")" ;;
      */roles/*) cp "$S/writes/$(enc "$p")" "$S/roles/$(enc "$p")" ;;
    esac ;;
  delete) case "${args[0]}" in identity/entity/name/*) rm -f "$S/entities/${args[0]##*/}" ;; *) exit 2 ;; esac ;;
  secrets)
    sub=${args[0]}
    if [[ "$sub" == enable ]]; then for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/mounts/$(enc "${a#-path=}")"; done; fi
    exit 0 ;;
  auth)
    sub=${args[0]}
    case "$sub" in
      enable) for a in "${args[@]}"; do [[ "$a" == -path=* ]] && touch "$S/auth/$(enc "${a#-path=}")"; done; exit 0 ;;
      disable) rm -f "$S/auth/$(enc "${args[1]}")" ;;
      list) printf 'Path Type Accessor\n---- ---- --------\nkubernetes/ kubernetes a1\ntoken/ token a2\n'
            for f in "$S"/auth/*; do [[ -e "$f" ]] && printf '%s/ jwt x\n' "$(basename "$f")"; done; exit 0 ;;
    esac ;;
  policy)
    sub=${args[0]}
    case "$sub" in
      write) cat > "$S/policies/${args[1]}" ;;
      delete) rm -f "$S/policies/${args[1]}" ;;
      list) printf 'default\nroot\nplatform-mesh-config\n'; ls "$S/policies" ;;
    esac ;;
  list) exit 2 ;;
  *) echo "fake bao: unhandled $*" >&2; exit 3 ;;
esac
FAKE
chmod +x "$BIN/bao"

# Environment exactly as the chart renders it for the Job and the CronJob (groups local + prod).
render_env() {
  helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
    --set 'mesh.groups={local,prod}' -s templates/reconcile.yaml \
    | yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/env"
  helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
    --set 'mesh.groups={local,prod}' -s templates/reconcile.yaml \
    | yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/cronenv"
}
render_env
member() {   # member <name> <group> [server] [ca]
  printf '%s' "$2" > "$IN/$1.group"
  printf '%s' "${3:-https://172.18.0.9:6443}" > "$IN/$1.server"
  printf '%s\n' "${4:------BEGIN CERTIFICATE-----}" > "$IN/$1.ca"
}
run() {   # run [env file]: the Job (default) or the CronJob environment
  ( set -a; while IFS= read -r l; do export "${l?}"; done < "${1:-$TMP/env}"; set +a
    export INPUT_DIR="$IN" TOKEN_FILE="$TMP/token" FAKE_STATE="$S" PATH="$BIN:$PATH" TERMINATION_LOG="$TMP/termination"
    unset BAO_TOKEN BAO_BOOTSTRAP_TOKEN
    sh addons/openbao/files/mesh-reconcile.sh ) > "$TMP/out" 2>&1
}
wr() { cat "$S/writes/$(printf '%s' "$1" | tr '/' '_')" 2>/dev/null; }

member dev1 local
member prod1 prod
member Bad_Name local
member ghost nogroup
member plain local http://172.18.0.9:6443
member noca local https://172.18.0.9:6443 "not a cert"
printf 'jwt' > "$TMP/token"
rc=0; run || rc=$?
assert_eq "$rc" 0 "reconcile exits 0"; [[ $rc -eq 0 ]] || cat "$TMP/out" >&2

# login: Kubernetes auth with the projected token, scoped roles (never a root token): bootstrap first, then members
assert_match "$(sed -n 1p "$S/calls")" '^none write -field=token auth/kubernetes/login role=platform-mesh-bootstrap jwt=@' "Job: logs in as platform-mesh-bootstrap with the projected token"
assert_eq "$(grep -c 'auth/kubernetes/login role=platform-mesh-config jwt=@' "$S/calls")" 1 "Job: then as platform-mesh-config"
# groups: internal keys only, with the bootstrap token only
for g in local prod; do
  assert_match "$(cat "$S/calls")" "tok-platform-mesh-bootstrap write pki-mesh-$g-root/root/generate/internal " "group $g: root key generated inside OpenBao (bootstrap token)"
  assert_match "$(cat "$S/calls")" "tok-platform-mesh-bootstrap write -field=csr pki-mesh-$g-int/intermediate/generate/internal " "group $g: intermediate key generated inside OpenBao (bootstrap token)"
done
assert_eq "$(grep '^tok-platform-mesh-bootstrap' "$S/calls" | grep -cE 'identity|auth |auth/mesh|/roles/' || true)" 0 "the bootstrap token enrols no member"
assert_eq "$(grep '^tok-platform-mesh-config' "$S/calls" | grep -cE '/generate/|sign-intermediate|set-signed|secrets ' || true)" 0 "the member token touches no CA"
assert_eq "$(grep -cE '(^| )policy ' "$S/calls" || true)" 0 "the reconcile writes, deletes or lists no ACL policy"
assert_eq "$(grep -c 'auth/kubernetes/role' "$S/calls" || true)" 0 "the reconcile writes no Kubernetes auth role (mesh-ca-read is static)"
assert_eq "$(grep -cE 'generate/exported|generate/existing|private_key|config/ca|/import' "$S/calls" || true)" 0 "no CA key is ever exported or imported"
assert_match "$(wr pki-mesh-local-root/root/sign-intermediate)" 'max_path_length=0' "intermediates cannot sign further CAs"

# per-cluster scope: entity mesh-<c> carries cluster + group (the static templated policy keys on them), and the auth
# mount's alias for the member ServiceAccount is bound to it before the role exists
assert_eq "$(wr identity/entity/name/mesh-dev1 | tr '\n' ' ')" "metadata=cluster=dev1 metadata=group=local " "dev1 entity: cluster=dev1, group=local, no policies"
assert_eq "$(wr identity/entity/name/mesh-prod1 | tr '\n' ' ')" "metadata=cluster=prod1 metadata=group=prod " "prod1 entity: its own group"
assert_match "$(grep -n '' "$S/calls" | grep -E 'identity/entity-alias name=system:serviceaccount:istio-system:istio-csr-openbao canonical_id=id-mesh-dev1 mount_accessor=auth_jwt_mesh-dev1' | cut -d: -f1)" '^[0-9]+$' "dev1 alias: the member ServiceAccount on auth/mesh-dev1 -> entity mesh-dev1"
alias_line=$(grep -n 'entity-alias.*mesh-dev1' "$S/calls" | cut -d: -f1); role_line=$(grep -m1 -n 'auth/mesh-dev1/role/' "$S/calls" | cut -d: -f1)
assert_eq "$(( alias_line < role_line ))" 1 "dev1: alias bound before the login role exists (no auto-created entity)"
# PKI role: SPIFFE IDs of the trust domain + the two serving names, short TTLs
role=$(cat "$S/roles/pki-mesh-local-int_roles_dev1")
for kv in 'allowed_uri_sans=spiffe://cluster.local/ns/*/sa/*' allow_any_name=false allow_ip_sans=false allow_localhost=false \
  allow_subdomains=false allow_glob_domains=false allow_wildcard_certificates=false enforce_hostnames=true \
  'allowed_domains=istiod.istio-system.svc,cert-manager-istio-csr.istio-system.svc' allow_bare_domains=true \
  ttl=24h max_ttl=48h no_store=true allowed_other_sans= code_signing_flag=false; do
  assert_eq "$(printf '%s\n' "$role" | grep -cxF -- "$kv")" 1 "dev1 PKI role: $kv"
done
# JWT auth: this cluster's own JWKS, pinned CA, fixed subject + audience, short batch tokens with only its policy
assert_eq "$(wr auth/mesh-dev1/config | tr '\n' ' ')" "jwks_url=https://172.18.0.9:6443/openid/v1/jwks jwks_ca_pem=@$IN/dev1.ca " "dev1 auth: its API server's JWKS, pinned to its cluster CA"
arole=$(wr auth/mesh-dev1/role/istio-csr)
for kv in role_type=jwt user_claim=sub bound_subject=system:serviceaccount:istio-system:istio-csr-openbao \
  bound_audiences=vault://istio-system/openbao-mesh token_policies=mesh-member token_no_default_policy=true \
  token_type=batch token_ttl=10m token_max_ttl=10m; do
  assert_eq "$(printf '%s\n' "$arole" | grep -cxF -- "$kv")" 1 "dev1 auth role: $kv"
done
# invalid inputs never get an auth mount
for bad in Bad_Name ghost plain noca; do
  assert_eq "$([[ -e "$S/auth/mesh-$bad" ]] && echo mounted || echo skipped)" skipped "negative: input '$bad' skipped"
done
assert_eq "$(cd "$S/auth" && printf '%s ' *)" "mesh-dev1 mesh-prod1 " "exactly the valid members have an auth mount"

# idempotent: a second run creates nothing new
: > "$S/calls"; run
assert_eq "$(grep -cE 'generate/internal|auth enable|secrets enable' "$S/calls" || true)" 0 "second run: no new mounts or keys"

# prune: a member that left loses auth and policy at once; an empty input list prunes nothing (fail-safe)
rm -f "$IN"/prod1.*; run
assert_eq "$([[ -e "$S/auth/mesh-prod1" ]] && echo kept || echo pruned)" pruned "removed member: auth mount disabled"
assert_eq "$([[ -e "$S/entities/mesh-prod1" ]] && echo kept || echo pruned)" pruned "removed member: identity entity deleted"
assert_eq "$([[ -e "$S/auth/mesh-dev1" ]] && echo kept || echo pruned)" kept "remaining member untouched"

# per-member fail-safe: an unreachable member (JWKS fetch fails) is skipped and reported, the rest are configured,
# the run succeeds, and the unreachable member's existing auth is not pruned
member prod1 prod
member down1 local https://unreachable.test:6443
rc=0; run || rc=$?
assert_eq "$rc" 0 "one unreachable member: reconcile still exits 0"
assert_match "$(cat "$TMP/out")" 'member down1 \(group local\): FAILED' "unreachable member reported as FAILED"
assert_match "$(cat "$TMP/out")" 'JWKS https://unreachable.test:6443/openid/v1/jwks not readable' "the report names the JWKS URL"
assert_match "$(cat "$TMP/out")" 'done: configured=\[dev1 prod1\] failed=\[down1\]' "summary: configured and failed members"
assert_eq "$([[ -e "$S/auth/mesh-prod1" ]] && echo kept || echo missing)" kept "the other members are configured after the failure"
assert_eq "$(wr auth/mesh-prod1/role/istio-csr | grep -c token_policies=mesh-member)" 1 "member after the failed one gets its auth role"
assert_eq "$([[ -e "$S/writes/auth_mesh-down1_role_istio-csr" ]] && echo written || echo none)" none "negative: no auth role for the member whose JWKS failed"
touch "$S/auth/mesh-down1"   # down1 was configured by an earlier run, then became unreachable
rc=0; run || rc=$?
assert_eq "$([[ -e "$S/auth/mesh-down1" ]] && echo kept || echo pruned)" kept "unreachable member keeps its existing auth (never pruned while in the inputs)"
# CronJob: members only (no bootstrap login, no CA operation), same member result
: > "$S/calls"; rc=0; run "$TMP/cronenv" || rc=$?
assert_eq "$rc" 0 "CronJob: one unreachable member, still exits 0"
assert_eq "$(grep -c 'platform-mesh-bootstrap' "$S/calls" || true)" 0 "CronJob: never logs in as platform-mesh-bootstrap"
assert_eq "$(grep -cE '/generate/|sign-intermediate|set-signed|secrets ' "$S/calls" || true)" 0 "CronJob: no CA operation"
assert_match "$(cat "$TMP/termination")" '^done: configured=\[dev1 prod1\] failed=\[down1\]' "the summary is the termination message (pod status)"
# a new group without CA: the CronJob cannot create it; its members fail (reported), the rest are configured
sed_inplace 's/^MESH_GROUPS=.*/MESH_GROUPS=local prod new/' "$TMP/cronenv"; member new1 new
rc=0; run "$TMP/cronenv" || rc=$?
assert_match "$(cat "$TMP/out")" 'group new: no intermediate CA yet' "CronJob: a group without CA is reported"
assert_match "$(cat "$TMP/out")" 'failed=\[down1 new1\]' "CronJob: its members fail, the others are configured"
assert_eq "$([[ -e "$S/mounts/pki-mesh-new-root" ]] && echo created || echo none)" none "CronJob: creates no group mount"
rm -f "$IN"/new1.*; render_env
# every member failing: the CronJob fails visibly; the Sync-hook Job exits 0 (cold boot: members not reachable yet)
rm -f "$IN"/*; member down1 local https://unreachable.test:6443; member down2 prod https://unreachable.test:7443
rc=0; run "$TMP/cronenv" || rc=$?
assert_eq "$rc" 1 "every member failed: the CronJob exits non-zero"
assert_match "$(cat "$TMP/out")" 'ERROR: no member could be configured \(failed: down1 down2\)' "every member failed: error names them"
assert_match "$(cat "$TMP/termination")" '^ERROR: no member could be configured' "every member failed: CronJob termination message"
rc=0; run || rc=$?
assert_eq "$rc" 0 "every member failed: the Sync-hook Job exits 0 (the CronJob converges)"
assert_match "$(cat "$TMP/out")" 'WARNING: no member could be configured yet \(failed: down1 down2\)' "every member failed: the hook still logs it"
assert_match "$(cat "$TMP/termination")" '^WARNING: no member could be configured yet' "every member failed: hook termination message"
assert_eq "$([[ -e "$S/auth/mesh-dev1" ]] && echo kept || echo pruned)" pruned "members no longer in the inputs are still pruned"
assert_eq "$([[ -e "$S/auth/mesh-down1" ]] && echo kept || echo pruned)" kept "every member failed: their auth is kept"
# invalid configuration fails the run
rm -f "$IN"/*; member Bad_Name local
rc=0; run || rc=$?
assert_eq "$rc" 1 "only invalid member inputs: reconcile exits non-zero"
assert_match "$(cat "$TMP/out")" 'every member input is invalid: Bad_Name' "only invalid member inputs: named"
rc=0; ( sed_inplace 's/^MESH_GROUPS=.*/MESH_GROUPS=Bad_Group/' "$TMP/env"; run ) || rc=$?
assert_eq "$rc" 1 "negative: a mesh group that is not a DNS label fails the run"
render_env

touch "$S/auth/mesh-dev1"
rm -f "$IN"/*; run
assert_match "$(cat "$TMP/out")" 'no member inputs: nothing pruned' "empty inputs: fail-safe message"
assert_eq "$([[ -e "$S/auth/mesh-dev1" ]] && echo kept || echo pruned)" kept "empty inputs: nothing pruned"

# mesh-clients template (ESO engine v2 = Go text/template + sprig, rendered here with helm's engine): only a fleet Secret
# named <cluster>-mesh-openbao becomes member input; anything else is rejected.<secret> (one Secret cannot claim or
# override another member). Then the reconcile logs rejected inputs and counts them as invalid.
lit=$(helm template openbao addons/openbao --namespace openbao -s templates/mesh-clients.yaml | yq '.spec.target.template.templateFrom[0].literal')
E="$TMP/esotpl"; mkdir -p "$E/templates"
printf 'apiVersion: v2\nname: esotpl\nversion: 0.0.1\n' > "$E/Chart.yaml"
printf '%s\n' "$lit" | sed 's/ := \. }}/ := $.Values.data }}/' > "$E/templates/out.yaml"
cat > "$E/values.yaml" <<'EOV'
data:
  dev1-mesh-openbao: '{"cluster":"dev1","group":"local","server":"https://172.18.0.9:6443","ca":"-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n"}'
  prod1-mesh-openbao: '{"cluster":"dev1","group":"local","server":"https://evil:6443","ca":"-----BEGIN CERTIFICATE-----"}'
  rogue: '{"cluster":"rogue","group":"local","server":"https://evil:6443","ca":"-----BEGIN CERTIFICATE-----"}'
  nocluster-mesh-openbao: '{"group":"local"}'
EOV
out=$(helm template e "$E" -s templates/out.yaml | yq -o json '.' )
assert_eq "$(printf '%s' "$out" | yq -r 'keys | sort | join(" ")')" "dev1.ca dev1.group dev1.server rejected.nocluster-mesh-openbao rejected.prod1-mesh-openbao rejected.rogue" "mesh-clients: only <cluster>-mesh-openbao becomes input, the rest is rejected"
assert_eq "$(printf '%s' "$out" | yq -r '."dev1.server"')" "https://172.18.0.9:6443" "mesh-clients: dev1's inputs come from dev1-mesh-openbao, not from the Secret that claims dev1"
assert_match "$(printf '%s' "$out" | yq -r '."rejected.prod1-mesh-openbao"')" 'cluster "dev1" does not match the Secret name' "mesh-clients: the rejection names the reason"
rm -f "$IN"/*; member dev1 local; printf 'cluster "dev1" does not match the Secret name' > "$IN/rejected.prod1-mesh-openbao"
rc=0; run || rc=$?
assert_eq "$rc" 0 "a rejected fleet Secret next to valid members: the run succeeds"
assert_match "$(cat "$TMP/out")" 'skip fleet Secret prod1-mesh-openbao: cluster "dev1" does not match' "the reconcile logs a rejected fleet Secret"
assert_match "$(cat "$TMP/out")" 'invalid=\[prod1-mesh-openbao\]' "a rejected fleet Secret counts as invalid input"
rm -f "$IN"/*; printf 'x' > "$IN/rejected.rogue"
rc=0; run || rc=$?
assert_eq "$rc" 1 "only rejected fleet Secrets: the run fails (every input invalid)"
rm -f "$IN"/*

# Self-initialisation (static policies + roles) and the addon values name the same identities: a renamed
# ServiceAccount, login role or member policy in values.yaml without the matching self-init change would lock the
# reconcile (or ESO) out of OpenBao for good - self-initialisation never runs again.
V=addons/openbao/values.yaml
cfg=$(helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  --set 'mesh.groups={local}' -s charts/openbao/templates/server-config-configmap.yaml | yq '.data["extraconfig-from-values.hcl"]')
role_sas() { printf '%s\n' "$cfg" | awk -v p="auth/kubernetes/role/$1" '$0 ~ "path *= \"" p "\"" {f=1} f && /bound_service_account_names/ && !n++ {sub(/.*= /, ""); print}'; }
role_field() { printf '%s\n' "$cfg" | awk -v p="auth/kubernetes/role/$1" -v k="$2" '$0 ~ "path *= \"" p "\"" {f=1} f && $1 == k && !n++ {sub(/.*= /, ""); print}'; }
assert_eq "$(role_sas "$(yq .reconcile.loginRole $V)")" "[\"$(yq .reconcile.serviceAccount $V)\", \"$(yq .reconcile.bootstrapServiceAccount $V)\"]" "self-init: reconcile.loginRole is bound to the CronJob and Job ServiceAccounts"
assert_eq "$(role_sas "$(yq .reconcile.bootstrapLoginRole $V)")" "[\"$(yq .reconcile.bootstrapServiceAccount $V)\"]" "self-init: reconcile.bootstrapLoginRole is bound to the Job ServiceAccount only"
assert_eq "$(role_sas mesh-ca-read)" "[\"$(yq .caPublic.pkiReader $V)\"]" "self-init: mesh-ca-read is bound to caPublic.pkiReader"
for r in "$(yq .reconcile.loginRole $V)" "$(yq .reconcile.bootstrapLoginRole $V)" mesh-ca-read; do
  assert_eq "$(role_field "$r" audience)" "\"$(yq .reconcile.audience $V)\"" "self-init: role $r audience == reconcile.audience"
  assert_eq "$(role_field "$r" bound_service_account_namespaces)" '["openbao"]' "self-init: role $r bound to namespace openbao (the addon namespace)"
done
assert_match "$cfg" "path += \"sys/policies/acl/$(yq .memberAuth.policy $V)\"" "self-init: writes memberAuth.policy"
assert_eq "$(yq '.addons.openbao.namespace' charts/platform/values.yaml)" openbao "addon openbao runs in namespace openbao"

finish
