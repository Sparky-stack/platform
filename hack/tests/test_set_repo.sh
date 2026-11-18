#!/usr/bin/env bash
# hack/set-repo.sh on a scratch copy: rewrites repoURL / githubOrg / tenant repos, is idempotent, keeps label keys,
# honours APPS_ORG and DOCS=1.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_set_repo =="

copy() {
  local dst=$1
  mkdir -p "$dst/hack" "$dst/charts/platform" "$dst/docs/runbooks" "$dst/docs/diagrams/src"
  cp -R "$ROOT/bootstrap" "$ROOT/installations" "$dst/"
  cp -R "$ROOT/hack/lib" "$ROOT/hack/set-repo.sh" "$dst/hack/"
  cp "$ROOT/charts/platform/values.yaml" "$dst/charts/platform/"
  cp "$ROOT/README.md" "$dst/"
  cp "$ROOT"/docs/*.md "$dst/docs/"
  cp "$ROOT"/docs/runbooks/*.md "$dst/docs/runbooks/"
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
assert_match "$out" "Changed 8 file\\(s\\)" "summary lists changed files"
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

# DOCS=1 rewrites links, never label keys; docs/forking.md (upstream fork/mirror steps) is left alone.
W="$TMP/docs"; copy "$W"
DOCS=1 bash "$W/hack/set-repo.sh" https://github.com/Example/platform.git >/dev/null
assert_eq "$(has '\[Example/hello-world\]\(https://github\.com/Example/hello-world\)' "$W/README.md")" yes "README hello-world link + text follow APPS_ORG"
assert_eq "$(has 'https://github\.com/Example/platform/issues/' "$W/docs/runbooks/incidents.md")" yes "runbook issue links follow REPO"
assert_eq "$(grep -c 'ghcr\.io/koorikla/' "$W/docs/openchoreo.md" || true)" "0" "GHCR refs rewritten (lowercase owner)"
assert_eq "$(has 'ghcr\.io/example/hello-world' "$W/docs/openchoreo.md")" yes "GHCR owner lowercased"
assert_eq "$(has 'platform\.koorikla\.io/name' "$W/docs/conventions.md")" yes "label keys kept in docs"
if cmp -s "$ROOT/docs/forking.md" "$W/docs/forking.md"; then same=yes; else same=no; fi
assert_eq "$same" yes "docs/forking.md untouched"
assert_eq "$(has '^git clone --bare https://github\.com/koorikla/platform\.git' "$W/docs/forking.md")" yes "forking.md mirror step still clones upstream"
assert_eq "$(has 'gh repo fork koorikla/platform' "$W/README.md")" yes "README fork command still names upstream"

# APPS_ORG=koorikla keeps the hello-world doc links (they must match the tenant file).
W="$TMP/docs-keep"; copy "$W"
APPS_ORG=https://github.com/koorikla DOCS=1 \
  bash "$W/hack/set-repo.sh" https://github.com/example/platform.git >/dev/null
assert_eq "$(has '\[koorikla/hello-world\]\(https://github\.com/koorikla/hello-world\)' "$W/README.md")" yes "APPS_ORG=koorikla keeps README hello-world link"
assert_eq "$(has 'repoURL: https://github\.com/koorikla/hello-world\.git' "$W/docs/openchoreo.md")" yes "APPS_ORG=koorikla keeps docs hello-world repo"
assert_eq "$(has 'ghcr\.io/koorikla/hello-world' "$W/docs/openchoreo.md")" yes "APPS_ORG=koorikla keeps GHCR image"
assert_eq "$(yq '.apps[0].repoURL' "$W/installations/local/tenants/demo.yaml")" "https://github.com/koorikla/hello-world.git" "tenant file matches the docs"

# A renamed fork: full repo URLs (+ link text) move to REPO, a longer repo name is left alone; round trip is clean.
W="$TMP/docs-rename"; copy "$W"
fixture='[koorikla/platform](https://github.com/koorikla/platform) https://github.com/koorikla/platform.git https://github.com/koorikla/platform/tree/main https://github.com/koorikla/platform-extras'
printf '%s\n' "$fixture" >> "$W/README.md"
cp "$W/README.md" "$TMP/README.orig"
DOCS=1 bash "$W/hack/set-repo.sh" https://github.com/Alice-Co/platform-fork.git >/dev/null
assert_eq "$(tail -1 "$W/README.md")" '[Alice-Co/platform-fork](https://github.com/Alice-Co/platform-fork) https://github.com/Alice-Co/platform-fork.git https://github.com/Alice-Co/platform-fork/tree/main https://github.com/koorikla/platform-extras' "renamed repo links"
DOCS=1 bash "$W/hack/set-repo.sh" https://github.com/koorikla/platform.git >/dev/null
if cmp -s "$TMP/README.orig" "$W/README.md"; then same=yes; else same=no; fi
assert_eq "$same" yes "round trip back to upstream restores README"

# Old orgs read from the repo that fail the URL check are skipped, not spliced into sed patterns.
W="$TMP/badorg"; copy "$W"
sed_out=$(sed 's#^\( *githubOrg: *\)https://[^ ]*#\1https://github.com/a|b#' "$W/installations/aws-example/installation.yaml")
printf '%s\n' "$sed_out" > "$W/installations/aws-example/installation.yaml"
if out=$(bash "$W/hack/set-repo.sh" https://github.com/example/platform.git 2>&1); then rc=0; else rc=$?; fi
assert_eq "$rc" 0 "bad old org does not break the run"
assert_match "$out" "ignoring unexpected old org URL" "bad old org reported"
assert_eq "$(yq '.installation.githubOrg' "$W/installations/aws-example/installation.yaml")" "https://github.com/example" "bad old org overwritten"

# sed_inplace reports a failing expression and leaves the file alone.
printf 'keep\n' > "$TMP/sedf"
if ( source "$ROOT/hack/lib/portable.sh"; sed_inplace 's|unterminated' "$TMP/sedf" ) 2>/dev/null; then rc=0; else rc=1; fi
assert_eq "$rc" 1 "sed_inplace propagates sed failure"
assert_eq "$(cat "$TMP/sedf")" keep "sed_inplace leaves the file on failure"

# Bad input is rejected; the message does not pretend only github.com works.
if out=$(bash "$W/hack/set-repo.sh" git@github.com:example/platform.git 2>&1); then rc=0; else rc=$?; fi
assert_eq "$rc" 2 "ssh URL rejected"
assert_match "$out" "https://<host>/<owner>/<name>\\.git" "error names any https host"

finish
