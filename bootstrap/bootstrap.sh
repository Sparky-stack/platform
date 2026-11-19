#!/usr/bin/env bash
# Idempotent bootstrap entrypoint for koorikla/platform.
# Usage: bootstrap/bootstrap.sh [--inst <name>] [up|secrets|argocd|status|down]
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../hack/lib/portable.sh
source hack/lib/portable.sh

INST="${INST:-local}"
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inst)
      INST="${2:-}"
      shift 2
      ;;
    up|secrets|argocd|status|ui|down)
      CMD="$1"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: bootstrap/bootstrap.sh [--inst <name>] [up|secrets|argocd|status|ui|down]

Subcommands:
  up       Run full bootstrap (k3d mgmt for local, secrets, Argo CD, root-app) [default]
  secrets  Seed/refresh local platform-secrets (no-op if backend != kubernetes). GitHub creds from env, least
           privilege first: GITHUB_APP_ID/GITHUB_APP_INSTALLATION_ID/GITHUB_APP_PRIVATE_KEY_FILE,
           PLATFORM_GITHUB_TOKEN [PLATFORM_GITHUB_USER] (GITHUB_TOKEN accepted with a warning), else gh CLI
           (NO_GH=1 skips); GHCR_TOKEN/GHCR_USER; push App GITHUB_PUSH_APP_* (docs/forking.md); provider byo
           clusters: BYO_KUBECONFIG_<NAME> or the k3d cluster of that name (docs/providers.md)
  argocd   Install/upgrade Argo CD via Helm, seed the bootstrap repo secret until ESO's repo-creds is Ready (then
           delete it), apply root-app. `up` waits REPO_CREDS_WAIT seconds (default 600, 0 skips) for that hand-over
  status   Show clusters, Argo CD apps, and UI info (how to read the admin password; never the password)
  ui       Port-forward argocd-server on localhost:8081 (prints how to read the admin password, not the password)
  down     Freeze Argo CD, delete CAPD workload clusters (if any), then k3d platform-mgmt (local only)
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

CMD="${CMD:-up}"
INST_FILE="installations/${INST}/installation.yaml"
[[ -f "$INST_FILE" ]] || { echo "ERROR: installation file not found: $INST_FILE" >&2; exit 1; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

load_inst() {
  local -a _inst=()
  read_lines _inst yq -r '(.secrets.backend // "kubernetes"), (.installation.repoURL // "https://github.com/koorikla/platform.git"), (.installation.githubOrg // ""), (.installation.revision // "HEAD")' "$INST_FILE"
  BACKEND="${_inst[0]}"
  REPO_URL="${_inst[1]}"
  GITHUB_ORG="${_inst[2]}"
  REVISION="${_inst[3]}"
  if [[ "$INST" == "local" ]]; then
    CTX="${KUBE_CTX:-k3d-platform-mgmt}"
  else
    CTX="${KUBE_CTX:-$(kubectl config current-context)}"
  fi
}

require_bins() {
  local bin missing=()
  for bin in "$@"; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done
  (( ${#missing[@]} == 0 )) || die "missing required tools: ${missing[*]}"
}

ensure_k3d() {
  [[ "$INST" == "local" ]] || return 0
  require_bins docker k3d kubectl
  docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
  local free
  free=$(free_gb .)
  if [[ -n "$free" ]] && (( free < 15 )); then
    warn "Low free disk space (${free}GB < 15GB recommended for k3d + CAPD images)"
  fi
  # inotify limits matter where the containers run: the host on native Linux, the Docker Desktop / WSL2 VM elsewhere
  # (raise them there, see docs/dev-environment.md). Only the native Linux host can be checked from here.
  local watches
  watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  if [[ "$(os_name)" == linux && -n "$watches" ]] && (( watches > 0 && watches < 524288 )); then
    warn "fs.inotify.max_user_watches=${watches} (< 524288 recommended for multi-cluster k3s/CAPD)"
  fi
  docker network inspect kind >/dev/null 2>&1 || {
    log "Creating docker network 'kind' for CAPD + k3d"
    docker network create kind >/dev/null
  }
  if k3d cluster list -o json | yq -e '.[] | select(.name == "platform-mgmt")' >/dev/null 2>&1; then
    log "k3d cluster 'platform-mgmt' already exists"
  else
    log "Creating k3d cluster 'platform-mgmt'"
    k3d cluster create --config bootstrap/k3d-mgmt.yaml
  fi
  kubectl --context "$CTX" wait --for=condition=Ready node --all --timeout=3m >/dev/null
}

# Every object bootstrap writes goes through kapply: server-side apply with its own field manager. Fields it stops
# sending are pruned (switching platform-github from token to GitHub App leaves no stale token) and, unlike client-side
# apply, no kubectl.kubernetes.io/last-applied-configuration copy of the data is written. Objects an older bootstrap
# wrote client-side are migrated by kubectl on first contact (their field ownership moves to platform-bootstrap and the
# re-apply drops the old annotation).
kapply() {
  kubectl --context "$CTX" apply --server-side --field-manager=platform-bootstrap --force-conflicts -f - >/dev/null
}

ensure_namespace() {
  NS=$1 yq -n '.apiVersion = "v1" | .kind = "Namespace" | .metadata.name = strenv(NS)' | kapply
}

# secret_manifest <ns> <name> <spec>... -> v1 Secret on stdout. Specs name where a value is, never the value itself:
#   key=VAR             data key from shell variable VAR (any scope; `vals[2]` works too)
#   key=@FILE           data key from the content of FILE
#   label:key=VAR       metadata label / annotation from shell variable VAR
#   annotation:key=VAR
# yq gets each value through its environment (readable only by the same user) or reads the file itself, so no secret
# value is ever a process argument (/proc/<pid>/cmdline, `ps`: readable by every local user). Works in Git Bash too
# (no process substitution, no temp files).
secret_manifest() {
  local __sm_ns=$1 __sm_name=$2 __sm_spec __sm_key __sm_ref __sm_val __sm_path __sm_expr __sm_i=0
  local __sm_filter='.apiVersion = "v1" | .kind = "Secret" | .metadata.name = strenv(NAME) | .metadata.namespace = strenv(NS) | .type = "Opaque"'
  local -a __sm_exports=("NS=$__sm_ns" "NAME=$__sm_name")
  shift 2
  for __sm_spec in "$@"; do
    __sm_key=${__sm_spec%%=*}; __sm_ref=${__sm_spec#*=}; __sm_path=.data
    case "$__sm_key" in
      label:*)      __sm_path=.metadata.labels;      __sm_key=${__sm_key#label:} ;;
      annotation:*) __sm_path=.metadata.annotations; __sm_key=${__sm_key#annotation:} ;;
    esac
    if [[ "$__sm_ref" == @* ]]; then
      __sm_val=${__sm_ref#@}; __sm_expr="load_str(strenv(V$__sm_i))"
    else
      __sm_val=${!__sm_ref}; __sm_expr="strenv(V$__sm_i)"
    fi
    [[ "$__sm_path" == .data ]] && __sm_expr="$__sm_expr | @base64"
    __sm_exports+=("K$__sm_i=$__sm_key" "V$__sm_i=$__sm_val")
    __sm_filter="$__sm_filter | ${__sm_path}[strenv(K$__sm_i)] = (${__sm_expr})"
    __sm_i=$((__sm_i + 1))
  done
  ( export "${__sm_exports[@]}"; yq -n "$__sm_filter" )
}

# apply_secret <ns> <name> <spec>...: secret_manifest | kapply (create or replace; keys not passed are dropped).
apply_secret() {
  secret_manifest "$@" | kapply
}

# require_app_env <ID var> <INSTALLATION_ID var> <PRIVATE_KEY_FILE var>: all three set, key file readable (and, on
# POSIX hosts, not readable by group/others).
require_app_env() {
  [[ -n "${!1:-}" && -n "${!2:-}" && -r "${!3:-}" ]] \
    || die "GitHub App seeding needs $1, $2 and $3 (path to the App's .pem private key)"
  local perms
  perms=$(file_group_other_perms "${!3}")
  [[ -z "$perms" || "$perms" == "------" ]] \
    || warn "$3 (${!3}) is accessible by group/others (mode ...${perms}): chmod 600 it"
}

# token_warnings <var>: the read token should be a dedicated, fine-grained PAT. GITHUB_TOKEN is a crowded name:
# devcontainers, Codespaces and many dev shells already export a broad token under it.
token_warnings() {
  local var=$1
  [[ "$var" == GITHUB_TOKEN ]] \
    && warn "using GITHUB_TOKEN: shells, devcontainers and Codespaces often export a broad token under that name; set the dedicated PLATFORM_GITHUB_TOKEN instead"
  case "${!var}" in
    github_pat_*) ;;
    ghp_*) warn "$var is a classic PAT (ghp_): broad scopes on every repo you can reach. Use a GitHub App (GITHUB_APP_*) or a fine-grained PAT (github_pat_) with Contents: Read-only" ;;
    gho_*) warn "$var is an OAuth token (gho_, e.g. from gh): broad scopes. Use a GitHub App (GITHUB_APP_*) or a fine-grained PAT (github_pat_) with Contents: Read-only" ;;
    *)     warn "$var is not a fine-grained PAT (github_pat_...): it may be broad or expire within hours. Prefer GITHUB_APP_* or a fine-grained PAT" ;;
  esac
}

# resolve_github_creds <allow gh: 1|0> -> GH_MODE (app|token|gh|none), GH_LOGIN, GH_SECRET, GH_SRC.
# Read access for Argo CD, least privilege first (docs/forking.md "Credentials"):
#   GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_FILE   GitHub App, Contents: read (preferred)
#   PLATFORM_GITHUB_TOKEN [+ PLATFORM_GITHUB_USER]                             fine-grained PAT, Contents: read
#   GITHUB_TOKEN [+ GITHUB_USER]                                               same, legacy name (warns)
#   gh CLI login (local only; broad OAuth token; NO_GH=1 skips it)
#   none                                                                       public fork: Argo CD needs no creds
resolve_github_creds() {
  GH_MODE=none; GH_LOGIN=""; GH_SECRET=""; GH_SRC=""
  if [[ -n "${GITHUB_APP_ID:-}${GITHUB_APP_INSTALLATION_ID:-}${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
    require_app_env GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_FILE
    GH_MODE=app; GH_SRC="GitHub App"
  elif [[ -n "${PLATFORM_GITHUB_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
    GH_SRC=PLATFORM_GITHUB_TOKEN
    [[ -n "${PLATFORM_GITHUB_TOKEN:-}" ]] || GH_SRC=GITHUB_TOKEN
    token_warnings "$GH_SRC"
    GH_MODE=token; GH_SECRET=${!GH_SRC}; GH_LOGIN="${PLATFORM_GITHUB_USER:-${GITHUB_USER:-git}}"
  elif [[ "$1" == 1 && "${NO_GH:-0}" != 1 ]] && command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    GH_SECRET=$(gh auth token) || die "failed to read GitHub token from gh CLI"
    # The login is cosmetic for token auth over HTTPS (GitHub ignores it): offline / rate-limited is not fatal.
    if ! GH_LOGIN=$(gh api user --jq .login 2>/dev/null) || [[ -z "$GH_LOGIN" ]]; then
      warn "gh api user failed (offline or rate-limited?): using username 'git'"
      GH_LOGIN=git
    fi
    GH_MODE=gh; GH_SRC="gh CLI"
  fi
}

# The repo-creds ExternalSecret (addon secret-stores on mgmt) must read the properties that were seeded. Same layering
# as the addons ApplicationSet: values.yaml < env-<mgmt.environment>.yaml < cluster-<mgmt.name>.yaml.
check_repo_creds_mode() {
  local d="installations/${INST}/addons/secret-stores" want=token have=token src="chart default" f v m_env m_name
  m_env=$(yq '.mgmt.environment // "mgmt"' "$INST_FILE")
  m_name=$(yq '.mgmt.name // "mgmt"' "$INST_FILE")
  for f in "$d/values.yaml" "$d/env-$m_env.yaml" "$d/cluster-$m_name.yaml"; do
    [[ -f "$f" ]] || continue
    v=$(yq '.repoCreds.auth // ""' "$f")
    [[ -n "$v" ]] && { have=$v; src=$f; }
  done
  [[ "$GH_MODE" == app ]] && want=githubApp
  [[ "$have" == "$want" ]] \
    || warn "platform-github holds $want credentials but repoCreds.auth is $have ($src): set 'repoCreds: {auth: $want}' in $d/values.yaml (or the env-/cluster- overlay that sets it; docs/forking.md)"
}

# node_registry_auth -> true|false: secrets.nodeRegistryAuth.enabled, chart default true (charts/cluster). No `//`:
# yq treats false as empty there.
node_registry_auth() {
  local v
  v=$(yq '.secrets.nodeRegistryAuth.enabled' "$INST_FILE")
  [[ "$v" == null ]] && v=true
  echo "$v"
}

# get_secret_yaml <ns> <name>: Secret YAML on stdout, empty on NotFound, non-zero on any other kubectl error
# (API unreachable, timeout, wrong context, RBAC) so callers never mistake a failed lookup for a missing Secret.
get_secret_yaml() {
  kubectl --context "$CTX" -n "$1" get secret "$2" --ignore-not-found -o yaml
}

# drop_stale_ghcr <nodeRegistryAuth true|false>: no GHCR credential this run, but an earlier run may have left
# platform-ghcr. A gh CLI copy (annotation seeded-from=gh, or a gho_ token from before the annotation existed) is
# deleted when no node needs it; while nodeRegistryAuth is on, new nodes do need it, so it is kept and reported, as is
# any secret the user seeded.
drop_stale_ghcr() {
  local doc from tok
  doc=$(get_secret_yaml platform-secrets platform-ghcr) \
    || die "failed to look up secret platform-secrets/platform-ghcr in context '$CTX'"
  [[ -n "$doc" ]] || return 0
  from=$(printf '%s\n' "$doc" | yq '.metadata.annotations["platform.koorikla.io/seeded-from"] // ""')
  tok=$(printf '%s\n' "$doc" | yq '.data.token // ""' | b64dec 2>/dev/null || true)
  if [[ "$from" == gh || "$tok" == gho_* ]]; then
    if [[ "$1" == true ]]; then
      warn "  platform-ghcr: still holds the gh CLI token from an earlier run (kept: nodeRegistryAuth is on and new nodes"
      warn "  need it). Replace it with GHCR_USER/GHCR_TOKEN, or turn nodeRegistryAuth off to have it deleted"
    else
      kubectl --context "$CTX" -n platform-secrets delete secret platform-ghcr >/dev/null
      log "  platform-ghcr: deleted the gh CLI token an earlier run copied there"
    fi
  else
    warn "  platform-ghcr: kept from an earlier run although no GHCR_TOKEN was given now; if unwanted:"
    warn "  kubectl --context $CTX -n platform-secrets delete secret platform-ghcr"
  fi
}

rand_alnum() {
  # openssl, not `tr </dev/urandom | head`: under pipefail the reader closing early kills tr with SIGPIPE (exit 141).
  # $1 = length (default 24, max ~80).
  openssl rand -base64 96 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-24}"
}

# seed_generated_secret <secret> <key>[=<fixed value>|=@strong|=@<length>] ...
# Generates each missing property once (random alphanumeric; @strong adds upper/lower/digit/special for password
# policies like OpenSearch 3 and Harbor; @<length> exact length; @hex32 = 32 random bytes in hex), keeps existing values
# on re-runs.
seed_generated_secret() {
  local name=$1 existing; shift
  existing=$(get_secret_yaml platform-secrets "$name") \
    || die "failed to look up secret platform-secrets/$name in context '$CTX'; refusing to generate or overwrite secrets"
  local -a specs=() vals=()
  local spec k fixed val i=0
  for spec in "$@"; do
    k=${spec%%=*}; fixed=""; [[ "$spec" == *=* ]] && fixed=${spec#*=}
    val=""
    [[ -n "$existing" ]] && val=$(printf '%s\n' "$existing" | K="$k" yq -r '.data[strenv(K)] // ""' 2>/dev/null | b64dec 2>/dev/null || true)
    if [[ -z "$val" ]]; then
      case "$fixed" in
        "")      val=$(rand_alnum) ;;
        @strong) val="Px9!$(rand_alnum)" ;;
        @hex32)  val=$(openssl rand -hex 32) ;;       # 32 random bytes as 64 hex chars (OpenBao static seal key)
        @[0-9]*) val=$(rand_alnum "${fixed#@}") ;;   # exact length (Harbor secretKey 16, CSRF key 32)
        *)       val=$fixed ;;
      esac
    fi
    # shellcheck disable=SC2034  # read by apply_secret through the spec name vals[i]
    vals[i]=$val
    specs+=("${k}=vals[$i]")
    i=$((i + 1))
  done
  apply_secret platform-secrets "$name" "${specs[@]}"
}

seed_openchoreo_secret() {
  seed_generated_secret openchoreo thunder-admin-password admin-user-password developer-user-password \
    backstage-client-secret backstage-backend-secret service-mcp-client-secret
  # Observability plane (addon openchoreo-observability-plane) and data-plane telemetry; observer-client-secret is
  # shared with Thunder's observer OAuth client.
  seed_generated_secret openchoreo-observability opensearch-username=admin opensearch-password=@strong \
    observer-client-secret
  # Falco escalation webhook (mgmt only: every cluster gets a token derived from it, never the key itself) and the
  # promotion gate's Thunder client secret (ClusterWorkflow promotion-gate). docs/observability.md, docs/promotion.md.
  seed_generated_secret falco-webhook url=http://events.openchoreo.localhost:8080/falco token
  seed_generated_secret promotion-gate client-secret
}

# Harbor (addon harbor): every key the chart would otherwise generate per render, the admin password and the robot
# secrets (builder: in-cluster builds, nodes: k3s node pulls). Harbor's policy: >= 8 chars, upper + lower + digit.
seed_harbor_secret() {
  seed_generated_secret harbor admin-password=@strong secret-key=@16 core-secret csrf-key=@32 jobservice-secret \
    registry-http-secret registry-password database-password builder-secret=@strong nodes-secret=@strong
}

# OpenBao static auto-unseal key (addon openbao, local backend only; cloud installations use a KMS seal instead). Never
# regenerated: OpenBao's storage is encrypted with it and self-initialisation creates no recovery keys.
seed_openbao_secret() {
  seed_generated_secret openbao-unseal key=@hex32
}

# Platform cosign key pair for in-cluster builds (key cosign-platform: cosign.key [encrypted], cosign.pub,
# cosign.password). Generated once with cosign from the ci-toolbox image (ci/toolbox) (no host install); the private key
# only ever exists in this Secret (and the build pods that mount it). Admission policies trust cosign.pub.
COSIGN_IMAGE="ghcr.io/koorikla/ci-toolbox:v1@sha256:d9505f97eddefe4989e3b38b289aeccea15b4c35a2de3a479f339431864b6a79"
COSIGN_TMP=""
# shellcheck disable=SC2034  # cosign_pass is read by apply_secret through its name
seed_cosign_secret() {
  local existing
  existing=$(kubectl --context "$CTX" -n platform-secrets get secret cosign-platform --ignore-not-found -o name) \
    || die "failed to look up secret platform-secrets/cosign-platform in context '$CTX'; refusing to regenerate key pair"
  if [[ -n "$existing" ]]; then
    log "  cosign-platform exists (keeping the key pair)"
    return 0
  fi
  require_bins docker
  local cosign_pass
  COSIGN_TMP=$(mktemp -d)
  # The private key must not outlive this function, also when docker or the apply fails (set -e exits).
  trap 'rm -rf "$COSIGN_TMP"' EXIT
  cosign_pass=$(rand_alnum 32)
  log "  cosign-platform: generating the platform cosign key pair"
  # The password reaches docker and cosign only through the environment (-e NAME, no value in argv).
  # Git Bash rewrites POSIX-looking arguments of native programs (`-w /keys` would become C:/Program Files/Git/keys
  # and the bind mount a `;`-joined path list): MSYS_NO_PATHCONV / MSYS2_ARG_CONV_EXCL switch that off (no-ops
  # elsewhere), and native_path hands docker.exe the host dir as C:/Users/... itself.
  COSIGN_PASSWORD="$cosign_pass" MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    docker run --rm -u "$(id -u):$(id -g)" -e COSIGN_PASSWORD \
    -v "$(native_path "$COSIGN_TMP"):/keys" -w /keys --entrypoint cosign "$COSIGN_IMAGE" generate-key-pair >/dev/null
  apply_secret platform-secrets cosign-platform cosign.key=@"$COSIGN_TMP/cosign.key" \
    cosign.pub=@"$COSIGN_TMP/cosign.pub" cosign.password=cosign_pass
  rm -rf "$COSIGN_TMP"; COSIGN_TMP=""
  trap - EXIT
}

# seed_byo_kubeconfigs: platform store key byo-<name> (property kubeconfig) for every `provider: byo` fleet file of the
# installation (charts/cluster templates/byo/access.yaml; docs/providers.md "Bring your own cluster (byo)"). Source, first
# match: the file named by BYO_KUBECONFIG_<NAME> (name upper-cased, '-' -> '_'), else the local k3d cluster <name>
# (`k3d kubeconfig get`, API server rewritten to its server node's IP on docker network kind: what mgmt pods reach, as
# with CAPD's kubeconfigs). Neither: a warning, and the cluster stays unregistered until seeded. Re-run after rotating.
seed_byo_kubeconfigs() {
  local cf name var file kc ip
  for cf in "installations/$INST/clusters/"*.yaml; do
    [[ -f "$cf" ]] || continue
    [[ "$(yq -r '.provider // ""' "$cf")" == byo ]] || continue
    name=$(yq -r '.name' "$cf")
    var="BYO_KUBECONFIG_$(printf '%s' "$name" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')"
    file="${!var:-}"
    if [[ -n "$file" ]]; then
      [[ -r "$file" ]] || die "$var=$file is not readable"
      apply_secret platform-secrets "byo-$name" kubeconfig=@"$file"
      log "  byo-$name: kubeconfig from \$$var"
    elif command -v k3d >/dev/null 2>&1 && kc=$(k3d kubeconfig get "$name" 2>/dev/null) && [[ -n "$kc" ]]; then
      ip=$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "k3d-$name-server-0" 2>/dev/null || true)
      [[ -n "$ip" ]] || die "k3d cluster $name is not on docker network kind (k3d cluster create $name --network kind ...)"
      kc=$(printf '%s\n' "$kc" | SERVER="https://$ip:6443" yq '.clusters[0].cluster.server = strenv(SERVER)')
      apply_secret platform-secrets "byo-$name" kubeconfig=kc
      log "  byo-$name: kubeconfig of k3d cluster $name (API https://$ip:6443 on network kind)"
    else
      warn "  byo-$name: no \$$var and no k3d cluster $name: $cf stays unregistered until it is seeded"
    fi
  done
}

cmd_secrets() {
  load_inst
  if [[ "$BACKEND" != "kubernetes" ]]; then
    log "secrets.backend=$BACKEND (not kubernetes); skipping local platform-secrets seeding"
    return 0
  fi
  require_bins kubectl yq
  resolve_github_creds 1

  log "Seeding ns platform-secrets"
  ensure_namespace platform-secrets

  # platform-github: Argo CD repo-creds for installation.githubOrg (read-only).
  case "$GH_MODE" in
    app)
      apply_secret platform-secrets platform-github githubAppID=GITHUB_APP_ID \
        githubAppInstallationID=GITHUB_APP_INSTALLATION_ID githubAppPrivateKey=@"$GITHUB_APP_PRIVATE_KEY_FILE"
      log "  platform-github: GitHub App $GITHUB_APP_ID, installation $GITHUB_APP_INSTALLATION_ID" ;;
    token)
      apply_secret platform-secrets platform-github username=GH_LOGIN token=GH_SECRET
      log "  platform-github: $GH_SRC (user $GH_LOGIN)" ;;
    gh)
      apply_secret platform-secrets platform-github username=GH_LOGIN token=GH_SECRET
      warn "  platform-github: gh CLI token of $GH_LOGIN (broad scopes). Least privilege: GITHUB_APP_* or a read-only fine-grained PLATFORM_GITHUB_TOKEN" ;;
    none)
      warn "  platform-github: no GITHUB_APP_*, PLATFORM_GITHUB_TOKEN or gh login: skipped (fine for a public fork)" ;;
  esac
  [[ "$GH_MODE" == none ]] || check_repo_creds_mode

  # platform-ghcr: k3s node registry auth for ghcr.io (secrets.nodeRegistryAuth). The gh CLI token is copied onto
  # every node only when it can actually pull (read:packages); otherwise nothing broad lands in registries.yaml.
  local ghcr_user="${GHCR_USER:-${PLATFORM_GITHUB_USER:-${GITHUB_USER:-}}}" ghcr_token="${GHCR_TOKEN:-}"
  # shellcheck disable=SC2034  # ghcr_from is read by apply_secret through its name
  local ghcr_src=GHCR_TOKEN ghcr_from=env scopes nra
  nra=$(node_registry_auth)
  if [[ -z "$ghcr_token" && "$GH_MODE" == gh && "$nra" == true ]]; then
    scopes=$(gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:' | tr -d '\r' || true)
    if [[ "$scopes" =~ (read|write):packages ]]; then
      ghcr_user="${GHCR_USER:-$GH_LOGIN}"; ghcr_token="$GH_SECRET"; ghcr_src="gh CLI token"
      # shellcheck disable=SC2034
      ghcr_from=gh
    else
      warn "  platform-ghcr: gh CLI token lacks read:packages (${scopes:-scopes unknown}): not copied to the nodes"
    fi
  fi
  if [[ -n "$ghcr_token" ]]; then
    [[ -n "$ghcr_user" ]] || die "GHCR_TOKEN is set: also set GHCR_USER (the GitHub login that owns the token)"
    apply_secret platform-secrets platform-ghcr username=ghcr_user token=ghcr_token \
      annotation:platform.koorikla.io/seeded-from=ghcr_from
    log "  platform-ghcr: $ghcr_src (user $ghcr_user)"
  else
    drop_stale_ghcr "$nra"
    if [[ "$nra" == true ]]; then
      warn "  platform-ghcr: no GHCR_TOKEN: skipped, but secrets.nodeRegistryAuth is on and new cluster nodes wait for it."
      warn "  Public images only: set 'secrets: {nodeRegistryAuth: {enabled: false}}' in $INST_FILE (docs/forking.md)"
    else
      log "  platform-ghcr: not needed (secrets.nodeRegistryAuth.enabled=false)"
    fi
  fi

  # platform-github-app: write access (GitOps hand-off commits, scaffolder). Optional.
  if [[ -n "${GITHUB_PUSH_APP_ID:-}${GITHUB_PUSH_APP_INSTALLATION_ID:-}${GITHUB_PUSH_APP_PRIVATE_KEY_FILE:-}" ]]; then
    require_app_env GITHUB_PUSH_APP_ID GITHUB_PUSH_APP_INSTALLATION_ID GITHUB_PUSH_APP_PRIVATE_KEY_FILE
    apply_secret platform-secrets platform-github-app githubAppID=GITHUB_PUSH_APP_ID \
      githubAppInstallationID=GITHUB_PUSH_APP_INSTALLATION_ID githubAppPrivateKey=@"$GITHUB_PUSH_APP_PRIVATE_KEY_FILE"
    log "  platform-github-app: GitHub App $GITHUB_PUSH_APP_ID, installation $GITHUB_PUSH_APP_INSTALLATION_ID"
  fi

  # promotion-gate-github: the platform's GitHub App (Contents, Pull requests, Commit statuses: write; app repos
  # only). The promotion gate and every in-cluster build mint installation tokens scoped to one repository per run
  # (builds: ESO GithubAccessToken generator, docs/build-plane.md). Optional: without it the gate fails closed, builds
  # fail at checkout, and auto-build + PR previews are not rendered (secrets.githubGateApp.enabled, gate_app_enabled).
  if [[ -n "${GITHUB_GATE_APP_ID:-}${GITHUB_GATE_APP_INSTALLATION_ID:-}${GITHUB_GATE_APP_PRIVATE_KEY_FILE:-}" ]]; then
    require_app_env GITHUB_GATE_APP_ID GITHUB_GATE_APP_INSTALLATION_ID GITHUB_GATE_APP_PRIVATE_KEY_FILE
    apply_secret platform-secrets promotion-gate-github githubAppID=GITHUB_GATE_APP_ID \
      githubAppInstallationID=GITHUB_GATE_APP_INSTALLATION_ID githubAppPrivateKey=@"$GITHUB_GATE_APP_PRIVATE_KEY_FILE"
    log "  promotion-gate-github: GitHub App $GITHUB_GATE_APP_ID, installation $GITHUB_GATE_APP_INSTALLATION_ID"
  elif [[ "$(gate_app_enabled)" == true ]]; then
    log "  promotion-gate-github: kept from an earlier run"
  else
    warn "  promotion-gate-github: no GITHUB_GATE_APP_*: auto-build and PR previews stay off, the promotion gate fails"
    warn "  closed, builds cannot clone (docs/forking.md (c2))"
  fi

  seed_openchoreo_secret
  seed_harbor_secret
  seed_cosign_secret
  seed_openbao_secret
  log "  openchoreo, openchoreo-observability, harbor, cosign-platform, openbao-unseal: generated once, kept on re-runs"
  seed_byo_kubeconfigs
  # A running stack picks up a newly seeded (or removed) gate App without a full `up`.
  if kubectl --context "$CTX" -n argocd get application root -o name >/dev/null 2>&1; then
    apply_root_app
  fi
}

# gate_app_enabled -> true|false|"" : root app value secrets.githubGateApp.enabled. Features that need the platform
# GitHub App (auto-build, PR previews: their ESO GithubAccessToken generators fail without the key and degrade the
# apps) render only when it is true (#192). kubernetes backend: true iff promotion-gate-github is seeded and
# installation.yaml does not set it to false. Other backends: "" (bootstrap cannot see the store; installation.yaml
# decides, default false in charts/platform).
gate_app_enabled() {
  [[ "$BACKEND" == kubernetes ]] || return 0
  if [[ "$(yq '.secrets.githubGateApp.enabled' "$INST_FILE")" == false ]]; then
    echo false
  elif kubectl --context "$CTX" -n platform-secrets get secret promotion-gate-github -o name >/dev/null 2>&1; then
    echo true
  else
    echo false
  fi
}

# root_app_manifest: bootstrap/root-app.yaml for this installation (repo, revision, value file, gate_app_enabled).
root_app_manifest() {
  REPO_URL="$REPO_URL" REVISION="$REVISION" INST_NAME="$INST" GATE="$(gate_app_enabled)" \
    yq '.spec.source.repoURL = strenv(REPO_URL) | .spec.source.targetRevision = strenv(REVISION) | .spec.source.helm.valueFiles = ["../../installations/" + strenv(INST_NAME) + "/installation.yaml"] | del(.spec.source.helm.parameters) | with(select(strenv(GATE) != ""); .spec.source.helm.parameters = [{"name": "secrets.githubGateApp.enabled", "value": strenv(GATE)}])' \
    bootstrap/root-app.yaml
}

apply_root_app() {
  root_app_manifest | kubectl --context "$CTX" apply -f - >/dev/null
}

# Bootstrap repo credentials so Argo CD can read a private fork before ESO exists (same sources as platform-github;
# the gh fallback only for the local backend).
# Once ESO's repo-creds is Ready the bootstrap copy is deleted (it may hold a broad gh token).
seed_argocd_repo_secret() {
  if repo_creds_ready; then
    retire_repo_bootstrap
    log "ESO's $REPO_CREDS_NAME is Ready: no bootstrap repo secret needed"
    return 0
  fi
  local allow_gh=0
  [[ "$BACKEND" == "kubernetes" ]] && allow_gh=1
  resolve_github_creds "$allow_gh"
  if [[ "$GH_MODE" == none ]]; then
    warn "No GITHUB_APP_*/PLATFORM_GITHUB_TOKEN/gh auth token available; skipping bootstrap repo secret (fine if repo is public)"
    return 0
  fi
  # shellcheck disable=SC2034  # git_type, login: read by apply_secret through the spec names
  local cred_url="${GITHUB_ORG:-$REPO_URL}" cred_type="repository" git_type=git login="${GH_LOGIN:-git}"
  [[ -n "$GITHUB_ORG" ]] && cred_type="repo-creds"
  local -a specs=(type=git_type url=cred_url label:argocd.argoproj.io/secret-type=cred_type)
  if [[ "$GH_MODE" == app ]]; then
    specs+=(githubAppID=GITHUB_APP_ID githubAppInstallationID=GITHUB_APP_INSTALLATION_ID
      githubAppPrivateKey=@"$GITHUB_APP_PRIVATE_KEY_FILE")
  else
    specs+=(username=login password=GH_SECRET)
  fi
  log "Creating Argo CD bootstrap ${cred_type} secret 'platform-repo-bootstrap' for $cred_url ($GH_MODE)"
  apply_secret argocd platform-repo-bootstrap "${specs[@]}"
}

# ESO's repo-creds secret (addon secret-stores, repoCreds.name default) for installation.githubOrg.
REPO_CREDS_NAME=platform-repo-creds

# repo_creds_ready: ESO's repo-creds ExternalSecret is Ready and its secret covers installation.githubOrg. Without a
# githubOrg the bootstrap secret is a single-repo credential that ESO does not replace.
repo_creds_ready() {
  [[ -n "$GITHUB_ORG" ]] || return 1
  local ready url
  ready=$(kubectl --context "$CTX" -n argocd get externalsecret "$REPO_CREDS_NAME" \
    -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$ready" == True ]] || return 1
  url=$(kubectl --context "$CTX" -n argocd get secret "$REPO_CREDS_NAME" -o 'jsonpath={.data.url}' 2>/dev/null \
    | b64dec 2>/dev/null || true)
  [[ "$url" == "$GITHUB_ORG" ]]
}

# retire_repo_bootstrap: delete platform-repo-bootstrap if it exists and ESO's repo-creds took over.
retire_repo_bootstrap() {
  kubectl --context "$CTX" -n argocd get secret platform-repo-bootstrap >/dev/null 2>&1 || return 0
  repo_creds_ready || return 1
  kubectl --context "$CTX" -n argocd delete secret platform-repo-bootstrap >/dev/null
  log "Deleted bootstrap secret platform-repo-bootstrap: ESO's $REPO_CREDS_NAME is Ready"
}

# wait_retire_repo_bootstrap: after the root app, give Argo CD REPO_CREDS_WAIT seconds (default 600; 0 skips) to sync
# ESO + secret-stores, then retire the bootstrap secret. No `timeout` (not portable): poll with a counter.
wait_retire_repo_bootstrap() {
  local wait_s="${REPO_CREDS_WAIT:-600}" waited=0
  [[ -n "$GITHUB_ORG" ]] || return 0
  kubectl --context "$CTX" -n argocd get secret platform-repo-bootstrap >/dev/null 2>&1 || return 0
  (( wait_s > 0 )) && log "Waiting up to ${wait_s}s for ESO's $REPO_CREDS_NAME to replace platform-repo-bootstrap (REPO_CREDS_WAIT=0 skips)"
  until retire_repo_bootstrap; do
    if (( waited >= wait_s )); then
      warn "platform-repo-bootstrap kept: $REPO_CREDS_NAME not Ready yet. 'task argocd' deletes it once it is"
      return 0
    fi
    sleep 15; waited=$((waited + 15))
  done
}

cmd_argocd() {
  load_inst
  require_bins kubectl helm yq
  if [[ ! -d addons/argo-cd/charts || -z "$(ls -A addons/argo-cd/charts 2>/dev/null)" ]]; then
    log "Building Helm dependencies for addons/argo-cd"
    helm dependency build addons/argo-cd >/dev/null
  fi
  log "Installing/upgrading Argo CD (release 'argocd' in ns 'argocd')"
  helm --kube-context "$CTX" upgrade --install argocd addons/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values addons/argo-cd/values.yaml \
    --wait --timeout 5m

  seed_argocd_repo_secret

  log "Applying root Application for installation '$INST' (secrets.githubGateApp.enabled=$(gate_app_enabled))"
  apply_root_app
}

cmd_up() {
  load_inst
  require_bins kubectl helm yq
  ensure_k3d
  cmd_secrets
  cmd_argocd
  wait_retire_repo_bootstrap
  log "Bootstrap complete for installation '$INST' (context: $CTX)"
  cmd_status
}

cmd_status() {
  load_inst
  require_bins kubectl
  echo "=== Context: $CTX ==="
  kubectl --context "$CTX" get clusters.cluster.x-k8s.io -A 2>/dev/null || true
  echo ""
  kubectl --context "$CTX" get applications -n argocd 2>/dev/null || true
  echo ""
  kubectl --context "$CTX" get clusterdataplanes 2>/dev/null || true
  echo ""
  echo "Argo CD UI: kubectl --context $CTX port-forward -n argocd svc/argocd-server 8081:80"
  admin_password_hint
}

# admin_password_hint: how to read the Argo CD admin password, never the password itself. Output of `up`/`status` lands
# in terminals, CI logs and agent transcripts; a printed password is an exposed password.
admin_password_hint() {
  # shellcheck disable=SC2016  # printed for the user to run, not expanded here
  printf '%s\n' "Argo CD admin password (user admin; not printed): kubectl --context $CTX -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; echo" \
    "  The secret is gone once the password was changed (argocd account update-password)."
}

cmd_ui() {
  load_inst
  require_bins kubectl
  admin_password_hint
  log "Port-forwarding Argo CD UI to http://localhost:8081 (Ctrl-C to stop; NO_BROWSER=1 skips opening a browser)"
  ( sleep 3; open_url http://localhost:8081 ) &
  kubectl --context "$CTX" port-forward -n argocd svc/argocd-server 8081:80
}

# freeze_argocd: stop the Argo CD controllers that write to clusters. The fleet Clusters are Argo CD-managed with
# selfHeal, so a Cluster deleted under a running application-controller is re-created within seconds (a new CAPD
# cluster boots while mgmt is being torn down), and the ApplicationSet controller rewrites Applications as cluster
# secrets go away. Scaling to 0 is undone by the next `task up`/`task argocd` (helm upgrade restores the replicas).
freeze_argocd() {
  kubectl --context "$CTX" get ns argocd >/dev/null 2>&1 || return 0
  log "Freezing Argo CD (application + applicationset controllers to 0 replicas) so it cannot re-create Clusters"
  kubectl --context "$CTX" -n argocd scale statefulset/argocd-application-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n argocd scale deployment/argocd-applicationset-controller --replicas=0 >/dev/null 2>&1 || true
  kubectl --context "$CTX" -n argocd wait --for=delete pod --timeout=2m \
    -l 'app.kubernetes.io/name in (argocd-application-controller,argocd-applicationset-controller)' >/dev/null 2>&1 \
    || warn "Argo CD controller pods still terminating; continuing"
}

# remove_capd_leftovers: CAPD node containers carry the kind label io.x-k8s.kind.cluster=<cluster>. Remove the ones of
# the given clusters that CAPI could not delete in time (only those names: other kind clusters on the host are kept).
remove_capd_leftovers() {
  local c ids seen=" "
  for c in "$@"; do
    [[ "$seen" == *" $c "* ]] && continue
    seen="$seen$c "
    ids=$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$c" 2>/dev/null || true)
    [[ -n "$ids" ]] || continue
    warn "Removing leftover CAPD containers of cluster '$c'"
    # shellcheck disable=SC2086  # one id per word
    docker rm -f $ids >/dev/null 2>&1 || true
  done
}

cmd_down() {
  load_inst
  [[ "$INST" == "local" ]] || die "'down' only tears down the local k3d installation (got INST=$INST)"
  require_bins k3d kubectl docker yq
  local clusters=()
  if kubectl --context "$CTX" get ns fleet >/dev/null 2>&1; then
    local name
    while IFS= read -r name; do
      [[ -n "$name" ]] && clusters+=("$name")
    done < <(kubectl --context "$CTX" get clusters.cluster.x-k8s.io -n fleet \
      -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  fi
  if (( ${#clusters[@]} > 0 )); then
    freeze_argocd
    log "Deleting CAPI workload clusters gracefully before tearing down mgmt: ${clusters[*]}"
    kubectl --context "$CTX" delete clusters.cluster.x-k8s.io -n fleet --all --wait=true \
      --timeout="${DOWN_TIMEOUT:-5m}" || warn "CAPI cluster deletion did not finish within ${DOWN_TIMEOUT:-5m}"
  fi
  # Leftovers of the clusters mgmt listed plus the installation's fleet files (mgmt may already be unreachable),
  # disabled ones included (a profile switch, docs/dev-environment.md "Local profiles", may have left containers).
  local f
  for f in "installations/$INST/clusters/"*.yaml "installations/$INST/clusters/"*.yaml.disabled; do
    [[ -f "$f" ]] && clusters+=("$(yq '.name' "$f")")
  done
  (( ${#clusters[@]} > 0 )) && remove_capd_leftovers "${clusters[@]}"
  log "Deleting k3d cluster 'platform-mgmt'"
  k3d cluster delete platform-mgmt 2>/dev/null || true
}

case "$CMD" in
  up)      cmd_up ;;
  secrets) cmd_secrets ;;
  argocd)  cmd_argocd ;;
  status)  cmd_status ;;
  ui)      cmd_ui ;;
  down)    cmd_down ;;
esac
