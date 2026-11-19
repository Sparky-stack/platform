#!/bin/sh
# Demo-only seed of a tenant's OpenBao mount (charts/tenant templates/demo-secrets.yaml, CronJob <project>-demo-secrets;
# docs/multicluster.md "Tenant secrets (OpenBao)"). Runs as the tenant's OWN writer identity (ServiceAccount
# openbao-tenants/<project>-writer, Kubernetes auth role tenant-writer, policy tenant-write = kv-tenant-<project> of its
# own entity only): never root, never another tenant's mount, no Kubernetes API access.
#   SEEDS   space-separated <key>/<property> (the tenant file's demoSecrets)
#   MOUNT   kv-tenant-<project>
# Per seed: a property that already exists is never touched (idempotent; a value written by hand or a rotation wins).
# A missing one gets a generated value "demo-only-<24 hex>" (random per installation, generated inside the pod, never in
# git, never printed): a new key with check-and-set 0 (fails rather than overwrite a concurrent write), a key that exists
# without the property with a patch. Fails (retried next schedule) until tenant-reconcile has created the mount and
# bound the writer alias, i.e. on a clean bootstrap it converges by itself after OpenBao, without blocking any sync.
# Exit status: non-zero for a failed login, an invalid seed or a failed read/write.
set -eu

: "${MOUNT:?}" "${LOGIN_ROLE:?}" "${TOKEN_FILE:?}"
SEEDS=${SEEDS:-}

status() { printf 'seed-demo-secrets: %s\n' "$*"; }

jwt=$(cat "$TOKEN_FILE")
BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role="$LOGIN_ROLE" jwt="$jwt") \
  || { status "login as role $LOGIN_ROLE failed (tenant-reconcile has not bound the writer alias yet?)"; exit 1; }
export BAO_TOKEN
trap 'bao token revoke -self >/dev/null 2>&1 || true' EXIT

value() { printf 'demo-only-%s' "$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

kept="" seeded="" failed=0
for s in $SEEDS; do
  key=${s%%/*} prop=${s#*/}
  case "$key/$prop" in
    */*/* | /* | */ | *[!A-Za-z0-9._/-]*) status "invalid seed '$s' (want <key>/<property>)"; failed=1; continue ;;
  esac
  [ "$key" != "$s" ] || { status "invalid seed '$s' (want <key>/<property>)"; failed=1; continue; }
  if bao kv get -mount="$MOUNT" -field="$prop" "$key" >/dev/null 2>&1; then
    kept="$kept $s"; continue
  fi
  if bao kv metadata get -mount="$MOUNT" "$key" >/dev/null 2>&1; then
    value | bao kv patch -mount="$MOUNT" "$key" "$prop=-" >/dev/null || { status "patch $MOUNT/$key failed"; failed=1; continue; }
  else
    value | bao kv put -mount="$MOUNT" -cas=0 "$key" "$prop=-" >/dev/null || { status "put $MOUNT/$key failed"; failed=1; continue; }
  fi
  seeded="$seeded $s"
done

status "done: mount=$MOUNT seeded=[${seeded# }] kept=[${kept# }]"
exit "$failed"
