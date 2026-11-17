#!/bin/sh
# Desired state of the per-tenant secrets in OpenBao (addon openbao, installation.yaml secrets.tenantStores; docs/
# multicluster.md "Tenant secrets (OpenBao)"). Idempotent; run by the CronJob `tenant-reconcile`
# (templates/tenant-secrets.yaml). POSIX sh + the bao CLI only (the OpenBao image: busybox, no jq).
#
# This script authors NO ACL policy: tenant-read / tenant-write are templated policies from git (files/policies/,
# written by the CronJob policy-reconcile), keyed on the metadata `tenant` of the caller's identity entity. One
# identity: LOGIN_ROLE (policy tenant-config). Inputs (built by ESO, the pod has no Kubernetes API access):
#   $IN/tenants/<t>.namespaces   space-separated cell namespaces of tenant <t> on the data planes (charts/tenant
#                                computes them like OpenChoreo does); rejected.<secret> = a descriptor whose name is not
#                                <t>-openbao-tenant (templates/tenant-secrets.yaml)
#   $IN/clusters/<c>.server, <c>.ca, <c>.group   the mesh members (the mesh-clients Secret of the mesh reconcile)
# Per tenant <t>:
#   kv-tenant-<t>                       KV v2 mount (created if missing; never deleted here - data outlives a tenant)
#   identity entity tenant-<t>          metadata tenant=<t>
#   alias WRITER_NS/<t>-writer on the mgmt Kubernetes auth mount -> entity tenant-<t> (role tenant-writer)
# Per member cluster <c>:
#   auth/tenants-<c> (jwt)              the member's ServiceAccount signing keys (jwks_url = its API server's
#                                       /openid/v1/jwks, pinned to its cluster CA), like auth/mesh-<c>
#   per tenant and namespace <ns>: entity tenant-<t>.<c>.<ns> (metadata tenant=<t>) with the alias
#   system:serviceaccount:<ns>:READER_SA (bound before the role exists, so no login ever auto-creates an entity for
#   it), then role <t>: that subject list only, audience READER_AUDIENCE, policy READER_POLICY, short service tokens
#   (ESO revokes them after use). One entity per namespace because OpenBao allows an entity only ONE alias per auth
#   mount ("Alias already exists for requested entity and mount accessor"); the policies only read metadata.tenant.
# Prune: roles of tenants no longer in the inputs and their entities; namespace entities tenant-<t>.<c>.<ns> that are
#   no longer bound (namespace left or contested, tenant left; only for clusters configured in this run and tenants
#   not failed in it) and those of clusters that left; tenants-<c> mounts of clusters no longer in the inputs. Never
#   with an empty tenant list (fail-safe: an ESO outage must not cut every tenant off). A namespace claimed by two
#   tenants is bound to neither (and logged): one descriptor must never move another tenant's namespace.
# Exit status: non-zero for a failed login, when every tenant input is invalid, or when no member cluster could be
# configured although there are members. The summary line goes to the container termination message.
set -eu

IN=${INPUT_DIR:-/inputs}
: "${READER_SA:?}" "${READER_AUDIENCE:?}" "${WRITER_NS:?}"
READER_POLICY=${READER_POLICY:-tenant-read}
TOKEN_TTL=${TOKEN_TTL:-10m}
K8S_MOUNT=${K8S_MOUNT:-kubernetes}
TERMINATION_LOG=${TERMINATION_LOG:-/dev/termination-log}

log() { printf '%s tenant-reconcile: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
status() { log "$*"; { printf '%s\n' "$*" > "$TERMINATION_LOG"; } 2>/dev/null || true; }
die() { status "ERROR: $*"; exit 1; }
label() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'; }
q() { bao "$@" >/dev/null; }

if [ -z "${BAO_TOKEN:-}" ]; then
  : "${LOGIN_ROLE:?}" "${TOKEN_FILE:?}"
  BAO_TOKEN=$(bao write -field=token "auth/$K8S_MOUNT/login" role="$LOGIN_ROLE" jwt=@"$TOKEN_FILE") \
    || die "login as $LOGIN_ROLE failed (is OpenBao up, and has the CronJob policy-reconcile written the role?)"
  export BAO_TOKEN
fi

# --- inputs ---------------------------------------------------------------------------------------------------------
tenants=" "; invalid=""; claims=" "
for f in "$IN"/tenants/rejected.*; do
  [ -e "$f" ] || continue
  r=${f##*/rejected.}; log "skip descriptor $r: $(cat "$f")"; invalid="$invalid $r"
done
for f in "$IN"/tenants/*.namespaces; do
  [ -e "$f" ] || continue
  t=$(basename "$f" .namespaces)
  if ! label "$t" || [ ${#t} -gt 50 ]; then log "skip tenant '$t': not a DNS label of <= 50 characters"; invalid="$invalid $t"; continue; fi
  nss=$(cat "$f")
  bad=""; for ns in $nss; do label "$ns" || bad="$bad $ns"; done
  if [ -n "$bad" ] || [ -z "$nss" ]; then log "skip tenant $t: invalid namespaces '${bad# }'"; invalid="$invalid $t"; continue; fi
  tenants="$tenants$t "
  for ns in $nss; do claims="$claims$ns:$t "; done
done
# namespaces claimed by more than one tenant: bound to none of them
dup=" "
for c in $claims; do
  ns=${c%%:*}
  # shellcheck disable=SC2086  # word list on purpose (validated DNS labels)
  n=$(printf '%s\n' $claims | grep -c "^$ns:" || true)
  if [ "$n" -gt 1 ]; then case "$dup" in *" $ns "*) ;; *) dup="$dup$ns "; log "namespace $ns is claimed by several tenants: bound to none" ;; esac; fi
done
namespaces_of() { # <tenant>: its namespaces, minus contested ones
  # shellcheck disable=SC2013  # space-separated words, validated above
  for ns in $(cat "$IN/tenants/$1.namespaces"); do case "$dup" in *" $ns "*) ;; *) printf '%s ' "$ns" ;; esac; done
}

if [ "$tenants" = " " ]; then
  [ -z "$invalid" ] || die "every tenant input is invalid:$invalid"
  status "no tenant inputs: nothing configured, nothing pruned (fail-safe)"
  exit 0
fi

# --- per tenant: KV mount, entity, writer alias ---------------------------------------------------------------------
k8s_acc=$(bao auth list | awk -v m="$K8S_MOUNT/" '$1 == m {print $3}')   # sys/auth list (no sudo on that mount)
[ -n "$k8s_acc" ] || die "accessor of auth/$K8S_MOUNT unreadable"
ok_t=""; failed_t=""; ready=" "
configure_tenant() { # <tenant>
  t=$1
  if ! bao read "sys/mounts/kv-tenant-$t" >/dev/null 2>&1; then
    log "tenant $t: enable kv v2 at kv-tenant-$t"
    q secrets enable -path="kv-tenant-$t" -version=2 -description="tenant $t" kv || { log "tenant $t: kv mount failed"; return 1; }
  fi
  q write "identity/entity/name/tenant-$t" metadata="tenant=$t" || { log "tenant $t: identity entity failed"; return 1; }
  eid=$(bao read -field=id "identity/entity/name/tenant-$t") || { log "tenant $t: identity entity unreadable"; return 1; }
  q write identity/entity-alias name="$WRITER_NS/$t-writer" canonical_id="$eid" mount_accessor="$k8s_acc" \
    || { log "tenant $t: writer alias failed"; return 1; }
  ready="$ready$t=$eid "
}
for t in $tenants; do
  if configure_tenant "$t"; then ok_t="$ok_t $t"; else failed_t="$failed_t $t"; fi
done
eid_of() { for p in $ready; do case "$p" in "$1="*) printf '%s' "${p#*=}"; return 0 ;; esac; done; return 1; }

# --- per member cluster: JWT auth, aliases, roles -------------------------------------------------------------------
clusters=" "; ok_c=""; failed_c=""; pruned=""; bound=" "
configure_cluster() { # <cluster> <server>
  c=$1; server=$2; m="tenants-$c"
  if ! bao read "sys/auth/$m" >/dev/null 2>&1; then
    log "cluster $c: enable jwt auth at $m"
    q auth enable -path="$m" -description="tenant secrets on $c" jwt || { log "cluster $c: auth enable failed"; return 1; }
  fi
  acc=$(bao read -field=accessor "sys/auth/$m") || { log "cluster $c: auth mount accessor unreadable"; return 1; }
  q write "auth/$m/config" jwks_url="$server/openid/v1/jwks" jwks_ca_pem=@"$IN/clusters/$c.ca" \
    || { log "cluster $c: JWKS $server/openid/v1/jwks not readable (API server unreachable, or issuer discovery not yet public)"; return 1; }
  for t in $tenants; do
    eid_of "$t" >/dev/null || continue      # tenant not configured this run: its existing role is kept
    subs=""
    for ns in $(namespaces_of "$t"); do
      sub="system:serviceaccount:$ns:$READER_SA"; en="tenant-$t.$c.$ns"
      q write "identity/entity/name/$en" metadata="tenant=$t" || { log "cluster $c tenant $t: entity $en failed"; return 1; }
      neid=$(bao read -field=id "identity/entity/name/$en") || { log "cluster $c tenant $t: entity $en unreadable"; return 1; }
      q write identity/entity-alias name="$sub" canonical_id="$neid" mount_accessor="$acc" \
        || { log "cluster $c tenant $t: alias $sub failed"; return 1; }
      bound="$bound$en "
      subs="$subs\"$sub\","
    done
    if [ -z "$subs" ]; then q delete "auth/$m/role/$t" || true; log "cluster $c tenant $t: no uncontested namespace, no role"; continue; fi
    printf '{"role_type":"jwt","user_claim":"sub","bound_audiences":["%s"],"bound_claims_type":"string","bound_claims":{"sub":[%s]},"token_policies":"%s","token_no_default_policy":true,"token_type":"service","token_ttl":"%s","token_max_ttl":"%s"}' \
      "$READER_AUDIENCE" "${subs%,}" "$READER_POLICY" "$TOKEN_TTL" "$TOKEN_TTL" \
      | bao write "auth/$m/role/$t" - >/dev/null || { log "cluster $c tenant $t: role failed"; return 1; }
  done
  # roles of tenants that left (descriptor removed): role gone now, entity below
  for r in $(bao list "auth/$m/role" 2>/dev/null | sed '1,2d'); do
    case "$tenants" in *" $r "*) ;; *) log "cluster $c: prune role $r (tenant left)"; q delete "auth/$m/role/$r"; pruned="$pruned $r" ;; esac
  done
}
for f in "$IN"/clusters/*.server; do
  [ -e "$f" ] || continue
  c=$(basename "$f" .server)
  label "$c" || { log "skip cluster '$c': not a DNS label"; continue; }
  server=$(cat "$f")
  case "$server" in https://*) ;; *) log "skip cluster $c: API server '$server' is not https"; continue ;; esac
  grep -q 'BEGIN CERTIFICATE' "$IN/clusters/$c.ca" 2>/dev/null || { log "skip cluster $c: no cluster CA"; continue; }
  clusters="$clusters$c "
  if configure_cluster "$c" "$server"; then ok_c="$ok_c $c"; log "cluster $c: tenant auth in place"; else failed_c="$failed_c $c"; fi
done
# entities of tenants that left
# shellcheck disable=SC2086  # word list on purpose
for r in $(printf '%s\n' $pruned | sort -u); do
  case "$tenants" in *" $r "*) ;; *) q delete "identity/entity/name/tenant-$r" || log "prune: entity tenant-$r not deleted" ;; esac
done
# namespace entities tenant-<t>.<c>.<ns> no longer bound (three DNS labels, so the dots are unambiguous)
for en in $(bao list identity/entity/name 2>/dev/null | sed '1,2d' | grep -E '^tenant-[a-z0-9-]+\.[a-z0-9-]+\.[a-z0-9-]+$' || true); do
  case "$bound" in *" $en "*) continue ;; esac
  rest=${en#tenant-}; et=${rest%%.*}; rest=${rest#*.}; ec=${rest%%.*}
  case "$failed_t " in *" $et "*) continue ;; esac              # tenant not configured in this run: keep
  case "$ok_c " in
    *" $ec "*) ;;                                               # cluster configured in this run: $bound is complete
    *) case "$clusters" in " "|*" $ec "*) continue ;; esac ;;   # cluster failed in this run (or no inputs): keep
  esac
  log "prune entity $en (no longer bound)"
  q delete "identity/entity/name/$en" || log "prune: entity $en not deleted"
done
# auth mounts of clusters that left (only with a non-empty member list)
if [ "$clusters" != " " ]; then
  for m in $(bao auth list | awk '{print $1}' | grep '^tenants-' | sed 's#/$##'); do
    case "$clusters" in *" ${m#tenants-} "*) ;; *) log "prune auth $m (cluster left)"; q auth disable "$m" ;; esac
  done
fi

summary="tenants=[${ok_t# }] failed=[${failed_t# }] invalid=[${invalid# }] clusters=[${ok_c# }] failed-clusters=[${failed_c# }]"
[ -n "$ok_t" ] || die "no tenant could be configured $summary"
if [ "$clusters" != " " ] && [ -z "$ok_c" ]; then die "no member cluster could be configured $summary"; fi
[ "$clusters" != " " ] || { status "WARNING: no member clusters (mesh-clients empty): tenants have mounts and writers, no reader auth yet $summary"; exit 0; }
status "done: $summary"
