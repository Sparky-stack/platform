#!/usr/bin/env bash
# koorikla-build step `gitops`: commit the signed image ref (tag + digest) and source commit into the app repo's
# Workload manifest. Argo CD syncs it (Application <project>-<app>, charts/tenant); with autoDeploy the Component
# controller cuts a ComponentRelease and binds the first pipeline environment. The commit goes through the GitHub
# contents API with the run's App installation token, so GitHub authors, commits and signs it as the App's bot (no git
# identity, no push credential); `sha` makes it a compare-and-swap, a concurrent commit (409) re-reads the branch and
# retries. An unchanged Workload is not committed again.
#
# Env in:  REPO, GITOPS_BRANCH, WORKLOAD_PATH (deploy/openchoreo/<name>.yaml), GITHUB_API_URL, IMAGE, COMMIT_SHA,
#          SHORT_SHA, COMPONENT, PROJECT, NAMESPACE, RUN (commit message), plus the guards.sh env
# Linux toolbox only (GNU realpath -e, base64 -w0).
set -euo pipefail
# shellcheck source=guards.sh
source "$(dirname "${BASH_SOURCE[0]}")/guards.sh"

check_ref "$GITOPS_BRANCH"; check_workload_path "$WORKLOAD_PATH"
git_access "$REPO"
slug=${REPO#https://*/}; slug=${slug%.git}
[[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$REPO is not https://<host>/<owner>/<repo>"
[[ "$GITHUB_API_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]] || die "github-api-url must be https (got '$GITHUB_API_URL')"
umask 077
printf 'Authorization: Bearer %s\n' "$(cat "${GIT_SECRET_DIR:-/secrets/git}/password")" > /tmp/gh-auth
msg=$(printf 'chore(deploy): %s image %s [skip ci]\n\nOpenChoreo WorkflowRun %s (%s/%s/%s): %s' \
  "$COMPONENT" "$SHORT_SHA" "$RUN" "$NAMESPACE" "$PROJECT" "$COMPONENT" "$IMAGE")
export IMAGE COMMIT_SHA
for i in 1 2 3 4 5; do
  cd /tmp && rm -rf /tmp/gitops
  git clone -q --depth 1 --branch "$GITOPS_BRANCH" -- "$REPO" /tmp/gitops
  cd /tmp/gitops
  # Only an OpenChoreo Workload under deploy/openchoreo/ is ever rewritten (no symlink out of it).
  # shellcheck disable=SC2015 # die exits, so this is if-then-else
  [ -f "$WORKLOAD_PATH" ] && [ ! -L "$WORKLOAD_PATH" ] && [ ! -L deploy ] && [ ! -L deploy/openchoreo ] \
    || die "$WORKLOAD_PATH not found (or a symlink on its path) in $REPO@$GITOPS_BRANCH"
  case "$(realpath -e "$WORKLOAD_PATH")" in
    "$(realpath -e deploy/openchoreo)"/*) ;;
    *) die "$WORKLOAD_PATH resolves outside deploy/openchoreo/" ;;
  esac
  [ "$(yq '.kind' "$WORKLOAD_PATH")" = Workload ] || die "$WORKLOAD_PATH is not an OpenChoreo Workload"
  yq -i '.spec.container.image = strenv(IMAGE)' "$WORKLOAD_PATH"
  if [ "$(yq '.spec | has("source")' "$WORKLOAD_PATH")" = true ]; then
    yq -i '.spec.source.commit = strenv(COMMIT_SHA)' "$WORKLOAD_PATH"
  fi
  if git diff --quiet -- "$WORKLOAD_PATH"; then echo ">> $WORKLOAD_PATH already at $IMAGE"; exit 0; fi
  jq -n --arg message "$msg" --arg branch "$GITOPS_BRANCH" --arg sha "$(git rev-parse "HEAD:$WORKLOAD_PATH")" \
    --arg content "$(base64 -w0 "$WORKLOAD_PATH")" \
    '{message: $message, content: $content, sha: $sha, branch: $branch}' > /tmp/body.json
  code=$(curl -sS --proto =https -o /tmp/gh.json -w '%{http_code}' -X PUT -H @/tmp/gh-auth \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    --data-binary @/tmp/body.json "$GITHUB_API_URL/repos/$slug/contents/$WORKLOAD_PATH") || code=000
  case "$code" in
    200|201)
      echo ">> committed $(jq -r '.commit.sha' /tmp/gh.json) to $slug@$GITOPS_BRANCH as $(jq -r '.commit.author.name' /tmp/gh.json)"
      exit 0 ;;
    409) echo ">> $GITOPS_BRANCH moved, re-reading (attempt $i)"; sleep $((i * 2)) ;;
    *) die "GitHub contents API ($slug $WORKLOAD_PATH): HTTP $code $(jq -r '.message? // empty' /tmp/gh.json 2>/dev/null || true)." \
         "The platform GitHub App needs Contents: Read and write on $slug, and a bypass if $GITOPS_BRANCH is protected" ;;
  esac
done
die "$GITOPS_BRANCH kept moving: gave up after 5 attempts"
