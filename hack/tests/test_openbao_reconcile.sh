#!/usr/bin/env bash
# Mesh PKI reconcile (addon openbao files/mesh-reconcile.sh) against a fake `bao` CLI that keeps state in files: what
# OpenBao is told to do per group and per member, with the environment the chart renders for the Job. Checks the
# per-cluster scope (a member's policy covers exactly its own role in its own group's intermediate), the SPIFFE-only
# PKI role, audience/subject-bound JWT auth, internal (never exported) CA keys, input validation, prune + fail-safe.
# The same script runs against a real OpenBao in hack/tests/openbao_integration.sh (opt-in, docker).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_openbao_reconcile =="
cd "$ROOT"
S="$TMP/state"; BIN="$TMP/bin"; IN="$TMP/inputs"
mkdir -p "$S/mounts" "$S/certs" "$S/auth" "$S/policies" "$S/roles" "$S/writes" "$BIN" "$IN"
cat > "$BIN/bao" <<'FAKE'
#!/usr/bin/env bash
# fake bao: state under $FAKE_STATE, every call appended to $FAKE_STATE/calls
set -u
S=$FAKE_STATE
printf '%s\n' "$*" >> "$S/calls"
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
      sys/auth/*) [[ -e "$S/auth/$(enc "${p#sys/auth/}")" ]] ;;
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
      auth/kubernetes/login) [[ -n "$field" ]] && echo "fake-token" ;;
      */root/generate/internal) touch "$S/certs/$(enc "${p%/root/generate/internal}")" ;;
      */intermediate/generate/internal) echo "-----BEGIN CERTIFICATE REQUEST-----" ;;
      */root/sign-intermediate) echo "-----BEGIN CERTIFICATE----- int" ;;
      */intermediate/set-signed) touch "$S/certs/$(enc "${p%/intermediate/set-signed}")" ;;
      */roles/*) cp "$S/writes/$(enc "$p")" "$S/roles/$(enc "$p")" ;;
    esac ;;
  delete) rm -f "$S/roles/$(enc "${args[0]}")" ;;
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

# Environment exactly as the chart renders it for the Job (groups local + prod).
helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  --set 'mesh.groups={local,prod}' -s templates/reconcile.yaml \
  | yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/env"
member() {   # member <name> <group> [server] [ca]
  printf '%s' "$2" > "$IN/$1.group"
  printf '%s' "${3:-https://172.18.0.9:6443}" > "$IN/$1.server"
  printf '%s\n' "${4:------BEGIN CERTIFICATE-----}" > "$IN/$1.ca"
}
run() {
  ( set -a; while IFS= read -r l; do export "${l?}"; done < "$TMP/env"; set +a
    export INPUT_DIR="$IN" TOKEN_FILE="$TMP/token" FAKE_STATE="$S" PATH="$BIN:$PATH"; unset BAO_TOKEN
    sh addons/openbao/files/mesh-reconcile.sh ) > "$TMP/out" 2>&1
}
pol() { cat "$S/policies/$1" 2>/dev/null; }
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

# login: Kubernetes auth with the projected token, scoped role (never a root token)
assert_match "$(head -1 "$S/calls")" '^write -field=token auth/kubernetes/login role=platform-mesh-config jwt=@' "logs in as platform-mesh-config with the projected token"
# groups: internal keys only
for g in local prod; do
  assert_match "$(cat "$S/calls")" "write pki-mesh-$g-root/root/generate/internal " "group $g: root key generated inside OpenBao"
  assert_match "$(cat "$S/calls")" "write -field=csr pki-mesh-$g-int/intermediate/generate/internal " "group $g: intermediate key generated inside OpenBao"
done
assert_eq "$(grep -cE 'generate/exported|generate/existing|private_key|config/ca|/import' "$S/calls" || true)" 0 "no CA key is ever exported or imported"
assert_match "$(wr pki-mesh-local-root/root/sign-intermediate)" 'max_path_length=0' "intermediates cannot sign further CAs"

# per-cluster scope: exactly one path, sign on its own role in its own group's intermediate
assert_eq "$(pol mesh-member-dev1 | tr -s ' \n' ' ')" 'path "pki-mesh-local-int/sign/dev1" { capabilities = ["create", "update"] } ' "dev1 policy: sign on its own role only"
assert_eq "$(pol mesh-member-prod1 | tr -s ' \n' ' ')" 'path "pki-mesh-prod-int/sign/prod1" { capabilities = ["create", "update"] } ' "prod1 policy: its own group's intermediate only"
assert_eq "$(pol mesh-member-dev1 | grep -cE 'root|prod|\*|sudo|delete|read' || true)" 0 "negative: dev1 may not touch a root, another group, globs, sudo, read or delete"
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
  bound_audiences=vault://istio-system/openbao-mesh token_policies=mesh-member-dev1 token_no_default_policy=true \
  token_type=batch token_ttl=10m token_max_ttl=10m; do
  assert_eq "$(printf '%s\n' "$arole" | grep -cxF -- "$kv")" 1 "dev1 auth role: $kv"
done
# public certificate reader: cert/ca of the roots only
assert_eq "$(pol mesh-ca-read | grep -o 'path "[^"]*"' | tr '\n' ' ')" 'path "pki-mesh-local-root/cert/ca" path "pki-mesh-prod-root/cert/ca" ' "mesh-ca-read: the group roots' public certificates only"
assert_eq "$(pol mesh-ca-read | grep -c 'capabilities = \["read"\]')" 2 "mesh-ca-read: read only"
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
assert_eq "$([[ -e "$S/policies/mesh-member-prod1" ]] && echo kept || echo pruned)" pruned "removed member: policy deleted"
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
assert_eq "$(wr auth/mesh-prod1/role/istio-csr | grep -c token_policies=mesh-member-prod1)" 1 "member after the failed one gets its auth role"
assert_eq "$([[ -e "$S/writes/auth_mesh-down1_role_istio-csr" ]] && echo written || echo none)" none "negative: no auth role for the member whose JWKS failed"
touch "$S/auth/mesh-down1"   # down1 was configured by an earlier run, then became unreachable
rc=0; run || rc=$?
assert_eq "$([[ -e "$S/auth/mesh-down1" ]] && echo kept || echo pruned)" kept "unreachable member keeps its existing auth (never pruned while in the inputs)"
# every member failing is a real outage: non-zero, nothing pruned
rm -f "$IN"/*; member down1 local https://unreachable.test:6443; member down2 prod https://unreachable.test:7443
rc=0; run || rc=$?
assert_eq "$rc" 1 "every member failed: reconcile exits non-zero"
assert_match "$(cat "$TMP/out")" 'ERROR: no member could be configured \(failed: down1 down2\)' "every member failed: error names them"
assert_eq "$([[ -e "$S/auth/mesh-dev1" ]] && echo kept || echo pruned)" pruned "members no longer in the inputs are still pruned"
assert_eq "$([[ -e "$S/auth/mesh-down1" ]] && echo kept || echo pruned)" kept "every member failed: their auth is kept"
# invalid configuration fails the run
rm -f "$IN"/*; member Bad_Name local
rc=0; run || rc=$?
assert_eq "$rc" 1 "only invalid member inputs: reconcile exits non-zero"
assert_match "$(cat "$TMP/out")" 'every member input is invalid: Bad_Name' "only invalid member inputs: named"
rc=0; ( sed -i 's/^MESH_GROUPS=.*/MESH_GROUPS=Bad_Group/' "$TMP/env"; run ) || rc=$?
assert_eq "$rc" 1 "negative: a mesh group that is not a DNS label fails the run"
helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml \
  --set 'mesh.groups={local,prod}' -s templates/reconcile.yaml \
  | yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | .name + "=" + .value' > "$TMP/env"

touch "$S/auth/mesh-dev1"
rm -f "$IN"/*; run
assert_match "$(cat "$TMP/out")" 'no member inputs: nothing pruned' "empty inputs: fail-safe message"
assert_eq "$([[ -e "$S/auth/mesh-dev1" ]] && echo kept || echo pruned)" kept "empty inputs: nothing pruned"

finish
