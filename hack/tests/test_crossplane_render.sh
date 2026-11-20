#!/usr/bin/env bash
# PostgreSQL as a service (addon crossplane, docs/data-services.md "PostgreSQL as a service"):
#   1. selection: the addon ApplicationSet's render for local dev1 opted in (`addons: {crossplane: true}`) installs no
#      XRD / Composition, one Configuration (packages/postgresql) pinned by digest without dependency resolution and
#      EnvironmentConfig platform-postgresql with backend cnpg - from the provider label, no developer input;
#      every backend's addon render (hack/tests/crossplane/values-<backend>.yaml) passes kubeconform -strict with the
#      Crossplane + provider CRD schemas, pins every package by digest and installs only its provider family members;
#   2. `crossplane render` (offline: pinned CLI from mise.toml, the addon's pinned Crossplane image and function packages
#      in Docker) of the package's one Composition with each backend's EnvironmentConfig (from the addon render) and
#      the sample XRs in hack/tests/crossplane (an unknown backend must be a fatal result): composed resources pass kubeconform
#      -strict, HA / backup / deletion policy / Aurora map as documented, and once the cloud reports its endpoint
#      (observed-<backend>.yaml) every backend delivers the same connection Secret shape (<name>-app: host, port,
#      dbname, username, password, uri) with no password in the composed objects.
# Part 2 needs a Linux Docker engine; without one (macOS / Windows CI runners) it is skipped, part 1 still runs.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

ADDON=addons/crossplane
FIX=hack/tests/crossplane
EX=packages/postgresql/examples   # the sample XRs live with the API (one copy)
SCHEMAS_DIR=$(native_path "${SCHEMAS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/koorikla-platform/schemas}")
[[ -d "$SCHEMAS_DIR/rds.aws.m.upbound.io" ]] || SCHEMAS_DIR="$SCHEMAS_DIR" ./hack/schemas.sh >/dev/null
[[ -d "$ADDON/charts" ]] || helm dependency build "$ADDON" >/dev/null
kc() { assert_eq "$(kc_valid "$1")" yes "$2 passes kubeconform -strict"; }   # kc <file> <label>
COMP=packages/postgresql/apis/postgresql/composition.yaml
# Release tags only (release-please postgresql-vX.Y.Z -> image tag vX.Y.Z): `main` / short SHAs move or are not releases.
CFG_RE='^ghcr\.io/koorikla/platform/postgresql:v[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$'
PKG_RE='^(xpkg\.crossplane\.io/crossplane(-contrib)?/[a-z0-9-]+:v[0-9]+\.[0-9]+\.[0-9]+|ghcr\.io/koorikla/platform/[a-z0-9_-]+:[a-z0-9.-]+)@sha256:[0-9a-f]{64}$'

# --- 1a. selection through the ApplicationSet for local dev1 ------------------------------------------------------------
render_platform local "$TMP/platform.yaml"
assert_eq "$(yq '.addons.crossplane.default' charts/platform/values.yaml)" false "catalog: crossplane is opt-in"
assert_eq "$(yq -o=json -I=0 '.addons.crossplane.roles' charts/platform/values.yaml)" '["workload"]' "catalog: crossplane targets workload clusters"
render_layered_addon local crossplane "$TMP/dev1.yaml" "$TMP/platform.yaml" workload dev1 docker development local cilium \
  https://192.0.2.10:6443
assert_eq "$(yq -N 'select(.kind == "Composition" or .kind == "CompositeResourceDefinition") | .kind' "$TMP/dev1.yaml")" "" \
  "dev1: the addon renders no XRD / Composition (they come from the Configuration package)"
assert_eq "$(yq -N 'select(.kind == "Configuration") | .spec.package' "$TMP/dev1.yaml" | grep -cE "$CFG_RE" || true)" 1 \
  "dev1: one Configuration, ghcr.io/koorikla/platform/postgresql pinned tag@digest"
cfg_tag=$(yq -N 'select(.kind == "Configuration") | .spec.package' "$TMP/dev1.yaml" | sed -E 's/.*:(v[^@]+)@.*/\1/')
fn_tag=$(yq -N 'select(.kind == "Function" and .metadata.name == "koorikla-platform-postgresqlcompose-postgresql") | .spec.package' \
  "$TMP/dev1.yaml" | grep -E '^ghcr\.io/koorikla/platform/postgresql_compose-postgresql:v[0-9.]+@sha256:[0-9a-f]{64}$' \
  | sed -E 's/.*:(v[^@]+)@.*/\1/')
assert_eq "$fn_tag" "$cfg_tag" "dev1: compose-postgresql is pinned at the Configuration's release tag (published together)"
assert_eq "$(yq -N 'select(.kind == "Configuration") | .spec.skipDependencyResolution' "$TMP/dev1.yaml")" true \
  "dev1: the Configuration skips dependency resolution (the addon pins Functions / Providers)"
assert_eq "$(yq -N 'select(.kind == "EnvironmentConfig" and .metadata.name == "platform-postgresql") | .data.backend' "$TMP/dev1.yaml")" \
  cnpg "dev1 (provider docker): EnvironmentConfig platform-postgresql selects cnpg"
assert_eq "$(yq -N 'select(.kind == "Function") | .metadata.name' "$TMP/dev1.yaml" | tr -d '\r' | sort | tr '\n' ' ')" \
  "function-auto-ready function-environment-configs function-go-templating koorikla-platform-postgresqlcompose-postgresql " \
  "dev1: the Functions of the Composition, its embedded compose-postgresql included"
assert_eq "$(yq -N 'select(.kind == "ValidatingPolicy" and .metadata.name == "postgresql-production-ha-backup") | .spec.validationActions[0]' "$TMP/dev1.yaml")" \
  Audit "dev1: values/provider-docker.yaml makes the production rule Audit (layered like the ApplicationSet)"

# Pod Security restricted on everything that runs in crossplane-system: the chart's Deployments (containers + init
# containers) and the pod template of every DeploymentRuntimeConfig (Functions, providers), plus the namespace label.
psa=$(yq -o=json -I=0 'select(.kind == "Deployment" or .kind == "DeploymentRuntimeConfig")' "$TMP/dev1.yaml" | py -c '
import json, sys
bad = []
for line in sys.stdin:
    if not line.strip():
        continue
    o = json.loads(line)
    spec = (o["spec"]["deploymentTemplate"]["spec"] if o["kind"] == "DeploymentRuntimeConfig" else o["spec"])["template"]["spec"]
    psc = spec.get("securityContext") or {}
    for c in (spec.get("initContainers") or []) + spec["containers"]:
        sc, who = c.get("securityContext") or {}, o["kind"] + "/" + o["metadata"]["name"] + "/" + c["name"]
        if sc.get("allowPrivilegeEscalation") is not False: bad.append(who + ": allowPrivilegeEscalation")
        if "ALL" not in ((sc.get("capabilities") or {}).get("drop") or []): bad.append(who + ": capabilities")
        if sc.get("runAsNonRoot", psc.get("runAsNonRoot")) is not True: bad.append(who + ": runAsNonRoot")
        if (sc.get("seccompProfile") or psc.get("seccompProfile") or {}).get("type") != "RuntimeDefault": bad.append(who + ": seccomp")
    if spec.get("hostNetwork"): bad.append(o["metadata"]["name"] + ": hostNetwork")
print(" ".join(bad))')
assert_eq "$psa" "" "dev1: Crossplane core, RBAC manager and package runtime configs meet Pod Security restricted"
assert_eq "$(yq -N 'select(.kind == "Namespace") | .metadata.labels["pod-security.kubernetes.io/enforce"]' "$TMP/dev1.yaml")" \
  restricted "dev1: crossplane-system enforces Pod Security restricted"

# --- 1b. every backend's addon render ----------------------------------------------------------------------------------
BACKENDS="cnpg aws-rds gcp-cloudsql azure-flexible"
for b in $BACKENDS; do
  if [[ "$b" == cnpg ]]; then
    render_standalone_addon crossplane "$TMP/addon-cnpg.yaml"
  else
    helm template crossplane "$ADDON" --namespace crossplane-system -f "$FIX/values-$b.yaml" > "$TMP/addon-$b.yaml"
  fi
  kc "$TMP/addon-$b.yaml" "addon render ($b)"
  assert_eq "$(yq -N 'select(.kind == "EnvironmentConfig") | .data.backend' "$TMP/addon-$b.yaml" | tr '\n' ' ')" \
    "$b " "$b: exactly one EnvironmentConfig, backend $b"
  bad=""
  while IFS= read -r ref; do
    [[ -z "$ref" || "$ref" =~ $PKG_RE ]] || bad="$bad $ref"
  done < <(yq -N 'select(.kind == "Function" or .kind == "Provider") | .spec.package' "$TMP/addon-$b.yaml" | tr -d '\r')
  assert_eq "$bad" "" "$b: every Function / Provider package is pinned by digest"
  want=$(yq -N ".packages.providers[\"$b\"] | keys | .[]" "$ADDON/values.yaml" | tr -d '\r' | sort | tr '\n' ' ')
  got=$(yq -N 'select(.kind == "Provider") | .metadata.name' "$TMP/addon-$b.yaml" | tr -d '\r' | sort | tr '\n' ' ')
  assert_eq "$got" "$want" "$b: installs exactly its provider family members"
  # The composed managed resources (MRAP) are exactly the kinds the Composition renders (checked in part 2).
  yq -N 'select(.kind == "ManagedResourceActivationPolicy") | .spec.activate[]' "$TMP/addon-$b.yaml" | tr -d '\r' | sort \
    > "$TMP/mrap-$b.txt"
  yq 'select(.kind == "EnvironmentConfig")' "$TMP/addon-$b.yaml" > "$TMP/env-$b.yaml"
done
helm template crossplane "$ADDON" --namespace crossplane-system -f "$FIX/values-cnpg-backup.yaml" \
  | yq 'select(.kind == "EnvironmentConfig")' > "$TMP/env-cnpg-backup.yaml"
if out=$(helm template crossplane "$ADDON" --namespace crossplane-system -f "$FIX/values-aws-rds.yaml" \
  --set postgresql.aws.vpcId= 2>&1); then
  assert_eq rendered fails "aws-rds without vpcId fails the render"
else
  assert_match "$out" "postgresql.aws.vpcId is required" "aws-rds without vpcId fails the render (required fact)"
fi
cp packages/postgresql/apis/postgresql/definition.yaml "$TMP/xrd.yaml"
yq '.data.backend = "mysql"' "$TMP/env-cnpg.yaml" > "$TMP/env-unknown.yaml"

# --- 2. crossplane render ---------------------------------------------------------------------------------------------
if ! command -v crossplane >/dev/null 2>&1; then
  echo "  SKIP crossplane render: crossplane CLI not found (mise install)"
  finish; exit 0
fi
if [[ "$(docker info --format '{{.OSType}}' 2>/dev/null | tr -d '\r')" != linux ]]; then
  echo "  SKIP crossplane render: needs a Linux Docker engine (functions run as containers)"
  finish; exit 0
fi
XP_IMAGE="$(yq -r '.crossplane.image.repository + ":" + .crossplane.image.tag' "$ADDON/values.yaml" | tr -d '\r')"
# One Docker network and one container per Function for the whole run, shared by every render. Left to itself each
# `crossplane render` creates its own bridge network (crossplane-render-<random>) plus fresh function containers, and
# leaves both behind when it is killed: ten renders per run, several runs at once on a shared Docker host and the leaked
# networks of killed runs exhaust Docker's default address pools (~30 networks) and renders fail with "all predefined
# address pools have been fully subnetted". The run's network and containers carry its name, are removed on exit
# (including INT / TERM), and a later run removes those of runs whose process is gone (SIGKILL).
XP_LABEL=koorikla.platform/test=crossplane-render
XP_HOST=$(uname -n)
XP_NET="koorikla-xp-render-$$-$RANDOM"
XP_RENDER_JOBS=${XP_RENDER_JOBS:-4}   # parallel renders (each one starts the render engine container)
xp_cleanup_run() {   # xp_cleanup_run <network>: remove the run's containers, then its network
  local ids
  ids=$( (docker ps -aq --filter "name=$1-"; docker ps -aq --filter "network=$1") 2>/dev/null | sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086 # word-split container ids
  [[ -z "${ids// /}" ]] || docker rm -f $ids >/dev/null 2>&1 || true
  docker network rm "$1" >/dev/null 2>&1 || true
}
xp_cleanup() {
  local pids
  pids=$(jobs -p)
  # shellcheck disable=SC2086 # word-split pids
  [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
  xp_cleanup_run "$XP_NET"
  [[ -z "${XP_FN_IMAGE:-}" ]] || docker rmi -f "$XP_FN_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap xp_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while read -r net pid host; do
  [[ -n "$net" && "$host" == "$XP_HOST" ]] || continue
  kill -0 "$pid" 2>/dev/null || xp_cleanup_run "$net"
done < <(docker network ls --filter "label=$XP_LABEL" \
  --format '{{.Name}} {{.Label "koorikla.platform/owner-pid"}} {{.Label "koorikla.platform/owner-host"}}' | tr -d '\r')
if ! out=$(docker network create --label "$XP_LABEL" --label "koorikla.platform/owner-pid=$$" \
  --label "koorikla.platform/owner-host=$XP_HOST" "$XP_NET" 2>&1); then
  echo "$out" >&2
  echo "  hint: $(docker network ls -q | wc -l | tr -d ' ') Docker networks exist; networks left by killed renders:" \
    "docker network ls --filter name=crossplane-render- (remove only those without containers you own)" >&2
  assert_eq failed ok "crossplane render: create the run's Docker network $XP_NET"
  finish; exit 1
fi
# The embedded function compose-postgresql, built from the working tree's templates exactly like `crossplane project
# build` does (CLI 2.4.1: FROM function-go-templating v0.12.0, templates in /src): renders test the templates you edit.
XP_FN=koorikla-platform-postgresqlcompose-postgresql
XP_FN_IMAGE="koorikla.local/postgresql_compose-postgresql:render-$$"
if ! out=$(printf '%s\n' \
  'FROM xpkg.crossplane.io/crossplane-contrib/function-go-templating:v0.12.0@sha256:ec55f6817a88c884a33158e7f50d7356405ef4d4e7efb00fd1a0e136275d9c54' \
  'COPY . /src' 'ENV FUNCTION_GO_TEMPLATING_DEFAULT_SOURCE=/src' \
  | retry_with_backoff 3 2 docker build -q -t "$XP_FN_IMAGE" -f - packages/postgresql/functions/compose-postgresql 2>&1); then
  echo "$out" >&2
  assert_eq failed ok "crossplane render: build the embedded function image"
  finish; exit 1
fi
printf 'apiVersion: pkg.crossplane.io/v1\nkind: Function\nmetadata:\n  name: %s\nspec:\n  package: %s\n' \
  "$XP_FN" "$XP_FN_IMAGE" > "$TMP/embedded-function.yaml"
# The addon's own Function objects (same pinned packages; its published compose-postgresql replaced by the local build),
# run as the run's named containers on its network; the first render starts them, the others reuse them (Orphan: the
# render leaves them running, xp_cleanup removes them). Container names stay <= 63 chars (a DNS label: the engine dials
# them by name; a longer one hangs the render), hence the embedded function's container is named after compose-postgresql.
yq 'select(.kind == "Function" and .metadata.name != "'"$XP_FN"'")' "$TMP/addon-cnpg.yaml" > "$TMP/addon-functions.yaml"
printf -- '---\n' >> "$TMP/addon-functions.yaml"; cat "$TMP/embedded-function.yaml" >> "$TMP/addon-functions.yaml"
XP_NET="$XP_NET" yq 'select(.kind == "Function")
  | .metadata.annotations["render.crossplane.io/runtime-docker-pull-policy"] = "IfNotPresent"
  | .metadata.annotations["render.crossplane.io/runtime-docker-network"] = strenv(XP_NET)
  | .metadata.annotations["render.crossplane.io/runtime-docker-name"] = strenv(XP_NET) + "-" + (.metadata.name | sub("^koorikla-platform-postgresql", ""))
  | .metadata.annotations["render.crossplane.io/runtime-docker-cleanup"] = "Orphan"' "$TMP/addon-functions.yaml" \
  > "$TMP/functions.yaml"
# Pull every image once, serially and with retries, before the parallel renders: ten renders pulling the same images
# at once from xpkg.crossplane.io get connection resets (#140). The renders then find them locally (IfNotPresent).
pkgs=()
read_lines pkgs yq -N -r '.spec.package' "$TMP/functions.yaml"
for img in "$XP_IMAGE" ${pkgs[@]+"${pkgs[@]}"}; do
  [[ -n "$img" && "$img" != null && "$img" != "$XP_FN_IMAGE" ]] || continue
  docker image inspect "$img" >/dev/null 2>&1 || retry_with_backoff 4 2 docker pull -q "$img" >/dev/null
done

# render_one <case> <EnvironmentConfig> <xr> [observed]: crossplane composition render (one retry for a transient
# registry/Docker error; a real render failure fails both attempts, the stderr of both is kept for render())
render_one() {
  local c=$1 env=$2 xr=$3 obs=${4:-} args=()
  [[ -n "$obs" ]] && args=(--observed-resources "$obs")
  retry_with_backoff 2 2 crossplane composition render "$xr" "$COMP" --extra-resources "$env" "$TMP/functions.yaml" --xrd "$TMP/xrd.yaml" \
    --crossplane-image "$XP_IMAGE" ${args[@]+"${args[@]}"} > "$TMP/render-$c.yaml" 2> "$TMP/render-$c.err" \
    && : > "$TMP/render-$c.ok"
}
# render_bg: render_one in the background, at most XP_RENDER_JOBS at a time (bash 3.2: no `wait -n`)
render_bg() {
  while [[ $(jobs -rp | wc -l) -ge $XP_RENDER_JOBS ]]; do sleep 0.2; done
  render_one "$@" &
}
render_one cnpg-minimal "$TMP/env-cnpg.yaml" "$EX/xr-minimal.yaml" || true   # starts the function containers
render_bg cnpg-production "$TMP/env-cnpg.yaml" "$EX/xr-production.yaml"
render_bg cnpg-backup "$TMP/env-cnpg-backup.yaml" "$EX/xr-production.yaml"
render_bg aws-minimal "$TMP/env-aws-rds.yaml" "$EX/xr-minimal.yaml"
render_bg aws-production "$TMP/env-aws-rds.yaml" "$EX/xr-production.yaml" "$FIX/observed-aws-rds.yaml"
render_bg aws-aurora "$TMP/env-aws-rds.yaml" "$EX/xr-aurora.yaml" "$FIX/observed-aws-rds.yaml"
render_bg gcp-minimal "$TMP/env-gcp-cloudsql.yaml" "$EX/xr-minimal.yaml"
render_bg gcp-production "$TMP/env-gcp-cloudsql.yaml" "$EX/xr-production.yaml" "$FIX/observed-gcp-cloudsql.yaml"
render_bg azure-minimal "$TMP/env-azure-flexible.yaml" "$EX/xr-minimal.yaml"
render_bg azure-production "$TMP/env-azure-flexible.yaml" "$EX/xr-production.yaml" "$FIX/observed-azure-flexible.yaml"
render_bg unknown-backend "$TMP/env-unknown.yaml" "$EX/xr-minimal.yaml"
wait
# XP_RENDER_OUT=<dir>: keep every case's raw render (diff renders before/after a template change).
if [[ -n "${XP_RENDER_OUT:-}" ]]; then mkdir -p "$XP_RENDER_OUT" && cp "$TMP"/render-*.yaml "$XP_RENDER_OUT"/; fi

# render <case>: the render_bg result of that case -> composed resources $TMP/out-<case>.yaml, XR $TMP/xr-<case>.yaml
render() {
  local c=$1
  if [[ ! -f "$TMP/render-$c.ok" ]]; then
    cat "$TMP/render-$c.err" >&2
    assert_eq failed ok "crossplane render $c"
    : > "$TMP/out-$c.yaml"; : > "$TMP/xr-$c.yaml"
    return 0
  fi
  yq 'select(.kind != "PostgreSQL")' "$TMP/render-$c.yaml" > "$TMP/out-$c.yaml"
  yq 'select(.kind == "PostgreSQL")' "$TMP/render-$c.yaml" > "$TMP/xr-$c.yaml"
  kc "$TMP/out-$c.yaml" "crossplane render $c: composed resources"
  assert_eq "$(yq -N '.status.conditions[] | select(.type == "Synced") | .status' "$TMP/xr-$c.yaml")" True \
    "crossplane render $c: XR Synced"
}
q() { yq -N "$1" "$2" | tr -d '\r' | sed '/^$/d'; }   # q <expr> <file> (blank lines of non-matching documents dropped)
kinds() { yq -N '.kind' "$1" | tr -d '\r' | sort | uniq -c | awk '{print $2 "=" $1}' | tr '\n' ' '; }
# secret_shape <case>: the connection Secret keys an app receives, "cnpg-operator" when the operator writes it.
secret_shape() {
  local es
  es=$(yq 'select(.kind == "ExternalSecret")' "$TMP/out-$1.yaml")
  if [[ -z "$es" ]]; then echo none; return; fi
  printf '%s\n' "$es" | yq -N '.spec.target.template.data | keys | .[]' | tr -d '\r' | sort | tr '\n' ' '
}
SHAPE="dbname host password port uri username "
assert_mrap() {   # assert_mrap <case> <backend>: every composed managed resource kind is activated on its clusters
  local missing
  missing=$(yq -N 'select(.apiVersion | test("\\.m\\.upbound\\.io/")) | (.kind | downcase) + "s." + (.apiVersion | sub("/.*$"; ""))' \
    "$TMP/out-$1.yaml" | tr -d '\r' | sort -u | grep -Fxv -f "$TMP/mrap-$2.txt" || true)
  assert_eq "$missing" "" "$1: every composed managed resource kind is activated by the MRAP"
}

# cnpg
# An EnvironmentConfig with a backend the Composition does not know: a fatal result naming it, nothing composed.
if [[ -f "$TMP/render-unknown-backend.ok" ]]; then
  assert_eq rendered fatal "unknown backend: the Composition returns a fatal result"
else
  assert_match "$(cat "$TMP/render-unknown-backend.err")" 'unknown backend \\"mysql\\"|unknown backend "mysql"' \
    "unknown backend: the Composition returns a fatal result naming it"
fi
render cnpg-minimal
assert_eq "$(kinds "$TMP/out-cnpg-minimal.yaml")" "Cluster=1 PodMonitor=1 " "cnpg minimal: a CNPG Cluster + its PodMonitor"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.instances' "$TMP/out-cnpg-minimal.yaml")" 1 "cnpg minimal: 1 instance"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.imageCatalogRef.name + ":" + (.spec.imageCatalogRef.major | tostring)' "$TMP/out-cnpg-minimal.yaml")" \
  "postgresql-standard:17" "cnpg minimal: image from ClusterImageCatalog postgresql-standard, major 17 (default)"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.bootstrap.initdb.database + "/" + .spec.bootstrap.initdb.owner' "$TMP/out-cnpg-minimal.yaml")" \
  app/app "cnpg minimal: database app owned by role app"
assert_eq "$(q '.status.secretName + " " + .status.endpoint + " " + (.status.port | tostring) + " " + .status.backup' "$TMP/xr-cnpg-minimal.yaml")" \
  "orders-db-app orders-db-rw.dp-default-shop-development-1a2b3c4d.svc 5432 disabled" \
  "cnpg minimal: XR status points at the operator's <name>-app Secret and the -rw Service"
render cnpg-production
assert_eq "$(q 'select(.kind == "Cluster") | .spec.instances' "$TMP/out-cnpg-production.yaml")" 3 "cnpg HA: 3 instances"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.imageCatalogRef.major' "$TMP/out-cnpg-production.yaml")" 18 "cnpg: version 18 -> major 18"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.storage.size + " " + .spec.resources.requests.memory' "$TMP/out-cnpg-production.yaml")" \
  "50Gi 1Gi" "cnpg: storageGiB 50, size M"
assert_eq "$(q '.status.backup' "$TMP/xr-cnpg-production.yaml")" unavailable \
  "cnpg: backup asked for on a cluster without an object store -> status.backup unavailable, no ScheduledBackup"
assert_eq "$(kinds "$TMP/out-cnpg-production.yaml")" "Cluster=1 PodMonitor=1 " "cnpg without object store: no backup objects"
render cnpg-backup
assert_eq "$(kinds "$TMP/out-cnpg-backup.yaml")" "Cluster=1 ObjectStore=1 PodMonitor=1 ScheduledBackup=1 " \
  "cnpg with object store: Barman Cloud ObjectStore + ScheduledBackup"
assert_eq "$(q 'select(.kind == "ObjectStore") | .spec.configuration.destinationPath + " " + .spec.retentionPolicy' "$TMP/out-cnpg-backup.yaml")" \
  "s3://example-pg-backups/postgresql/dev1/dp-default-shop-production-5e6f7a8b/orders-db 14d" \
  "cnpg backup: per cluster/namespace/name prefix, retentionDays -> retentionPolicy"
assert_eq "$(q 'select(.kind == "Cluster") | .spec.plugins[0].name + " " + .spec.serviceAccountTemplate.metadata.annotations["eks.amazonaws.com/role-arn"]' "$TMP/out-cnpg-backup.yaml")" \
  "barman-cloud.cloudnative-pg.io arn:aws:iam::111111111111:role/pg-backups" \
  "cnpg backup: WAL archiving through the plugin under the cluster's workload identity"
assert_eq "$(q '.status.backup' "$TMP/xr-cnpg-backup.yaml")" enabled "cnpg backup: status.backup enabled"

# aws-rds
render aws-minimal
assert_eq "$(kinds "$TMP/out-aws-minimal.yaml")" "Instance=1 Key=1 SecurityGroup=1 SecurityGroupIngressRule=1 SubnetGroup=1 " \
  "aws minimal: instance, KMS key, security group + rule, subnet group; no connection Secret before the endpoint exists"
assert_mrap aws-minimal aws-rds
f="$TMP/out-aws-minimal.yaml"
assert_eq "$(q 'select(.kind == "Instance") | [.spec.forProvider.multiAz, .spec.forProvider.manageMasterUserPassword, .spec.forProvider.iamDatabaseAuthenticationEnabled, .spec.forProvider.storageEncrypted, .spec.forProvider.publiclyAccessible, .spec.forProvider.deletionProtection] | join(" ")' "$f")" \
  "false true true true false true" "aws minimal: single-AZ, RDS-managed master password, IAM auth, encrypted, private, deletion protection (Retain)"
assert_eq "$(q 'select(.kind == "Instance") | .spec.managementPolicies | join(",")' "$f")" "Observe,Create,Update,LateInitialize" \
  "aws: deletionPolicy Retain (default) -> Crossplane never deletes the instance"
assert_eq "$(q 'select(.kind == "Instance") | .spec.forProvider.engineVersion + " " + .spec.forProvider.instanceClass + " " + (.spec.forProvider.allocatedStorage | tostring)' "$f")" \
  "17 db.t4g.medium 10" "aws minimal: version 17, size S, 10 GiB"
assert_eq "$(q 'select(.kind == "SecurityGroupIngressRule") | .spec.forProvider.referencedSecurityGroupId + ":" + (.spec.forProvider.fromPort | tostring)' "$f")" \
  "sg-0123456789abcdef0:5432" "aws: 5432 only from the cluster's node security group"
ext=$(q 'select(.kind == "Instance") | .metadata.annotations["crossplane.io/external-name"]' "$f")
assert_match "$ext" '^pg-[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{8}$' "aws: RDS identifier pg-<namespace>-<name>-<hash>, no double hyphens"
assert_match "${#ext}" '^([1-4][0-9]|5[0-2])$' "aws: RDS identifier <= 52 characters ($ext)"
assert_eq "$(q '.status.secretName // "none"' "$TMP/xr-aws-minimal.yaml")" none "aws: no secretName before RDS reports the endpoint"
render aws-production
f="$TMP/out-aws-production.yaml"
assert_eq "$(q 'select(.kind == "Instance") | [.spec.forProvider.multiAz, .spec.forProvider.backupRetentionPeriod, .spec.forProvider.engineVersion, .spec.forProvider.instanceClass, .spec.forProvider.skipFinalSnapshot] | join(" ")' "$f")" \
  "true 14 18 db.m7g.large false" "aws HA: Multi-AZ instance, 14 days backups, version 18, size M, final snapshot"
assert_eq "$(q 'select(.kind == "Instance") | .spec.managementPolicies | join(",")' "$f")" "*" "aws: deletionPolicy Delete -> full management"
assert_eq "$(secret_shape aws-production)" "$SHAPE" "aws: connection Secret keys host, port, dbname, username, password, uri"
assert_eq "$(q 'select(.kind == "ExternalSecret") | .spec.data[0].remoteRef.key + " " + .spec.secretStoreRef.name' "$f")" \
  "arn:aws:secretsmanager:eu-central-1:111111111111:secret:rds!db-0f0e0d0c-aaaa-bbbb-cccc-123456789abc-AbCdEf default" \
  "aws: ESO reads the RDS-managed master secret through ClusterSecretStore default"
assert_eq "$(q '.status.secretName + " " + .status.endpoint' "$TMP/xr-aws-production.yaml")" \
  "orders-db-app pg-example.cluster-abcdefghijkl.eu-central-1.rds.amazonaws.com" "aws: XR status endpoint + secretName"
render aws-aurora
assert_eq "$(kinds "$TMP/out-aws-aurora.yaml")" "Cluster=1 ClusterInstance=2 ExternalSecret=1 Key=1 SecurityGroup=1 SecurityGroupIngressRule=1 SubnetGroup=1 " \
  "aws engine aurora + HA: Aurora cluster with writer + reader, no RDS instance"
assert_mrap aws-aurora aws-rds
assert_eq "$(q 'select(.kind == "Cluster") | .spec.forProvider.engine + " " + (.spec.forProvider.manageMasterUserPassword | tostring)' "$TMP/out-aws-aurora.yaml")" \
  "aurora-postgresql true" "aurora: engine aurora-postgresql, RDS-managed master password"
assert_eq "$(secret_shape aws-aurora)" "$SHAPE" "aurora: same connection Secret shape"

# gcp-cloudsql
render gcp-minimal
f="$TMP/out-gcp-minimal.yaml"
assert_eq "$(kinds "$f")" "Database=1 DatabaseInstance=1 Password=1 " "gcp minimal: instance, database, password generator; user + Secret wait for the IP"
assert_mrap gcp-minimal gcp-cloudsql
assert_eq "$(q 'select(.kind == "DatabaseInstance") | [.spec.forProvider.databaseVersion, .spec.forProvider.settings.availabilityType, .spec.forProvider.settings.tier, .spec.forProvider.settings.ipConfiguration.ipv4Enabled, .spec.forProvider.settings.ipConfiguration.sslMode, .spec.forProvider.settings.databaseFlags[0].name] | join(" ")' "$f")" \
  "POSTGRES_17 ZONAL db-custom-1-3840 false ENCRYPTED_ONLY cloudsql.iam_authentication" \
  "gcp minimal: POSTGRES_17, zonal, size S, private IP only, TLS required, IAM database authentication"
render gcp-production
f="$TMP/out-gcp-production.yaml"
assert_eq "$(q 'select(.kind == "DatabaseInstance") | [.spec.forProvider.databaseVersion, .spec.forProvider.settings.availabilityType, .spec.forProvider.settings.backupConfiguration.pointInTimeRecoveryEnabled, .spec.forProvider.settings.backupConfiguration.backupRetentionSettings.retainedBackups] | join(" ")' "$f")" \
  "POSTGRES_18 REGIONAL true 14" "gcp HA: REGIONAL, PITR, 14 backups"
assert_eq "$(kinds "$f")" "Database=1 DatabaseInstance=1 ExternalSecret=1 Password=1 User=1 " "gcp: once the IP is known, Secret + owner user"
assert_eq "$(secret_shape gcp-production)" "$SHAPE" "gcp: connection Secret keys host, port, dbname, username, password, uri"
assert_eq "$(q 'select(.kind == "ExternalSecret") | .spec.target.template.data.host + " " + .spec.refreshPolicy' "$f")" \
  "192.0.2.25 CreatedOnce" "gcp: host = private IP, password generated once by ESO"
assert_eq "$(q 'select(.kind == "User") | .spec.forProvider.passwordSecretRef.name + "/" + .spec.forProvider.passwordSecretRef.key' "$f")" \
  "orders-db-app/password" "gcp: the provider reads the owner password from the connection Secret"

# azure-flexible
render azure-minimal
f="$TMP/out-azure-minimal.yaml"
assert_eq "$(kinds "$f")" "ExternalSecret=1 FlexibleServer=1 FlexibleServerDatabase=1 Password=1 " \
  "azure minimal: server, database, password generator + Secret (the server needs the password at creation)"
assert_mrap azure-minimal azure-flexible
assert_eq "$(q 'select(.kind == "FlexibleServer") | [.spec.forProvider.version, .spec.forProvider.storageMb, .spec.forProvider.publicNetworkAccessEnabled, .spec.forProvider.authentication.activeDirectoryAuthEnabled, (.spec.forProvider.highAvailability // "none")] | join(" ")' "$f")" \
  "17 32768 false true none" "azure minimal: v17, smallest storage (32 GiB), VNet only, Entra auth on, no HA"
assert_eq "$(secret_shape azure-minimal)" "$SHAPE" "azure: connection Secret keys host, port, dbname, username, password, uri"
render azure-production
f="$TMP/out-azure-production.yaml"
assert_eq "$(q 'select(.kind == "FlexibleServer") | [.spec.forProvider.highAvailability.mode, .spec.forProvider.storageMb, .spec.forProvider.backupRetentionDays, .spec.forProvider.skuName] | join(" ")' "$f")" \
  "ZoneRedundant 65536 14 GP_Standard_D4ds_v5" "azure HA: zone-redundant, 50 GiB -> 64 GiB tier, 14 days, size M"
assert_eq "$(q '.status.endpoint + " " + .status.secretName' "$TMP/xr-azure-production.yaml")" \
  "pg-example.postgres.database.azure.com orders-db-app" "azure: XR status endpoint from the server's FQDN"

# No composed object carries a password value: only ESO template references.
leaks=$(cat "$TMP"/out-*.yaml | yq -N '.. | select(tag == "!!map") | to_entries[] | select(.key | test("(?i)^password$")) | .value | select(tag == "!!str")' \
  | tr -d '\r' | grep -v '^{{ .password }}$' || true)
assert_eq "$leaks" "" "no composed object contains a password value (ESO templates only)"

finish
