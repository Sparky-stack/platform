#!/usr/bin/env bash
# hack/set-repo.sh on a scratch copy: rewrites repoURL / githubOrg / tenant repos, is idempotent, keeps label keys,
# honours APPS_ORG and DOCS=1.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_set_repo =="

copy() {
  local dst=$1
  mkdir -p "$dst/hack" "$dst/charts/platform" "$dst/docs/diagrams/src"
  cp -R "$ROOT/bootstrap" "$ROOT/installations" "$dst/"
  cp -R "$ROOT/hack/lib" "$ROOT/hack/set-repo.sh" "$dst/hack/"
  cp "$ROOT/charts/platform/values.yaml" "$dst/charts/platform/"
  cp "$ROOT/README.md" "$dst/"
  cp "$ROOT"/docs/*.md "$dst/docs/"
  cp "$ROOT/docs/diagrams/src/build.py" "$dst/docs/diagrams/src/"
}

# Default: everything follows the fork's org.
W="$TMP/default"; copy "$W"
out=$(bash "$W/hack/set-repo.sh" https://github.com/example/platform.git)
assert_eq "$(yq '.spec.source.repoURL' "$W/bootstrap/root-app.yaml")" "https://github.com/example/platform.git" "root app repoURL"
for f in "$W"/installations/*/installation.yaml "$W/charts/platform/values.yaml"; do
  assert_eq "$(yq '.installation.repoURL' "$f")" "https://github.com/example/platform.git" "repoURL in ${f#"$W"/}"
  assert_eq "$(yq '.installation.githubOrg' "$f")" "https://github.com/example" "githubOrg in ${f#"$W"/}"
done
assert_eq "$(yq '.apps[0].repoURL' "$W/installations/local/tenants/demo.yaml")" "https://github.com/example/hello-world.git" "tenant app repo follows ORG"
has() { grep -Eq -- "$1" "$2" && echo yes || echo no; }
assert_eq "$(has 'repoURL // "https://github.com/example/platform.git"' "$W/bootstrap/bootstrap.sh")" yes "bootstrap.sh fallback repoURL"
assert_eq "$(has 'githubOrg: https://github.com/example +# repo-creds' "$W/installations/local/installation.yaml")" yes "trailing comment kept"
assert_match "$out" "Changed 7 file\\(s\\)" "summary lists changed files"
assert_eq "$(grep -c 'platform\.koorikla\.io' "$W/installations/local/installation.yaml")" "1" "label key comment untouched"
assert_eq "$(has 'github\.com/koorikla/' "$W/README.md")" yes "docs untouched without DOCS=1"

out=$(bash "$W/hack/set-repo.sh" https://github.com/example/platform.git)
assert_match "$out" "Nothing to change" "second run is a no-op"

# ORG/APPS_ORG override: repo-creds prefix elsewhere, keep the upstream example app.
W="$TMP/keep"; copy "$W"
ORG=https://github.com/example-org APPS_ORG=https://github.com/koorikla \
  bash "$W/hack/set-repo.sh" https://github.com/example/platform.git >/dev/null
assert_eq "$(yq '.installation.githubOrg' "$W/installations/local/installation.yaml")" "https://github.com/example-org" "ORG override"
assert_eq "$(yq '.apps[0].repoURL' "$W/installations/local/tenants/demo.yaml")" "https://github.com/koorikla/hello-world.git" "APPS_ORG keeps upstream app"
# ...and switching the apps over later still finds them.
APPS_ORG=https://github.com/example bash "$W/hack/set-repo.sh" https://github.com/example/platform.git >/dev/null
assert_eq "$(yq '.apps[0].repoURL' "$W/installations/local/tenants/demo.yaml")" "https://github.com/example/hello-world.git" "APPS_ORG switch on re-run"

# DOCS=1 rewrites links, never label keys.
W="$TMP/docs"; copy "$W"
DOCS=1 bash "$W/hack/set-repo.sh" https://github.com/Example/platform.git >/dev/null
assert_eq "$(grep -c 'github\.com/koorikla/' "$W/README.md" || true)" "0" "README links rewritten"
assert_eq "$(grep -c 'ghcr\.io/koorikla/' "$W/docs/openchoreo.md" || true)" "0" "GHCR refs rewritten (lowercase owner)"
assert_eq "$(has 'ghcr\.io/example/hello-world' "$W/docs/openchoreo.md")" yes "GHCR owner lowercased"
assert_eq "$(has 'platform\.koorikla\.io/name' "$W/docs/conventions.md")" yes "label keys kept in docs"

# Bad input is rejected.
if bash "$W/hack/set-repo.sh" git@github.com:example/platform.git >/dev/null 2>&1; then
  assert_eq "accepted" "rejected" "ssh URL rejected"
else
  assert_eq "rejected" "rejected" "ssh URL rejected"
fi

finish
