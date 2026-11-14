#!/usr/bin/env bash
# Toolchain helper. The versions live in mise.toml; this script only checks and finishes the install.
#   hack/tools.sh check [tool...]   every tool from mise.toml (or the named ones) is on PATH at the pinned version
#                                   (missing = error, other version = warning)
#   hack/tools.sh plugins           install the pinned helm-unittest plugin (idempotent; mise postinstall hook)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

# pinned <tool>: version from the [tools] table of mise.toml ("" if absent).
pinned() {
  awk -v t="$1" '
    /^\[/ { in_tools = ($0 == "[tools]") ; next }
    in_tools && $1 == t && $2 == "=" { gsub(/"/, "", $3); print $3; exit }
  ' mise.toml
}

# version_of <tool>: the tool's own version output (one line), or exit 1 when not installed.
version_of() {
  case "$1" in
    kubectl)     kubectl version --client 2>/dev/null | head -n1 ;;
    helm)        helm version --short 2>/dev/null ;;
    k3d)         k3d version 2>/dev/null | head -n1 ;;
    clusterctl)  clusterctl version -o short 2>/dev/null ;;
    argocd)      argocd version --client --short 2>/dev/null | head -n1 ;;
    yq)          yq --version 2>/dev/null ;;
    jq)          jq --version 2>/dev/null ;;
    kubeconform) kubeconform -v 2>/dev/null ;;
    crane)       crane version 2>/dev/null ;;
    shellcheck)  shellcheck --version 2>/dev/null | grep '^version:' ;;
    actionlint)  actionlint --version 2>/dev/null | head -n1 ;;
    python)      pick_python && "$PYTHON" --version 2>&1 ;;
    task)        task --version 2>/dev/null ;;
    gh)          gh --version 2>/dev/null | head -n1 ;;
    *)           "$1" --version 2>/dev/null | head -n1 ;;
  esac
}

cmd_check() {
  local tools=("$@") t want have missing=0 drift=0
  if (( ${#tools[@]} == 0 )); then
    while IFS= read -r t; do tools+=("$t"); done < <(
      awk '/^\[/ { in_tools = ($0 == "[tools]"); next } in_tools && $2 == "=" { print $1 }' mise.toml)
  fi
  for t in "${tools[@]}"; do
    want=$(pinned "$t")
    if ! have=$(version_of "$t" | tr -d '\r') || [[ -z "$have" ]]; then
      printf '  MISSING %-12s want %s\n' "$t" "${want:-?}"
      missing=$((missing + 1))
    elif [[ -n "$want" && "$have" != *"$want"* ]]; then
      printf '  DRIFT   %-12s want %-9s have: %s\n' "$t" "$want" "$have"
      drift=$((drift + 1))
    else
      printf '  ok      %-12s %s\n' "$t" "${want:-$have}"
    fi
  done
  if command -v helm >/dev/null 2>&1; then
    have=$(helm plugin list 2>/dev/null | awk '$1 == "unittest" { print $2 }')
    if [[ -z "$have" ]]; then
      printf '  MISSING %-12s want %s (task tools:plugins)\n' helm-unittest "${HELM_UNITTEST_VERSION:-?}"
      missing=$((missing + 1))
    else
      printf '  ok      %-12s %s\n' helm-unittest "$have"
    fi
  fi
  (( drift == 0 )) || echo "WARN: $drift tool(s) differ from mise.toml (run 'mise install' and activate mise in your shell)" >&2
  (( missing == 0 )) || { echo "ERROR: $missing tool(s) missing: run 'mise install' (docs/dev-environment.md)" >&2; return 1; }
}

cmd_plugins() {
  local want="${HELM_UNITTEST_VERSION:-1.2.1}" have major
  command -v helm >/dev/null 2>&1 || { echo "helm not on PATH yet; run 'mise install' first" >&2; return 1; }
  have=$(helm plugin list 2>/dev/null | awk '$1 == "unittest" { print $2 }')
  if [[ "$have" == "$want" ]]; then
    echo "helm-unittest $want already installed"
    return 0
  fi
  [[ -n "$have" ]] && helm plugin uninstall unittest >/dev/null
  major=$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v?([0-9]+).*/\1/')
  echo "Installing helm-unittest $want (helm $major)"
  if [[ "$major" -ge 4 ]]; then
    # Helm 4 verifies plugin provenance by default; helm-unittest's git source has none (checksums are checked by
    # its install hook instead).
    helm plugin install https://github.com/helm-unittest/helm-unittest.git --version "v$want" --verify=false
  else
    helm plugin install https://github.com/helm-unittest/helm-unittest.git --version "v$want"
  fi
}

case "${1:-check}" in
  check) shift || true; cmd_check "$@" ;;
  plugins) cmd_plugins ;;
  *) echo "usage: $0 [check [tool...]|plugins]" >&2; exit 2 ;;
esac
