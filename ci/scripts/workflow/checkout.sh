#!/usr/bin/env bash
# koorikla-build step `checkout` (also koorikla-helm-chart's, through templateRef): shallow fetch of the requested commit
# (or branch head) into /work/source with the run's git credentials (guards.sh: credential helper scoped to the allowed
# repository prefixes, never in the URL or the logs).
# Loop guard: a commit that only touches the GitOps directory (the hand-off commit of a previous run, or a manual
# promotion) is not rebuilt - relevant once autoBuild webhooks are on, because OpenChoreo's webhook matcher treats
# appPath "." as "every change".
#
# Env in:  REPO, BRANCH, COMMIT (empty: branch head), WORKLOAD_PATH (its directory is the GitOps directory), plus the
#          guards.sh env (GIT_ALLOWED_PREFIXES, GIT_SECRET, RUN_NAMESPACE)
# Out:     /tmp/commit-sha, /tmp/short-sha, /tmp/skip (Argo output parameters); /work/source, /work/out, /work/home
set -euo pipefail
# shellcheck source=guards.sh
source "$(dirname "${BASH_SOURCE[0]}")/guards.sh"

check_ref "$BRANCH"; check_ref "$COMMIT"
git_access "$REPO"
rm -rf /work/source && mkdir -p /work/source /work/out /work/home && cd /work/source
git init -q . && git remote add origin "$REPO"
ref="${COMMIT:-$BRANCH}"
echo ">> fetching $REPO $ref"
git fetch -q --depth 2 origin "$ref"
git -c advice.detachedHead=false checkout -q FETCH_HEAD
sha=$(git rev-parse HEAD)
skip=false
changed=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
gitops_dir=$(dirname "$WORKLOAD_PATH")
if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -qv "^${gitops_dir}/"; then
  skip=true
  echo ">> $sha only changes ${gitops_dir}/ (GitOps hand-off or promotion): nothing to build"
fi
printf '%s' "$sha" > /tmp/commit-sha
printf '%s' "${sha:0:7}" > /tmp/short-sha
printf '%s' "$skip" > /tmp/skip
echo ">> $(git log -1 --format='%h %an: %s')"
