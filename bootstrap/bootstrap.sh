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
           privilege first: GITHUB_APP_ID/GITHUB_APP_INSTALLATION_ID/GITHUB_APP_PRIVATE_KEY_FILE, GITHUB_TOKEN
           [GITHUB_USER], else gh CLI (NO_GH=1 skips); GHCR_TOKEN/GHCR_USER; push App GITHUB_PUSH_APP_* (docs/forking.md)
  argocd   Install/upgrade Argo CD via Helm, seed repo secret if needed, apply root-app
  status   Show clusters, Argo CD apps, and UI/password info
  ui       Print Argo CD admin password and port-forward argocd-server on localhost:8081
  down     Delete CAPD workload clusters (if any) and delete k3d platform-mgmt (local only)
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
  BACKEND=$(yq '.secrets.backend // "kubernetes"' "$INST_FILE")
  REPO_URL=$(yq '.installation.repoURL // "https://github.com/koorikla/platform.git"' "$INST_FILE")
  GITHUB_ORG=$(yq '.installation.githubOrg // ""' "$INST_FILE")
  REVISION=$(yq '.installation.revision // "HEAD"' "$INST_FILE")
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

# apply_secret <ns> <name> <kubectl create secret generic args...>: create or replace (properties not passed are
# dropped, so switching platform-github from token to GitHub App leaves no stale token behind).
apply_secret() {
  local ns=$1 name=$2; shift 2
  kubectl --context "$CTX" create secret generic "$name" --namespace "$ns" "$@" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
}

# require_app_env <ID var> <INSTALLATION_ID var> <PRIVATE_KEY_FILE var>: all three set, key file readable.
require_app_env() {
  [[ -n "${!1:-}" && -n "${!2:-}" && -r "${!3:-}" ]] \
    || die "GitHub App seeding needs $1, $2 and $3 (path to the App's .pem private key)"
}

# resolve_github_creds <allow gh: 1|0> -> GH_MODE (app|token|gh|none), GH_LOGIN, GH_SECRET.
# Read access for Argo CD, least privilege first (docs/forking.md "Credentials"):
#   GITHUB_APP_ID + GITHUB_APP_INSTALLATION_ID + GITHUB_APP_PRIVATE_KEY_FILE   GitHub App, Contents: read (preferred)
#   GITHUB_TOKEN [+ GITHUB_USER]                                               fine-grained PAT, Contents: read
#   gh CLI login (local only; broad OAuth token; NO_GH=1 skips it)
#   none                                                                       public fork: Argo CD needs no creds
resolve_github_creds() {
  GH_MODE=none; GH_LOGIN=""; GH_SECRET=""
  if [[ -n "${GITHUB_APP_ID:-}${GITHUB_APP_INSTALLATION_ID:-}${GITHUB_APP_PRIVATE_KEY_FILE:-}" ]]; then
    require_app_env GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_FILE
    GH_MODE=app
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GH_MODE=token; GH_LOGIN="${GITHUB_USER:-git}"; GH_SECRET="$GITHUB_TOKEN"
  elif [[ "$1" == 1 && "${NO_GH:-0}" != 1 ]] && command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    GH_LOGIN=$(gh api user --jq .login) || die "failed to read GitHub user from gh CLI (run 'gh auth login')"
    GH_SECRET=$(gh auth token) || die "failed to read GitHub token from gh CLI"
    GH_MODE=gh
  fi
}

# The repo-creds ExternalSecret (addon secret-stores) must read the properties that were seeded.
check_repo_creds_mode() {
  local f="installations/${INST}/addons/secret-stores/values.yaml" want=token have=token
  [[ "$GH_MODE" == app ]] && want=githubApp
  [[ -f "$f" ]] && have=$(yq '.repoCreds.auth // "token"' "$f")
  [[ "$have" == "$want" ]] \
    || warn "platform-github holds $want credentials but repoCreds.auth is $have: put 'repoCreds: {auth: $want}' in $f (docs/forking.md)"
}

rand_alnum() {
  # openssl, not `tr </dev/urandom | head`: under pipefail the reader closing early kills tr with SIGPIPE (exit 141).
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
}

# seed_generated_secret <secret> <key>[=<fixed value>|=@strong] ...
# Generates each missing property once (random alphanumeric; @strong adds upper/lower/digit/special for password
# policies like OpenSearch 3), keeps existing values on re-runs.
seed_generated_secret() {
  local name=$1; shift
  local -a args=()
  local spec k fixed val
  for spec in "$@"; do
    k=${spec%%=*}; fixed=""; [[ "$spec" == *=* ]] && fixed=${spec#*=}
    val=$(kubectl --context "$CTX" -n platform-secrets get secret "$name" -o "jsonpath={.data['${k}']}" 2>/dev/null | b64dec 2>/dev/null || true)
    if [[ -z "$val" ]]; then
      case "$fixed" in
        "")      val=$(rand_alnum) ;;
        @strong) val="Px9!$(rand_alnum)" ;;
        *)       val=$fixed ;;
      esac
    fi
    args+=(--from-literal="${k}=${val}")
  done
  kubectl --context "$CTX" create secret generic "$name" \
    --namespace platform-secrets \
    "${args[@]}" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
}

seed_openchoreo_secret() {
  seed_generated_secret openchoreo thunder-admin-password admin-user-password developer-user-password \
    backstage-client-secret backstage-backend-secret
  # Observability plane (addon openchoreo-observability-plane) and data-plane telemetry; observer-client-secret is
  # shared with Thunder's observer OAuth client.
  seed_generated_secret openchoreo-observability opensearch-username=admin opensearch-password=@strong \
    observer-client-secret
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
  kubectl --context "$CTX" create namespace platform-secrets --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

  # platform-github: Argo CD repo-creds for installation.githubOrg (read-only).
  case "$GH_MODE" in
    app)
      apply_secret platform-secrets platform-github \
        --from-literal=githubAppID="$GITHUB_APP_ID" \
        --from-literal=githubAppInstallationID="$GITHUB_APP_INSTALLATION_ID" \
        --from-file=githubAppPrivateKey="$GITHUB_APP_PRIVATE_KEY_FILE"
      log "  platform-github: GitHub App $GITHUB_APP_ID, installation $GITHUB_APP_INSTALLATION_ID" ;;
    token)
      apply_secret platform-secrets platform-github --from-literal=username="$GH_LOGIN" --from-literal=token="$GH_SECRET"
      log "  platform-github: GITHUB_TOKEN (user $GH_LOGIN)" ;;
    gh)
      apply_secret platform-secrets platform-github --from-literal=username="$GH_LOGIN" --from-literal=token="$GH_SECRET"
      warn "  platform-github: gh CLI token of $GH_LOGIN (broad scopes). Least privilege: GITHUB_APP_* or a read-only fine-grained GITHUB_TOKEN" ;;
    none)
      warn "  platform-github: no GITHUB_APP_*, GITHUB_TOKEN or gh login: skipped (fine for a public fork)" ;;
  esac
  [[ "$GH_MODE" == none ]] || check_repo_creds_mode

  # platform-ghcr: k3s node registry auth for ghcr.io (secrets.nodeRegistryAuth, on by default).
  local ghcr_user="${GHCR_USER:-${GITHUB_USER:-}}" ghcr_token="${GHCR_TOKEN:-}" ghcr_src=GHCR_TOKEN scopes
  if [[ -z "$ghcr_token" && "$GH_MODE" == gh ]]; then
    ghcr_user="${GHCR_USER:-$GH_LOGIN}"; ghcr_token="$GH_SECRET"; ghcr_src="gh CLI token"
    scopes=$(gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:' | tr -d '\r' || true)
    if [[ -n "$scopes" && ! "$scopes" =~ read:packages ]]; then
      warn "GitHub token scopes ($scopes) may lack 'read:packages' needed for private ghcr.io images"
    fi
  fi
  if [[ -n "$ghcr_token" ]]; then
    [[ -n "$ghcr_user" ]] || die "GHCR_TOKEN is set: also set GHCR_USER (the GitHub login that owns the token)"
    apply_secret platform-secrets platform-ghcr --from-literal=username="$ghcr_user" --from-literal=token="$ghcr_token"
    log "  platform-ghcr: $ghcr_src (user $ghcr_user)"
  elif [[ "$(yq '.secrets.nodeRegistryAuth.enabled // true' "$INST_FILE")" == true ]]; then
    warn "  platform-ghcr: no GHCR_TOKEN: skipped, but secrets.nodeRegistryAuth is on and new cluster nodes wait for it."
    warn "  Public images only: set 'secrets: {nodeRegistryAuth: {enabled: false}}' in $INST_FILE (docs/forking.md)"
  else
    log "  platform-ghcr: not needed (secrets.nodeRegistryAuth.enabled=false)"
  fi

  # platform-github-app: write access (GitOps hand-off commits, promotion PRs, scaffolder). Optional.
  if [[ -n "${GITHUB_PUSH_APP_ID:-}${GITHUB_PUSH_APP_INSTALLATION_ID:-}${GITHUB_PUSH_APP_PRIVATE_KEY_FILE:-}" ]]; then
    require_app_env GITHUB_PUSH_APP_ID GITHUB_PUSH_APP_INSTALLATION_ID GITHUB_PUSH_APP_PRIVATE_KEY_FILE
    apply_secret platform-secrets platform-github-app \
      --from-literal=githubAppID="$GITHUB_PUSH_APP_ID" \
      --from-literal=githubAppInstallationID="$GITHUB_PUSH_APP_INSTALLATION_ID" \
      --from-file=githubAppPrivateKey="$GITHUB_PUSH_APP_PRIVATE_KEY_FILE"
    log "  platform-github-app: GitHub App $GITHUB_PUSH_APP_ID, installation $GITHUB_PUSH_APP_INSTALLATION_ID"
  fi

  seed_openchoreo_secret
  log "  openchoreo, openchoreo-observability: generated once, kept on re-runs"
}

# Bootstrap repo credentials so Argo CD can read a private fork before ESO exists (same sources as platform-github;
# the gh fallback only for the local backend).
seed_argocd_repo_secret() {
  local allow_gh=0
  [[ "$BACKEND" == "kubernetes" ]] && allow_gh=1
  resolve_github_creds "$allow_gh"
  if [[ "$GH_MODE" == none ]]; then
    warn "No GITHUB_APP_*/GITHUB_TOKEN/gh auth token available; skipping bootstrap repo secret (fine if repo is public)"
    return 0
  fi
  local cred_url="${GITHUB_ORG:-$REPO_URL}" cred_type="repository"
  [[ -n "$GITHUB_ORG" ]] && cred_type="repo-creds"
  local -a auth
  if [[ "$GH_MODE" == app ]]; then
    auth=(--from-literal=githubAppID="$GITHUB_APP_ID" --from-literal=githubAppInstallationID="$GITHUB_APP_INSTALLATION_ID"
      --from-file=githubAppPrivateKey="$GITHUB_APP_PRIVATE_KEY_FILE")
  else
    auth=(--from-literal=username="${GH_LOGIN:-git}" --from-literal=password="$GH_SECRET")
  fi
  log "Creating Argo CD bootstrap ${cred_type} secret 'platform-repo-bootstrap' for $cred_url ($GH_MODE)"
  kubectl --context "$CTX" create secret generic platform-repo-bootstrap \
    --namespace argocd \
    --from-literal=type=git \
    --from-literal=url="$cred_url" \
    "${auth[@]}" \
    --dry-run=client -o yaml | \
    CRED_TYPE="$cred_type" yq '.metadata.labels["argocd.argoproj.io/secret-type"] = strenv(CRED_TYPE)' | \
    kubectl --context "$CTX" apply -f - >/dev/null
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

  log "Applying root Application for installation '$INST'"
  REPO_URL="$REPO_URL" REVISION="$REVISION" INST_NAME="$INST" \
    yq '.spec.source.repoURL = strenv(REPO_URL) | .spec.source.targetRevision = strenv(REVISION) | .spec.source.helm.valueFiles = ["../../installations/" + strenv(INST_NAME) + "/installation.yaml"]' \
    bootstrap/root-app.yaml | kubectl --context "$CTX" apply -f - >/dev/null
}

cmd_up() {
  load_inst
  require_bins kubectl helm yq
  ensure_k3d
  cmd_secrets
  cmd_argocd
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
  echo "Argo CD admin password:"
  kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | b64dec || true
  echo ""
}

cmd_ui() {
  load_inst
  require_bins kubectl
  echo "Argo CD admin password:"
  kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | b64dec || true
  echo ""
  log "Port-forwarding Argo CD UI to http://localhost:8081 (Ctrl-C to stop; NO_BROWSER=1 skips opening a browser)"
  ( sleep 3; open_url http://localhost:8081 ) &
  kubectl --context "$CTX" port-forward -n argocd svc/argocd-server 8081:80
}

cmd_down() {
  load_inst
  [[ "$INST" == "local" ]] || die "'down' only tears down the local k3d installation (got INST=$INST)"
  require_bins k3d kubectl
  if kubectl --context "$CTX" get ns fleet >/dev/null 2>&1; then
    local clusters
    clusters=$(kubectl --context "$CTX" get clusters.cluster.x-k8s.io -n fleet -o name 2>/dev/null || true)
    if [[ -n "$clusters" ]]; then
      log "Deleting CAPI workload clusters gracefully before tearing down mgmt"
      kubectl --context "$CTX" delete clusters.cluster.x-k8s.io -n fleet --all --wait=true --timeout=2m || true
    fi
  fi
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
