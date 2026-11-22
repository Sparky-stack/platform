#!/usr/bin/env bash
# Unit tests for scripts/common/workload-bump.sh and git-push-change.sh
# (bash 3.2 compatible; run by selftest.yaml and locally:
#   bash tests/scripts/workload-bump.test.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${ROOT}/scripts/common"
FIXTURE="${ROOT}/fixtures/openchoreo/workload.yaml"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/wb-test.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT
fails=0

ok() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  fails=$((fails + 1))
}

# bump / push_change - run the script under test; settings come from the caller's env prefix.
bump() { bash "${SCRIPTS}/workload-bump.sh" 2>/dev/null; }
push_change() { bash "${SCRIPTS}/git-push-change.sh" 2>/dev/null; }

d64="$(printf '%064d' 0 | tr 0 a)"
cp "${FIXTURE}" "${tmp}/w.yaml"

# 1. image + commit rewritten in place, everything else untouched.
CI_OUT_DIR="${tmp}/out" WORKLOAD_FILE="${tmp}/w.yaml" IMAGE="ghcr.io/koorikla/app:abc1234" \
  DIGEST="sha256:${d64}" COMMIT="abc1234def" bump
if grep -q "^    image: ghcr.io/koorikla/app:abc1234@sha256:${d64}\$" "${tmp}/w.yaml" &&
  grep -q '^    commit: "abc1234def"$' "${tmp}/w.yaml" &&
  [[ "$(grep -cvxFf "${FIXTURE}" "${tmp}/w.yaml")" == 2 ]] &&
  [[ "$(wc -l <"${tmp}/w.yaml")" == "$(wc -l <"${FIXTURE}")" ]] &&
  [[ "$(cat "${tmp}/out/changed")" == true ]]; then
  ok "bumps image and commit only"
else
  fail "bumps image and commit only"
  diff "${FIXTURE}" "${tmp}/w.yaml" || true
fi

# 2. idempotent.
CI_OUT_DIR="${tmp}/out" WORKLOAD_FILE="${tmp}/w.yaml" IMAGE="ghcr.io/koorikla/app:abc1234@sha256:${d64}" \
  COMMIT="abc1234def" bump
if [[ "$(cat "${tmp}/out/changed")" == false ]]; then ok "idempotent"; else fail "idempotent"; fi

# 3. rejects references without a tag or digest, and junk commits.
for bad in "ghcr.io/koorikla/app@sha256:${d64}" "ghcr.io/koorikla/app:tag" "ghcr.io/koorikla/app:tag@sha256:short"; do
  if WORKLOAD_FILE="${tmp}/w.yaml" IMAGE="${bad}" bump; then
    fail "rejects ${bad}"
  else
    ok "rejects ${bad}"
  fi
done
if WORKLOAD_FILE="${tmp}/w.yaml" IMAGE="r:t@sha256:${d64}" COMMIT='x"; rm -rf /' bump; then
  fail "rejects non-hex COMMIT"
else
  ok "rejects non-hex COMMIT"
fi

# 4. picks container.image, not an earlier image: key elsewhere; registry with port.
cat >"${tmp}/w2.yaml" <<'EOF'
metadata:
  annotations:
    image: keep-me
spec:
  container:
    # comment
    env: []
    image: old
EOF
WORKLOAD_FILE="${tmp}/w2.yaml" IMAGE="harbor.local:9443/apps/x:t1@sha256:${d64}" bump
if grep -q '^    image: keep-me$' "${tmp}/w2.yaml" && grep -q "^    image: harbor.local:9443/apps/x:t1@sha256:${d64}\$" "${tmp}/w2.yaml"; then
  ok "targets spec.container.image (registry with port)"
else
  fail "targets spec.container.image (registry with port)"
  cat "${tmp}/w2.yaml"
fi

# 5. comments survive the yq edit, every other line stays as it was, and only spec.source.commit is a commit.
cat >"${tmp}/w3.orig.yaml" <<'EOF'
# Workload of app x: CI bumps spec.container.image and spec.source.commit.
apiVersion: openchoreo.dev/v1alpha1
kind: Workload
metadata:
  name: x # trailing comment
  annotations:
    commit: keep-me # not the source commit
spec:
  source:
    # the commit the image was built from
    commit: "0000000"
  container:
    # bumped by CI; do not edit
    image: old
    args: ["--port", "8080"]
EOF
cp "${tmp}/w3.orig.yaml" "${tmp}/w3.yaml"
CI_OUT_DIR="${tmp}/out3" WORKLOAD_FILE="${tmp}/w3.yaml" IMAGE="r/x:t1@sha256:${d64}" COMMIT="abc1234" bump
if grep -q "^    image: r/x:t1@sha256:${d64}\$" "${tmp}/w3.yaml" &&
  grep -q '^    commit: "abc1234"$' "${tmp}/w3.yaml" &&
  grep -q '^    commit: keep-me # not the source commit$' "${tmp}/w3.yaml" &&
  [[ "$(grep -cvxFf "${tmp}/w3.orig.yaml" "${tmp}/w3.yaml")" == 2 ]] &&
  [[ "$(wc -l <"${tmp}/w3.yaml")" == "$(wc -l <"${tmp}/w3.orig.yaml")" ]] &&
  [[ "$(cat "${tmp}/out3/changed")" == true ]]; then
  ok "keeps comments and unrelated lines"
else
  fail "keeps comments and unrelated lines"
  diff "${tmp}/w3.orig.yaml" "${tmp}/w3.yaml" || true
fi

# 6. no spec.source: only the image moves (with a warning).
printf 'spec:\n  container:\n    image: old\n' >"${tmp}/w4.yaml"
WORKLOAD_FILE="${tmp}/w4.yaml" IMAGE="r/x:t@sha256:${d64}" COMMIT="abc1234" bump
if grep -q "^    image: r/x:t@sha256:${d64}\$" "${tmp}/w4.yaml" && ! grep -q 'commit' "${tmp}/w4.yaml"; then
  ok "no spec.source: bumps the image only"
else
  fail "no spec.source: bumps the image only"
  cat "${tmp}/w4.yaml"
fi

# 7. no spec.container.image: refuses, even when other image: keys exist.
printf 'metadata:\n  image: keep-me\nspec:\n  owner: {}\n' >"${tmp}/w5.yaml"
if WORKLOAD_FILE="${tmp}/w5.yaml" IMAGE="r/x:t@sha256:${d64}" bump; then
  fail "refuses a Workload without spec.container.image"
else
  ok "refuses a Workload without spec.container.image"
fi

# 8. git-push-change.sh: commits only when changed, PUSH=false never pushes.
repo="${tmp}/repo"
git init -q "${repo}"
cp "${FIXTURE}" "${repo}/w.yaml"
git -C "${repo}" add w.yaml
git -C "${repo}" -c user.name=t -c user.email=t@t commit -q -m init
(
  cd "${repo}"
  CI_OUT_DIR="${tmp}/out2" PATHS=w.yaml MESSAGE=noop BRANCH=main PUSH=false push_change
)
if [[ "$(git -C "${repo}" rev-list --count HEAD)" == 1 && "$(cat "${tmp}/out2/pushed")" == false ]]; then
  ok "no commit without changes"
else
  fail "no commit without changes"
fi
(
  cd "${repo}"
  WORKLOAD_FILE=w.yaml IMAGE="r/x:t@sha256:${d64}" bump
  CI_OUT_DIR="${tmp}/out2" PATHS=w.yaml MESSAGE="chore: bump [skip ci]" BRANCH=main PUSH=false push_change
)
if [[ "$(git -C "${repo}" rev-list --count HEAD)" == 2 && "$(git -C "${repo}" log -1 --format=%s)" == "chore: bump [skip ci]" &&
  -n "$(cat "${tmp}/out2/commit_sha")" ]]; then
  ok "commits the change locally with PUSH=false"
else
  fail "commits the change locally with PUSH=false"
fi

[[ "${fails}" -eq 0 ]] || {
  printf '%s test(s) failed\n' "${fails}"
  exit 1
}
printf 'all workload-bump tests passed\n'
