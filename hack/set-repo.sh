#!/usr/bin/env bash
# Point a fork of koorikla/platform at itself (docs/forking.md). Idempotent; prints every file it changed.
#
# Usage: hack/set-repo.sh https://github.com/<you>/platform.git
#        task set-repo REPO=https://github.com/<you>/platform.git [ORG=...] [APPS_ORG=...] [DOCS=1]
#
#   REPO      GitOps repo Argo CD reads (https, ends in .git)               -> root app, installation.repoURL
#   ORG       repo-creds URL prefix, default: REPO minus /<name>.git        -> installation.githubOrg
#   APPS_ORG  org of the tenant app repos (hello-world), default: ORG       -> installations/*/tenants/*.yaml
#             (APPS_ORG=https://github.com/koorikla keeps the upstream example app)
#   DOCS=1    also rewrite github.com/<old>/ and ghcr.io/<old>/ links in README.md, docs/*.md, diagram sources
#
# Never touched: label/annotation keys `platform.koorikla.io/*` (an API contract, not an org name), chart defaults
# under addons/ (installation.yaml overrides them), tests.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

UPSTREAM_ORG="https://github.com/koorikla"

REPO="${1:-${REPO:-}}"
REPO="${REPO%/}"
[[ -n "$REPO" ]] || { echo "usage: $0 <repo-url>  (e.g. https://github.com/you/platform.git)" >&2; exit 2; }
url_re='^https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+'
[[ "$REPO" =~ ${url_re}/[A-Za-z0-9_.-]+\.git$ ]] \
  || { echo "REPO must look like https://github.com/<owner>/<name>.git (got: $REPO)" >&2; exit 2; }
ORG="${ORG:-${REPO%/*}}"; ORG="${ORG%/}"
APPS_ORG="${APPS_ORG:-$ORG}"; APPS_ORG="${APPS_ORG%/}"
for v in ORG APPS_ORG; do
  [[ "${!v}" =~ ${url_re}$ ]] || { echo "$v must look like https://github.com/<owner> (got: ${!v})" >&2; exit 2; }
done
DOCS="${DOCS:-0}"

command -v yq >/dev/null 2>&1 || { echo "yq is required (mise install)" >&2; exit 1; }

# Escape for a sed BRE pattern / replacement (delimiter |; the URL checks above already exclude | and spaces).
re_esc()  { printf '%s' "$1" | sed 's#[]$*.^[\\]#\\&#g'; }
rep_esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
lower()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Orgs whose URLs count as "ours" and get rewritten: upstream, the current root app's org, every installation's
# githubOrg. Third-party app repos in tenant files are left alone.
OLD_ORGS=("$UPSTREAM_ORG")
add_old_org() {
  local o=${1%/} x
  [[ -n "$o" && "$o" != null ]] || return 0
  for x in "${OLD_ORGS[@]}"; do [[ "$x" == "$o" ]] && return 0; done
  OLD_ORGS+=("$o")
}
old_repo=$(yq '.spec.source.repoURL' bootstrap/root-app.yaml)
add_old_org "${old_repo%/*}"
for f in installations/*/installation.yaml; do
  add_old_org "$(yq '.installation.githubOrg // ""' "$f")"
done

CHANGED=()
# rewrite <sed-expr> <file>...: apply, remember files whose content changed.
rewrite() {
  local expr=$1 f before; shift
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    before=$(cksum < "$f")
    sed_inplace "$expr" "$f"
    if [[ "$(cksum < "$f")" != "$before" ]]; then
      case " ${CHANGED[*]-} " in *" $f "*) ;; *) CHANGED+=("$f") ;; esac
    fi
  done
}

r_repo=$(rep_esc "$REPO"); r_org=$(rep_esc "$ORG"); r_apps=$(rep_esc "$APPS_ORG")
inst_files=(installations/*/installation.yaml)

# 1. GitOps repo: root app, chart default, every installation, bootstrap.sh fallback.
rewrite "s|^\( *repoURL: *\)https://[^ #]*|\1${r_repo}|" bootstrap/root-app.yaml charts/platform/values.yaml "${inst_files[@]}"
rewrite "s|\(\.installation\.repoURL // \"\)https://[^\"]*\"|\1${r_repo}\"|" bootstrap/bootstrap.sh

# 2. repo-creds prefix (Argo CD credential template matching every repo under ORG).
rewrite "s|^\( *githubOrg: *\)https://[^ #]*|\1${r_org}|" charts/platform/values.yaml "${inst_files[@]}"

# 3. Tenant app repos owned by an old org -> APPS_ORG.
tenant_files=()
for f in installations/*/tenants/*.yaml; do [[ -f "$f" ]] && tenant_files+=("$f"); done
if (( ${#tenant_files[@]} > 0 )); then
  for o in "${OLD_ORGS[@]}"; do
    [[ "$o" == "$APPS_ORG" ]] && continue
    rewrite "s|^\( *repoURL: *\)$(re_esc "$o")/|\1${r_apps}/|" "${tenant_files[@]}"
  done
fi

# 4. Optional: links in prose and diagram sources.
if [[ "$DOCS" == 1 ]]; then
  doc_files=(README.md docs/diagrams/src/build.py)
  for f in docs/*.md docs/*/*.md; do [[ -f "$f" ]] && doc_files+=("$f"); done
  new_owner=${ORG##*/}
  for o in "${OLD_ORGS[@]}"; do
    old_owner=${o##*/}
    [[ "$old_owner" == "$new_owner" ]] && continue
    rewrite "s|github\.com/$(re_esc "$old_owner")/|github.com/$(rep_esc "$new_owner")/|g; s|ghcr\.io/$(re_esc "$(lower "$old_owner")")/|ghcr.io/$(rep_esc "$(lower "$new_owner")")/|g" \
      "${doc_files[@]}"
  done
fi

echo "repoURL    $REPO"
echo "githubOrg  $ORG"
echo "app repos  $APPS_ORG"
if (( ${#CHANGED[@]} == 0 )); then
  echo "Nothing to change: already pointing there."
  exit 0
fi
echo "Changed ${#CHANGED[@]} file(s):"
printf '  %s\n' "${CHANGED[@]}"
case " ${CHANGED[*]} " in
  *" docs/diagrams/src/build.py "*) echo "Regenerate the diagrams: python3 docs/diagrams/src/build.py" ;;
esac
echo "Next: commit + push, then 'task up' (or re-apply the root app: 'task argocd'). Manual steps: docs/forking.md"
