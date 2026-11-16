#!/bin/sh
# Desired state of the Istio mesh PKI in OpenBao (addon openbao; docs/multicluster.md "Mesh CA"). Idempotent; run by
# the Argo CD PostSync Job (group bootstrap + members) and the CronJob `mesh-reconcile` (members only)
# (templates/reconcile.yaml). POSIX sh + the bao CLI only (the OpenBao image: busybox, no jq).
#
# This script authors NO ACL policy. Every policy is static and is written once by OpenBao's self-initialisation
# (values.yaml openbao.server.ha.raft.config). Two OpenBao identities, two tokens:
#   bootstrap token (BOOTSTRAP_LOGIN_ROLE, PostSync Job only; policy platform-mesh-bootstrap), per mesh group <g>:
#     pki-mesh-<g>-root   root CA, key generated inside OpenBao (root/generate/internal): never exported, never on disk
#     pki-mesh-<g>-int    intermediate CA (intermediate/generate/internal), signed by the group root with
#                         max_path_length=0; the root is imported next to it so every issued chain ends at the group
#                         root (cert-manager's ca.crt)
#   member token (LOGIN_ROLE, Job + CronJob; policy platform-mesh-config), per member <c> (one input set per cluster in
#   INPUT_DIR: <c>.group, <c>.server, <c>.ca; built by ESO from the fleet Secrets charts/cluster renders,
#   templates/mesh-clients.yaml, which turns a Secret not named <c>-mesh-openbao into rejected.<secret> - logged here
#   and counted as invalid):
#     pki-mesh-<g>-int/roles/<c>   istiod / istio-csr serving certs (ALLOWED_DOMAINS) + workload SPIFFE IDs
#                                  spiffe://<TRUST_DOMAIN>/ns/*/sa/* only, TTL <= WORKLOAD_MAX_TTL. The policy pins every
#                                  widening flag (IP SANs, wildcards, globs, any name, other SANs, localhost).
#     identity entity mesh-<c>     metadata cluster=<c>, group=<g>. The static templated policy MEMBER_POLICY grants
#                                  create/update on exactly pki-mesh-<group>-int/sign/<cluster> of the caller's entity.
#     auth/mesh-<c>  (jwt)         the member's own ServiceAccount signing keys (jwks_url = its API server's
#                                  /openid/v1/jwks, pinned to its cluster CA); role MEMBER_ROLE accepts only
#                                  system:serviceaccount:<MEMBER_SA> tokens with audience MEMBER_AUDIENCE. That
#                                  subject's alias on this mount is bound to entity mesh-<c> before the role exists.
# Members no longer in the inputs lose their auth mount and entity at once (prune), unless the input list is empty
# (fail-safe: an ESO outage must not cut every member off). Their PKI role stays but is unusable (no entity carries its
# metadata; it is rewritten if the name joins again). Group mounts are never deleted here.
# Per-member fail-safe: a member that cannot be configured (its API server unreachable, its JWKS not public yet, its
# group not bootstrapped yet) is logged and skipped, the rest are configured, and it keeps its existing auth.
# Exit status: non-zero for invalid groups, a failed login or group bootstrap, when every member input is invalid,
# and - with FAIL_ON_NO_MEMBER=true (CronJob) - when no member could be configured. The PostSync hook sets
# FAIL_ON_NO_MEMBER=false: on a cold boot members are registered before they are reachable, and the hook must not
# leave the Application SyncFailed for that. The CronJob converges and keeps failing visibly until a member is
# configured. The summary line also goes to the container termination message (pod .status...terminated.message).
set -eu

IN=${INPUT_DIR:-/inputs}
: "${MESH_GROUPS:?}" "${TRUST_DOMAIN:?}" "${ALLOWED_DOMAINS:?}" "${MEMBER_SA:?}" "${MEMBER_AUDIENCE:?}"
MEMBER_ROLE=${MEMBER_ROLE:-istio-csr}
MEMBER_POLICY=${MEMBER_POLICY:-mesh-member}
MEMBER_TOKEN_TTL=${MEMBER_TOKEN_TTL:-10m}
WORKLOAD_TTL=${WORKLOAD_TTL:-24h}
WORKLOAD_MAX_TTL=${WORKLOAD_MAX_TTL:-48h}
ROOT_TTL=${ROOT_TTL:-87600h}
INT_TTL=${INT_TTL:-43800h}
KEY_TYPE=${KEY_TYPE:-ec}
ROOT_KEY_BITS=${ROOT_KEY_BITS:-384}
INT_KEY_BITS=${INT_KEY_BITS:-256}
INSTALLATION=${INSTALLATION:-platform}
FAIL_ON_NO_MEMBER=${FAIL_ON_NO_MEMBER:-true}
TERMINATION_LOG=${TERMINATION_LOG:-/dev/termination-log}

log() { printf '%s mesh-reconcile: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
status() { log "$*"; { printf '%s\n' "$*" > "$TERMINATION_LOG"; } 2>/dev/null || true; }
die() { status "ERROR: $*"; exit 1; }
dns_label() { printf '%s' "$1" | grep -Eq '^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$'; }
has_cert() { bao read -field=certificate "$1/cert/ca" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; }
q() { bao "$@" >/dev/null; }
login() { # <role>: prints an OpenBao token for the projected ServiceAccount token in TOKEN_FILE
  : "${TOKEN_FILE:?}"
  bao write -field=token "auth/${LOGIN_MOUNT:-kubernetes}/login" role="$1" jwt=@"$TOKEN_FILE"
}

for g in $MESH_GROUPS; do dns_label "$g" || die "mesh group '$g' is not a DNS label"; done

# --- groups: root + intermediate (bootstrap token only) -------------------------------------------------------------
b() { BAO_TOKEN=$BAO_BOOTSTRAP_TOKEN bao "$@"; }
ensure_mount() { # <path> <max lease ttl>
  if ! b read "sys/mounts/$1" >/dev/null 2>&1; then
    log "enable pki at $1"
    b secrets enable -path="$1" -max-lease-ttl="$2" -description="mesh PKI ($1)" pki >/dev/null || die "enable pki at $1 failed"
  else
    b secrets tune -max-lease-ttl="$2" "$1" >/dev/null || die "tune $1 failed"
  fi
}
bootstrap_group() { # <group>
  g=$1; root="pki-mesh-$g-root"; int="pki-mesh-$g-int"
  ensure_mount "$root" "$ROOT_TTL"
  ensure_mount "$int" "$ROOT_TTL"
  if ! has_cert "$root"; then
    log "group $g: generate root CA (internal key, never exported)"
    b write "$root/root/generate/internal" common_name="$INSTALLATION mesh root CA ($g)" \
      organization="$INSTALLATION" ou="mesh $g" key_type="$KEY_TYPE" key_bits="$ROOT_KEY_BITS" ttl="$ROOT_TTL" \
      issuer_name=root >/dev/null || die "group $g: root CA failed"
  fi
  if ! has_cert "$int"; then
    log "group $g: generate intermediate CA (internal key), sign it with the group root"
    csr=$(b write -field=csr "$int/intermediate/generate/internal" common_name="$INSTALLATION mesh intermediate CA ($g)" \
      organization="$INSTALLATION" ou="mesh $g" key_type="$KEY_TYPE" key_bits="$INT_KEY_BITS") \
      || die "group $g: intermediate key failed"
    cert=$(b write -field=certificate "$root/root/sign-intermediate" csr="$csr" format=pem ttl="$INT_TTL" \
      use_csr_values=true max_path_length=0) || die "group $g: signing the intermediate failed"
    rootpem=$(b read -field=certificate "$root/cert/ca") || die "group $g: root certificate unreadable"
    # Intermediate first: set-signed makes the issuer whose key it holds the default; the root (no key here)
    # completes the chain, so signing responses carry ca_chain = [intermediate, root].
    b write "$int/intermediate/set-signed" certificate="$cert
$rootpem" >/dev/null || die "group $g: set-signed failed"
  fi
  # Revocation/CRL endpoints are not consulted by Istio; issued leaf certificates are not stored (no_store on roles).
}
if [ -z "${BAO_BOOTSTRAP_TOKEN:-}" ] && [ -n "${BOOTSTRAP_LOGIN_ROLE:-}" ]; then
  BAO_BOOTSTRAP_TOKEN=$(login "$BOOTSTRAP_LOGIN_ROLE") || die "login as $BOOTSTRAP_LOGIN_ROLE failed (is OpenBao up and self-initialised?)"
fi
if [ -n "${BAO_BOOTSTRAP_TOKEN:-}" ]; then
  for g in $MESH_GROUPS; do bootstrap_group "$g"; done
  BAO_BOOTSTRAP_TOKEN=""   # the CA-equivalent token is not used past this point
fi
# Groups whose intermediate exists (the CronJob cannot create one; a new group waits for the next PostSync Job).
ready=" "
for g in $MESH_GROUPS; do
  if has_cert "pki-mesh-$g-int"; then ready="$ready$g "; else log "group $g: no intermediate CA yet (created by the PostSync Job)"; fi
done

if [ -z "${BAO_TOKEN:-}" ]; then
  : "${LOGIN_ROLE:?}"
  BAO_TOKEN=$(login "$LOGIN_ROLE") || die "login as $LOGIN_ROLE failed (is OpenBao up and self-initialised?)"
  export BAO_TOKEN
fi

# --- members --------------------------------------------------------------------------------------------------------
# One member's role, entity and JWT auth. Every step checks its own result (`set -e` does not apply inside a function
# called from `if`): the first failure returns 1 and the caller moves on to the next member.
configure_member() { # <cluster> <group>
  c=$1; g=$2; int="pki-mesh-$g-int"
  case "$ready" in *" $g "*) ;; *) log "member $c: group $g has no intermediate CA yet"; return 1 ;; esac
  q write "$int/roles/$c" \
    allowed_domains="$ALLOWED_DOMAINS" allow_bare_domains=true allow_subdomains=false allow_glob_domains=false \
    allow_wildcard_certificates=false allow_localhost=false allow_ip_sans=false allow_any_name=false \
    enforce_hostnames=true require_cn=false \
    allowed_uri_sans="spiffe://$TRUST_DOMAIN/ns/*/sa/*" allowed_uri_sans_template=false allowed_other_sans="" \
    server_flag=true client_flag=true code_signing_flag=false email_protection_flag=false \
    key_type=any ttl="$WORKLOAD_TTL" max_ttl="$WORKLOAD_MAX_TTL" not_before_duration=30s no_store=true \
    generate_lease=false issuer_ref=default || { log "member $c: PKI role failed"; return 1; }

  if ! bao read "sys/auth/mesh-$c" >/dev/null 2>&1; then
    log "member $c (group $g): enable jwt auth at mesh-$c"
    q auth enable -path="mesh-$c" -description="mesh member $c (group $g)" jwt || { log "member $c: auth enable failed"; return 1; }
  fi
  acc=$(bao read -field=accessor "sys/auth/mesh-$c") || { log "member $c: auth mount accessor unreadable"; return 1; }
  # The entity carries the only member-specific authorisation: MEMBER_POLICY is templated on its metadata.
  q write "identity/entity/name/mesh-$c" metadata="cluster=$c" metadata="group=$g" \
    || { log "member $c: identity entity failed"; return 1; }
  eid=$(bao read -field=id "identity/entity/name/mesh-$c") || { log "member $c: identity entity unreadable"; return 1; }
  # Create or move: this mount's alias for the member's ServiceAccount belongs to entity mesh-<c>.
  q write identity/entity-alias name="system:serviceaccount:$MEMBER_SA" canonical_id="$eid" mount_accessor="$acc" \
    || { log "member $c: identity alias failed"; return 1; }
  # OpenBao fetches the JWKS while writing the config: this is where an unreachable member, or one whose issuer
  # discovery is not public yet (ClusterRoleBinding platform-oidc-discovery, CRS <c>-mesh-trust), fails.
  q write "auth/mesh-$c/config" jwks_url="$server/openid/v1/jwks" jwks_ca_pem=@"$IN/$c.ca" \
    || { log "member $c: JWKS $server/openid/v1/jwks not readable (API server unreachable, or issuer discovery not yet public)"; return 1; }
  q write "auth/mesh-$c/role/$MEMBER_ROLE" role_type=jwt user_claim=sub \
    bound_subject="system:serviceaccount:$MEMBER_SA" bound_audiences="$MEMBER_AUDIENCE" \
    token_policies="$MEMBER_POLICY" token_no_default_policy=true token_type=batch \
    token_ttl="$MEMBER_TOKEN_TTL" token_max_ttl="$MEMBER_TOKEN_TTL" || { log "member $c: auth role failed"; return 1; }
}

# Per-member fail-safe: a member that cannot be configured (API server down, JWKS forbidden, OpenBao error) is reported
# and skipped; the others are configured. It stays in `seen` (still desired), so its existing auth is never pruned.
seen=" "; ok=""; failed=""; invalid=""
# Fleet Secrets the mesh-clients template rejected (name != <cluster>-mesh-openbao): never enrolled.
for f in "$IN"/rejected.*; do
  [ -e "$f" ] || continue
  r=${f##*/rejected.}
  log "skip fleet Secret $r: $(cat "$f")"; invalid="$invalid $r"
done
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
    log "member $c (group $g): role, entity and auth in place"
  else
    failed="$failed $c"
    log "member $c (group $g): FAILED - skipped this run, retried by the next run; its existing auth is kept"
  fi
done

# --- prune members that left ----------------------------------------------------------------------------------------
if [ "$seen" = " " ]; then
  [ -z "$invalid" ] || die "every member input is invalid:$invalid"
  status "no member inputs: nothing pruned (fail-safe)"
  exit 0
fi
for m in $(bao auth list | awk '{print $1}' | grep '^mesh-' | sed 's#/$##'); do
  c=${m#mesh-}
  case "$seen" in *" $c:"*) ;; *)
    log "prune auth $m"; q auth disable "$m"
    q delete "identity/entity/name/$m" || log "prune: entity $m not deleted (no aliases left, unusable)" ;;
  esac
done
summary="configured=[${ok# }] failed=[${failed# }] invalid=[${invalid# }]"
# A single unreachable member must not fail the run for the rest of the fleet (partial failures: summary line).
if [ -z "$ok" ]; then
  [ "$FAIL_ON_NO_MEMBER" = true ] && die "no member could be configured (failed:$failed) $summary"
  status "WARNING: no member could be configured yet (failed:$failed) $summary - PostSync hook exits 0; the CronJob mesh-reconcile retries and fails until one is"
  exit 0
fi
status "done: $summary"
