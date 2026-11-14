#!/usr/bin/env bash
# Idempotent bootstrap entrypoint for koorikla/platform.
# Usage: bootstrap/bootstrap.sh [--inst <name>] [up|secrets|argocd|status|down]
set -euo pipefail
cd "$(dirname "$0")/.."

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
  secrets  Seed/refresh local platform-secrets from gh CLI (no-op if backend != kubernetes)
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
  local free_gb
  free_gb=$(df -BG --output=avail . | tail -n1 | tr -dc '0-9')
  if [[ -n "$free_gb" ]] && (( free_gb < 15 )); then
    warn "Low free disk space (${free_gb}GB < 15GB recommended for k3d + CAPD images)"
  fi
  local watches
  watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  if [[ -n "$watches" ]] && (( watches > 0 && watches < 524288 )); then
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

apply_kv_secret() {
  local ns="$1" name="$2" user="$3" token="$4"
  kubectl --context "$CTX" create secret generic "$name" \
    --namespace "$ns" \
    --from-literal=username="$user" \
    --from-literal=token="$token" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
}

rand_alnum() {
  # openssl, not `tr </dev/urandom | head`: under pipefail the reader closing early kills tr with SIGPIPE (exit 141).
  openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24
}

seed_openchoreo_secret() {
  local -a keys=(thunder-admin-password admin-user-password developer-user-password backstage-client-secret backstage-backend-secret)
  local -a args=()
  local k val
  for k in "${keys[@]}"; do
    val=$(kubectl --context "$CTX" -n platform-secrets get secret openchoreo -o "jsonpath={.data['${k}']}" 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -z "$val" ]]; then
      val=$(rand_alnum)
    fi
    args+=(--from-literal="${k}=${val}")
  done
  kubectl --context "$CTX" create secret generic openchoreo \
    --namespace platform-secrets \
    "${args[@]}" \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
}

cmd_secrets() {
  load_inst
  if [[ "$BACKEND" != "kubernetes" ]]; then
    log "secrets.backend=$BACKEND (not kubernetes); skipping local platform-secrets seeding"
    return 0
  fi
  require_bins kubectl gh
  local gh_user gh_token scopes
  gh_user=$(gh api user --jq .login) || die "failed to read GitHub user from gh CLI (run 'gh auth login')"
  gh_token=$(gh auth token) || die "failed to read GitHub token from gh CLI"
  [[ -n "$gh_user" && -n "$gh_token" ]] || die "empty GitHub credentials from gh CLI"

  scopes=$(gh api -i user 2>/dev/null | grep -i '^x-oauth-scopes:' | tr -d '\r' || true)
  if [[ -n "$scopes" && ! "$scopes" =~ read:packages ]]; then
    warn "GitHub token scopes ($scopes) may lack 'read:packages' needed for ghcr.io"
  elif [[ -z "$scopes" ]]; then
    warn "Could not inspect OAuth scopes; ensure token has 'read:packages' for ghcr.io"
  fi

  log "Seeding platform-secrets in ns platform-secrets (github, ghcr, openchoreo)"
  kubectl --context "$CTX" create namespace platform-secrets --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
  apply_kv_secret platform-secrets platform-github "$gh_user" "$gh_token"
  apply_kv_secret platform-secrets platform-ghcr "$gh_user" "$gh_token"
  seed_openchoreo_secret
}

seed_argocd_repo_secret() {
  local repo_user="${GITHUB_USER:-}" repo_token="${GITHUB_TOKEN:-}"
  if [[ -z "$repo_token" && "$BACKEND" == "kubernetes" ]] && command -v gh >/dev/null 2>&1; then
    repo_user=$(gh api user --jq .login 2>/dev/null || true)
    repo_token=$(gh auth token 2>/dev/null || true)
  fi
  if [[ -n "$repo_token" ]]; then
    local cred_url="${GITHUB_ORG:-$REPO_URL}"
    local cred_type="repository"
    [[ -n "$GITHUB_ORG" ]] && cred_type="repo-creds"
    log "Creating Argo CD bootstrap ${cred_type} secret 'platform-repo-bootstrap' for $cred_url"
    kubectl --context "$CTX" create secret generic platform-repo-bootstrap \
      --namespace argocd \
      --from-literal=type=git \
      --from-literal=url="$cred_url" \
      --from-literal=username="${repo_user:-git}" \
      --from-literal=password="$repo_token" \
      --dry-run=client -o yaml | \
      CRED_TYPE="$cred_type" yq '.metadata.labels["argocd.argoproj.io/secret-type"] = strenv(CRED_TYPE)' | \
      kubectl --context "$CTX" apply -f - >/dev/null
  else
    warn "No GITHUB_TOKEN/gh auth token available; skipping bootstrap repo secret (fine if repo is public)"
  fi
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
  kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
  echo ""
}

cmd_ui() {
  load_inst
  require_bins kubectl
  echo "Argo CD admin password:"
  kubectl --context "$CTX" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
  echo ""
  log "Port-forwarding Argo CD UI to http://localhost:8081 (Ctrl-C to stop)"
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
