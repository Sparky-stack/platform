#!/bin/sh
# Desired state of the Istio mesh PKI in OpenBao (addon openbao; docs/multicluster.md "Mesh CA"). Idempotent; run by
# the Argo CD PostSync Job and the CronJob `mesh-reconcile` (templates/reconcile.yaml). POSIX sh + the bao CLI only
# (the OpenBao image: busybox, no jq).
#
# Per mesh group <g> (MESH_GROUPS):
#   pki-mesh-<g>-root   root CA, key generated inside OpenBao (root/generate/internal): never exported, never on disk
#   pki-mesh-<g>-int    intermediate CA (intermediate/generate/internal), signed by the group root; the root is
#                       imported next to it so every issued chain ends at the group root (cert-manager's ca.crt)
# Per member <c> (one input set per cluster in INPUT_DIR: <c>.group, <c>.server, <c>.ca; built by ESO from the
# fleet Secrets charts/cluster renders, templates/mesh-clients.yaml):
#   pki-mesh-<g>-int/roles/<c>   istiod / istio-csr serving certs (ALLOWED_DOMAINS) + workload SPIFFE IDs
#                                spiffe://<TRUST_DOMAIN>/ns/*/sa/* only, TTL <= WORKLOAD_MAX_TTL
#   policy mesh-member-<c>       create/update on exactly pki-mesh-<g>-int/sign/<c>
#   auth/mesh-<c>  (jwt)         the member's own ServiceAccount signing keys (jwks_url = its API server's
#                                /openid/v1/jwks, pinned to its cluster CA); role MEMBER_ROLE accepts only
#                                system:serviceaccount:<MEMBER_SA> tokens with audience MEMBER_AUDIENCE
# plus policy mesh-ca-read + auth/kubernetes/role/mesh-ca-read: ESO (namespace openbao) reads the group roots'
# public certificates (cert/ca) and nothing else.
# Members no longer in the inputs lose their auth mount and policy at once (prune), unless the input list is empty
# (fail-safe: an ESO outage must not cut every member off). Their PKI role stays, unusable (no policy grants sign on
# it; rewritten if the name joins again): the reconcile's own policy may not delete anything under pki-mesh-*. Group
# mounts are never deleted here.
# Per-member fail-safe: a member that cannot be configured (its API server unreachable, its JWKS not public yet) is
# logged and skipped, the rest are configured, and it keeps its existing auth. Exit status: non-zero for invalid global
# config (groups, environment), when no member could be configured, or when every member input is invalid; 0 otherwise.
set -eu

IN=${INPUT_DIR:-/inputs}
: "${MESH_GROUPS:?}" "${TRUST_DOMAIN:?}" "${ALLOWED_DOMAINS:?}" "${MEMBER_SA:?}" "${MEMBER_AUDIENCE:?}"
MEMBER_ROLE=${MEMBER_ROLE:-istio-csr}
MEMBER_TOKEN_TTL=${MEMBER_TOKEN_TTL:-10m}
WORKLOAD_TTL=${WORKLOAD_TTL:-24h}
WORKLOAD_MAX_TTL=${WORKLOAD_MAX_TTL:-48h}
ROOT_TTL=${ROOT_TTL:-87600h}
INT_TTL=${INT_TTL:-43800h}
KEY_TYPE=${KEY_TYPE:-ec}
ROOT_KEY_BITS=${ROOT_KEY_BITS:-384}
INT_KEY_BITS=${INT_KEY_BITS:-256}
INSTALLATION=${INSTALLATION:-platform}
CA_READER_SA=${CA_READER_SA:-eso-openbao-pki-public}
CA_READER_NS=${CA_READER_NS:-openbao}
LOCAL_AUDIENCE=${LOCAL_AUDIENCE:-openbao}

log() { printf '%s mesh-reconcile: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
dns_label() { printf '%s' "$1" | grep -Eq '^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$'; }
has_cert() { bao read -field=certificate "$1/cert/ca" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; }
q() { bao "$@" >/dev/null; }

if [ -z "${BAO_TOKEN:-}" ]; then
  : "${LOGIN_ROLE:?}" "${TOKEN_FILE:?}"
  BAO_TOKEN=$(bao write -field=token "auth/${LOGIN_MOUNT:-kubernetes}/login" role="$LOGIN_ROLE" jwt=@"$TOKEN_FILE") \
    || die "login as $LOGIN_ROLE failed (is OpenBao up and self-initialised?)"
  export BAO_TOKEN
fi

ensure_mount() { # <path> <max lease ttl>
  if ! bao read "sys/mounts/$1" >/dev/null 2>&1; then
    log "enable pki at $1"
    q secrets enable -path="$1" -max-lease-ttl="$2" -description="mesh PKI ($1)" pki
  else
    q secrets tune -max-lease-ttl="$2" "$1"
  fi
}

# --- groups: root + intermediate ------------------------------------------------------------------------------------
for g in $MESH_GROUPS; do
  dns_label "$g" || die "mesh group '$g' is not a DNS label"
  root="pki-mesh-$g-root"; int="pki-mesh-$g-int"
  ensure_mount "$root" "$ROOT_TTL"
  ensure_mount "$int" "$ROOT_TTL"
  if ! has_cert "$root"; then
    log "group $g: generate root CA (internal key, never exported)"
    q write "$root/root/generate/internal" common_name="$INSTALLATION mesh root CA ($g)" \
      organization="$INSTALLATION" ou="mesh $g" key_type="$KEY_TYPE" key_bits="$ROOT_KEY_BITS" ttl="$ROOT_TTL" \
      issuer_name=root
  fi
  if ! has_cert "$int"; then
    log "group $g: generate intermediate CA (internal key), sign it with the group root"
    csr=$(bao write -field=csr "$int/intermediate/generate/internal" common_name="$INSTALLATION mesh intermediate CA ($g)" \
      organization="$INSTALLATION" ou="mesh $g" key_type="$KEY_TYPE" key_bits="$INT_KEY_BITS")
    cert=$(bao write -field=certificate "$root/root/sign-intermediate" csr="$csr" format=pem ttl="$INT_TTL" \
      use_csr_values=true max_path_length=0)
    rootpem=$(bao read -field=certificate "$root/cert/ca")
    # Intermediate first: set-signed makes the issuer whose key it holds the default; the root (no key here)
    # completes the chain, so signing responses carry ca_chain = [intermediate, root].
    q write "$int/intermediate/set-signed" certificate="$cert
$rootpem"
  fi
  # Revocation/CRL endpoints are not consulted by Istio; issued leaf certificates are not stored (no_store on roles).
done

# --- public root certificates for ESO (openbao-ca-bundle) -----------------------------------------------------------
pol=""
for g in $MESH_GROUPS; do
  pol="${pol}path \"pki-mesh-$g-root/cert/ca\" {
  capabilities = [\"read\"]
}
"
done
printf '%s' "$pol" | q policy write mesh-ca-read -
q write auth/kubernetes/role/mesh-ca-read bound_service_account_names="$CA_READER_SA" \
  bound_service_account_namespaces="$CA_READER_NS" audience="$LOCAL_AUDIENCE" token_policies=mesh-ca-read \
  token_no_default_policy=true token_ttl=10m token_max_ttl=10m

# --- members --------------------------------------------------------------------------------------------------------
# One member's role, policy and JWT auth. Every step checks its own result (`set -e` does not apply inside a function
# called from `if`): the first failure returns 1 and the caller moves on to the next member.
configure_member() { # <cluster> <group>
  c=$1; g=$2; int="pki-mesh-$g-int"
  q write "$int/roles/$c" \
    allowed_domains="$ALLOWED_DOMAINS" allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
    allow_wildcard_certificates=false allow_localhost=false allow_ip_sans=false allow_any_name=false \
    enforce_hostnames=true require_cn=false \
    allowed_uri_sans="spiffe://$TRUST_DOMAIN/ns/*/sa/*" allowed_uri_sans_template=false allowed_other_sans="" \
    server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false \
    key_type=any ttl="$WORKLOAD_TTL" max_ttl="$WORKLOAD_MAX_TTL" not_before_duration=30s no_store=true \
    generate_lease=false issuer_ref=default || { log "member $c: PKI role failed"; return 1; }

  printf 'path "%s/sign/%s" {\n  capabilities = ["create", "update"]\n}\n' "$int" "$c" | q policy write "mesh-member-$c" - \
    || { log "member $c: policy failed"; return 1; }

  if ! bao read "sys/auth/mesh-$c" >/dev/null 2>&1; then
    log "member $c (group $g): enable jwt auth at mesh-$c"
    q auth enable -path="mesh-$c" -description="mesh member $c (group $g)" jwt || { log "member $c: auth enable failed"; return 1; }
  fi
  # OpenBao fetches the JWKS while writing the config: this is where an unreachable member, or one whose issuer
  # discovery is not public yet (ClusterRoleBinding platform-oidc-discovery, CRS <c>-mesh-trust), fails.
  q write "auth/mesh-$c/config" jwks_url="$server/openid/v1/jwks" jwks_ca_pem=@"$IN/$c.ca" \
    || { log "member $c: JWKS $server/openid/v1/jwks not readable (API server unreachable, or issuer discovery not yet public)"; return 1; }
  q write "auth/mesh-$c/role/$MEMBER_ROLE" role_type=jwt user_claim=sub \
    bound_subject="system:serviceaccount:$MEMBER_SA" bound_audiences="$MEMBER_AUDIENCE" \
    token_policies="mesh-member-$c" token_no_default_policy=true token_type=batch \
    token_ttl="$MEMBER_TOKEN_TTL" token_max_ttl="$MEMBER_TOKEN_TTL" || { log "member $c: auth role failed"; return 1; }
}

# Per-member fail-safe: a member that cannot be configured (API server down, JWKS forbidden, OpenBao error) is reported
# and skipped; the others are configured. It stays in `seen` (still desired), so its existing auth is never pruned.
seen=" "; ok=""; failed=""; invalid=""
for f in "$IN"/*.group; do
  [ -e "$f" ] || continue
  c=$(basename "$f" .group)
  g=$(cat "$f")
  if ! dns_label "$c"; then log "skip '$c': cluster name is not a DNS label"; invalid="$invalid $c"; continue; fi
  case " $MESH_GROUPS " in *" $g "*) ;; *) log "skip $c: group '$g' is not in MESH_GROUPS"; invalid="$invalid $c"; continue ;; esac
  server=$(cat "$IN/$c.server" 2>/dev/null || true)
  case "$server" in https://*) ;; *) log "skip $c: API server '$server' is not https"; invalid="$invalid $c"; continue ;; esac
  if ! grep -q 'BEGIN CERTIFICATE' "$IN/$c.ca" 2>/dev/null; then log "skip $c: no cluster CA"; invalid="$invalid $c"; continue; fi
  seen="$seen$c:$g "
  if configure_member "$c" "$g"; then
    ok="$ok $c"
    log "member $c (group $g): role, policy and auth in place"
  else
    failed="$failed $c"
    log "member $c (group $g): FAILED - skipped this run, retried by the next run; its existing auth is kept"
  fi
done

# --- prune members that left ----------------------------------------------------------------------------------------
if [ "$seen" = " " ]; then
  log "no member inputs: nothing pruned (fail-safe)"
  [ -z "$invalid" ] || die "every member input is invalid:$invalid"
  exit 0
fi
for m in $(bao auth list | awk '{print $1}' | grep '^mesh-' | sed 's#/$##'); do
  c=${m#mesh-}
  case "$seen" in *" $c:"*) ;; *) log "prune auth $m"; q auth disable "$m" ;; esac
done
for p in $(bao policy list | grep '^mesh-member-' || true); do
  c=${p#mesh-member-}
  case "$seen" in *" $c:"*) ;; *) log "prune policy $p"; q policy delete "$p" ;; esac
done
log "done: configured=[${ok# }] failed=[${failed# }] invalid=[${invalid# }]"
# Non-zero only when no member could be configured (every one failed): a single unreachable member must not fail the
# Argo CD PostSync hook or the CronJob for the rest of the fleet. Partial failures are in the summary line above.
[ -n "$ok" ] || die "no member could be configured (failed:$failed)"
