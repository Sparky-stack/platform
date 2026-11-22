#!/usr/bin/env bash
# Build guards of the in-cluster build (ClusterWorkflowTemplate koorikla-build), sourced by checkout.sh and gitops.sh.
#
# The run's git token only ever reaches the installation's allowed repository prefixes (GIT_ALLOWED_PREFIXES, rendered
# by addon openchoreo-platform from installation.githubOrg; the ClusterWorkflow schema enforces the same pattern on
# repository.url, this is the second line): the URL is checked first, git config comes only from the environment (no
# system or global gitconfig, https only), and the credential helper is registered per prefix, so git never answers a
# 401 from any other host or owner. Ref and path parameters are checked against option injection and traversal. The
# token is a GitHub App installation token for this one repository (ESO generator <run>-git): git_access fails the run
# with the reason when it is missing, instead of an anonymous clone.
#
# Env in:
#   GIT_ALLOWED_PREFIXES  space-separated URL prefixes the token may be sent to
#   GIT_SECRET            name of the run's git Secret (<run>-git), for the error message
#   RUN_NAMESPACE         the run's namespace, for the error message
#   GIT_SECRET_DIR        where the Secret is mounted (default /secrets/git)
#   GIT_SECRET_WAIT       seconds to wait for ESO to write it (default 120)
#   TMPDIR                where the credential helper is written (default /tmp)
# Functions: die, check_repo, check_ref, check_workload_path, git_access.
# Linux toolbox only. hack/tests/test_build_guards.sh runs every guard with negative cases.
# shellcheck disable=SC2016  # the credential helper is written with literal $1 and $(cat ...)
die() { echo ">> $*" >&2; exit 1; }
# bash [[ =~ ]] matches the whole value (grep would accept any single matching line of a multi-line one)
re_name='^[A-Za-z0-9][A-Za-z0-9._-]*$'
re_ref='^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
re_workload='^deploy/openchoreo/[A-Za-z0-9][A-Za-z0-9._-]*\.yaml$'
check_repo() {
  local p rest
  for p in $GIT_ALLOWED_PREFIXES; do
    rest=${1#"$p"}
    if [[ "$rest" != "$1" && "$rest" =~ $re_name ]]; then return 0; fi
  done
  die "repository '$1' is not under an allowed prefix (${GIT_ALLOWED_PREFIXES:-none})"
}
check_ref() {
  [[ -z "$1" || "$1" =~ $re_ref ]] || die "invalid git ref '$1'"
}
check_workload_path() {
  [[ "$1" =~ $re_workload ]] || die "gitops.workloadPath must be deploy/openchoreo/<name>.yaml (got '$1')"
}
git_access() {
  local n=0 p helper="${TMPDIR:-/tmp}/git-credential" dir="${GIT_SECRET_DIR:-/secrets/git}"
  check_repo "$1"
  unset GIT_ASKPASS SSH_ASKPASS
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
  cfg() { export "GIT_CONFIG_KEY_$n=$1" "GIT_CONFIG_VALUE_$n=$2"; n=$((n + 1)); }
  cfg protocol.allow never
  cfg protocol.https.allow always
  cfg credential.useHttpPath true
  # ESO writes the Secret right after the run starts; the kubelet refreshes the mounted volume.
  local waited=0
  while [ ! -s "$dir/password" ] && [ "$waited" -lt "${GIT_SECRET_WAIT:-120}" ]; do sleep 5; waited=$((waited + 5)); done
  [ -s "$dir/password" ] || die "no GitHub token for $1: Secret ${GIT_SECRET:-<run>-git} was not created." \
    "The platform GitHub App must be installed on this repository with Contents: Read and write" \
    "(GitHub: Settings > Applications > the App > Configure > Repository access). Status:" \
    "kubectl -n ${RUN_NAMESPACE:-workflows-<org ns>} describe externalsecret ${GIT_SECRET:-<run>-git};" \
    "GitHub's answer (e.g. 422 not accessible to the installation): kubectl -n external-secrets logs" \
    "deploy/external-secrets | grep ${GIT_SECRET:-<run>-git}"
  printf '#!/bin/sh\n[ "$1" = get ] || exit 0\necho "username=$(cat %s/username)"\necho "password=$(cat %s/password)"\n' \
    "$dir" "$dir" > "$helper"
  chmod 0700 "$helper"
  for p in $GIT_ALLOWED_PREFIXES; do cfg "credential.${p}.helper" "$helper"; done
  export GIT_CONFIG_COUNT=$n
}
