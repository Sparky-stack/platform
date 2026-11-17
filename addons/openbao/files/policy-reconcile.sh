#!/bin/sh
# Tenant ACL policies and tenant identities' Kubernetes auth roles from git (addon openbao, #96; docs/multicluster.md
# "Policies from git: the policy reconciler"). Idempotent; run by the CronJob `policy-reconcile`
# (templates/policy-reconcile.yaml). POSIX sh + the bao CLI only (the OpenBao image: busybox, no jq).
#
# One identity: LOGIN_ROLE (policy platform-policy-reconciler, self-initialisation). It may write ACL policies named
# tenant-* and the roles tenant-config / tenant-writer with every parameter pinned - nothing else (no root, no PKI, no
# mesh, no other policy name). Inputs: the ConfigMap only (no Kubernetes API access, no tenant input):
#   $POLICY_DIR/<name>.hcl    files/policies/: written as policy <name> when the stored text differs
# Prune: tenant-* policies that have no file any more (never with zero files: a broken mount must not drop every
# tenant policy). Roles (auth/K8S_MOUNT/role/...), written on every run (idempotent):
#   tenant-config   ServiceAccount CONFIG_NS/CONFIG_SA (CronJob tenant-reconcile), policy tenant-config
#   tenant-writer   any ServiceAccount of WRITER_NS (alias = ServiceAccount name), policy tenant-write
# Exit status: non-zero for a failed login, a policy file that is not tenant-*, no policy file, or a failed write.
set -eu

POLICY_DIR=${POLICY_DIR:-/scripts}
: "${CONFIG_SA:?}" "${CONFIG_NS:?}" "${WRITER_NS:?}" "${AUDIENCE:?}"
ROLE_TTL=${ROLE_TTL:-15m}
K8S_MOUNT=${K8S_MOUNT:-kubernetes}
TERMINATION_LOG=${TERMINATION_LOG:-/dev/termination-log}

log() { printf '%s policy-reconcile: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
status() { log "$*"; { printf '%s\n' "$*" > "$TERMINATION_LOG"; } 2>/dev/null || true; }
die() { status "ERROR: $*"; exit 1; }

if [ -z "${BAO_TOKEN:-}" ]; then
  : "${LOGIN_ROLE:?}" "${TOKEN_FILE:?}"
  BAO_TOKEN=$(bao write -field=token "auth/$K8S_MOUNT/login" role="$LOGIN_ROLE" jwt=@"$TOKEN_FILE") \
    || die "login as $LOGIN_ROLE failed: this OpenBao has no policy reconciler identity (initialised before it existed?) - docs/runbooks/break-glass.md#openbao-local-re-initialization"
  export BAO_TOKEN
fi
# Our own token is short-lived anyway; revoke it when done so nothing usable outlives the run.
trap 'bao token revoke -self >/dev/null 2>&1 || true' EXIT

# --- policies ---------------------------------------------------------------------------------------------------------
desired=" "; written=""; pruned=""
for f in "$POLICY_DIR"/*.hcl; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .hcl)
  printf '%s' "$n" | grep -Eq '^tenant-[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' \
    || die "policy file $n.hcl: only tenant-* policies (DNS label) are reconciled; others are self-init only"
  desired="$desired$n "
  cur=$(bao read -field=policy "sys/policies/acl/$n" 2>/dev/null) || cur=""
  if [ "$cur" != "$(cat "$f")" ]; then
    log "write policy $n"
    bao policy write "$n" "$f" >/dev/null || die "writing policy $n failed"
    written="$written $n"
  fi
done
[ "$desired" != " " ] || die "no policy files in $POLICY_DIR: nothing written, nothing pruned"
existing=$(bao list sys/policies/acl 2>/dev/null | sed '1,2d') || die "listing ACL policies failed"
for n in $existing; do
  case "$n" in tenant-*) ;; *) continue ;; esac
  case "$desired" in *" $n "*) continue ;; esac
  log "prune policy $n (no file in git)"
  bao policy delete "$n" >/dev/null || die "deleting policy $n failed"
  pruned="$pruned $n"
done

# --- roles of the tenant identities -----------------------------------------------------------------------------------
# Written on every run: the reconciler may create/update these two roles only with every parameter given and pinned
# (required_parameters), which also means it cannot read them back to compare. The write is idempotent.
roles=""
ensure_role() { # <role> <key=value>...
  r=$1; shift
  bao write "auth/$K8S_MOUNT/role/$r" "$@" >/dev/null || die "writing role $r failed"
  roles="$roles $r"
}
common="audience=$AUDIENCE token_no_default_policy=true token_ttl=$ROLE_TTL token_max_ttl=$ROLE_TTL"
# shellcheck disable=SC2086  # $common: word list on purpose
ensure_role tenant-config bound_service_account_names="$CONFIG_SA" bound_service_account_namespaces="$CONFIG_NS" \
  token_policies=tenant-config $common
# shellcheck disable=SC2086
ensure_role tenant-writer "bound_service_account_names=*" bound_service_account_namespaces="$WRITER_NS" \
  alias_name_source=serviceaccount_name token_policies=tenant-write $common

# shellcheck disable=SC2086  # normalise the word list
d=$(echo $desired)
status "done: policies=[$d] written=[${written# }] pruned=[${pruned# }] roles=[${roles# }]"
