#!/usr/bin/env bash
# Point a fork of koorikla/platform at itself (docs/forking.md). Idempotent; prints every file it changed.
#
# Usage: hack/set-repo.sh https://github.com/<you>/platform.git
#        task set-repo REPO=https://github.com/<you>/platform.git [ORG=...] [APPS_ORG=...] [DOCS=1 [CI_ORG=...]]
#
#   REPO      GitOps repo Argo CD reads (https, ends in .git)               -> root app, installation.repoURL
#   ORG       repo-creds URL prefix, default: REPO minus /<name>.git        -> installation.githubOrg
#   APPS_ORG  org of the tenant app repos (hello-world), default: ORG       -> installations/*/tenants/*.yaml
#             (APPS_ORG=https://github.com/koorikla keeps the upstream example app)
#   DOCS=1    also rewrite links in README.md, docs/*.md (not docs/forking.md: its fork steps must keep pointing at
#             upstream) and diagram sources: <old>/platform URLs + [owner/name] link texts -> REPO, <old>/hello-world
#             and ghcr.io/<old>/ -> APPS_ORG, <old>/ci only when CI_ORG is given (default: keep upstream koorikla/ci)
#   CI_ORG    with DOCS=1: org of your koorikla/ci fork
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
  || { echo "REPO must look like https://<host>/<owner>/<name>.git, e.g. https://github.com/you/platform.git (got: $REPO)" >&2; exit 2; }
ORG="${ORG:-${REPO%/*}}"; ORG="${ORG%/}"
APPS_ORG="${APPS_ORG:-$ORG}"; APPS_ORG="${APPS_ORG%/}"
CI_ORG="${CI_ORG:-}"; CI_ORG="${CI_ORG%/}"
for v in ORG APPS_ORG CI_ORG; do
  [[ "$v" == CI_ORG && -z "$CI_ORG" ]] && continue
  [[ "${!v}" =~ ${url_re}$ ]] || { echo "$v must look like https://<host>/<owner>, e.g. https://github.com/you (got: ${!v})" >&2; exit 2; }
done
DOCS="${DOCS:-0}"

command -v yq >/dev/null 2>&1 || { echo "yq is required (mise install)" >&2; exit 1; }

# Escape for a sed BRE pattern / replacement (delimiter |; the URL checks above already exclude | and spaces).
re_esc()  { printf '%s' "$1" | sed 's#[]$*.^[\\]#\\&#g'; }
rep_esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
lower()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Orgs whose URLs count as "ours" and get rewritten: upstream, the current root app's org, every installation's
# githubOrg. Third-party app repos in tenant files are left alone. Values read from the repo go into sed patterns, so
# anything that would not pass the same check as user input is skipped.
OLD_ORGS=("$UPSTREAM_ORG")
add_old_org() {
  local o=${1%/} x
  [[ -n "$o" && "$o" != null ]] || return 0
  [[ "$o" =~ ${url_re}$ ]] || { echo "WARN: ignoring unexpected old org URL: $o" >&2; return 0; }
  for x in "${OLD_ORGS[@]}"; do [[ "$x" == "$o" ]] && return 0; done
  OLD_ORGS+=("$o")
}
# Platform repos (https://<host>/<owner>/<name>, no .git) whose doc links DOCS=1 moves to REPO.
OLD_REPOS=("$UPSTREAM_ORG/platform")
old_repo=$(yq '.spec.source.repoURL' bootstrap/root-app.yaml)
add_old_org "${old_repo%/*}"
if [[ "$old_repo" =~ ${url_re}/[A-Za-z0-9_.-]+\.git$ && "${old_repo%.git}" != "${OLD_REPOS[0]}" ]]; then
  OLD_REPOS+=("${old_repo%.git}")
fi
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
# ref_expr <old host/owner/name> <new host/owner/name>: sed expressions moving one repo's URLs (with or without
# .git; a longer name such as platform-fork is a different repo) and its markdown link texts [owner/name].
ref_expr() {
  local o n os ns nc='[^A-Za-z0-9_.-]'
  o=$(re_esc "$1"); n=$(rep_esc "$2"); os=$(re_esc "${1#*/}"); ns=$(rep_esc "${2#*/}")
  printf '%s' "s|$o\\.git\\($nc\\)|$n.git\\1|g; s|$o\\.git\$|$n.git|; s|$o\\($nc\\)|$n\\1|g; s|$o\$|$n|; s|\\[$os]|[$ns]|g"
}
if [[ "$DOCS" == 1 ]]; then
  doc_files=(README.md docs/diagrams/src/build.py)
  for f in docs/*.md docs/*/*.md; do
    [[ -f "$f" && "$f" != docs/forking.md ]] && doc_files+=("$f")
  done
  new_repo=${REPO#https://}; new_repo=${new_repo%.git}
  for o in "${OLD_REPOS[@]}"; do
    [[ "${o#https://}" == "$new_repo" ]] || rewrite "$(ref_expr "${o#https://}" "$new_repo")" "${doc_files[@]}"
  done
  for o in "${OLD_ORGS[@]}"; do
    if [[ "$o" != "$APPS_ORG" ]]; then
      rewrite "$(ref_expr "${o#https://}/hello-world" "${APPS_ORG#https://}/hello-world")" "${doc_files[@]}"
      # Images come from the app repos' CI: ghcr.io/<owner>/ follows APPS_ORG (GHCR owners are lowercase).
      if [[ "$o" == https://github.com/* && "$APPS_ORG" == https://github.com/* ]]; then
        rewrite "s|ghcr\\.io/$(re_esc "$(lower "${o##*/}")")/|ghcr.io/$(rep_esc "$(lower "${APPS_ORG##*/}")")/|g" "${doc_files[@]}"
      fi
    fi
    if [[ -n "$CI_ORG" && "$o" != "$CI_ORG" ]]; then
      rewrite "$(ref_expr "${o#https://}/ci" "${CI_ORG#https://}/ci")" "${doc_files[@]}"
    fi
  done
fi

echo "repoURL    $REPO"
echo "githubOrg  $ORG"
echo "app repos  $APPS_ORG"
[[ "$DOCS" == 1 ]] && echo "ci repo    ${CI_ORG:-$UPSTREAM_ORG (CI_ORG not set: links kept)}"
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
