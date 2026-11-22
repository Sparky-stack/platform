#!/usr/bin/env bash
# In-cluster build guards (addons openchoreo-platform + openchoreo-workflow-plane, ci/scripts/workflow), negative tests
# first:
#   - the ClusterWorkflow schema patterns reject foreign hosts/owners, traversal and option injection
#   - guards.sh (sourced by checkout.sh and gitops.sh) refuses foreign repositories and hands the git token only to the
#     allowed prefixes (real `git credential fill`), https only; operator messages word for word
#   - gitops.sh rewrites only a real OpenChoreo Workload under deploy/openchoreo/ (no symlink out, no other kind), through
#     the GitHub contents API as the App
#   - sign.sh skips the public Rekor log unless the installation opts in (cosign v3 signing config)
#   - run pods get no ServiceAccount token (only Argo's executor containers do)
#   - the ClusterWorkflowTemplates only call these scripts: no eval, no inline args script, no env var holding code
# shellcheck disable=SC2016  # literal shell code passed to bash -c / matched as text
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"
command -v git >/dev/null || { echo "  SKIP: git not found"; exit 0; }

if [[ ! -d addons/openchoreo-platform/charts || ! -d addons/openchoreo-workflow-plane/charts ]]; then
  ./hack/deps.sh >/dev/null 2>&1 || true
fi
render_standalone_addon openchoreo-platform "$TMP/platform.yaml"
render_standalone_addon openchoreo-workflow-plane "$TMP/plane.yaml"
yq 'select(.kind == "ClusterWorkflow")' "$TMP/platform.yaml" > "$TMP/cw.yaml"
yq 'select(.kind == "ClusterWorkflowTemplate")' "$TMP/plane.yaml" > "$TMP/cwt.yaml"

cw() { yq -r "select(.metadata.name == \"$1\") | $2" "$TMP/cw.yaml"; }
cwt() { yq -r "select(.metadata.name == \"$1\") | $2" "$TMP/cwt.yaml"; }
S='.spec.parameters.openAPIV3Schema.properties'

# accepts <label> <pattern> <value>... / rejects <label> <pattern> <value>...  (ERE == the RE2 subset used here)
accepts() { local l=$1 re=$2 v; shift 2; for v in "$@"; do assert_eq "$([[ "$v" =~ $re ]] && echo yes || echo no)" yes "$l accepts '$v'"; done; }
rejects() { local l=$1 re=$2 v; shift 2; for v in "$@"; do assert_eq "$([[ "$v" =~ $re ]] && echo yes || echo no)" no "$l rejects '$v'"; done; }

# --- schema patterns --------------------------------------------------------------------------------------------
for wf in go dockerfile; do
  url=$(cw "$wf" "$S.repository.properties.url.pattern")
  assert_nonempty "$url" "$wf: repository.url has a pattern"
  accepts "$wf url" "$url" https://github.com/koorikla/hello-world https://github.com/koorikla/hello-world.git \
    https://github.com/koorikla/a_b-c.d
  rejects "$wf url" "$url" https://attacker.example/x.git https://github.com/other/x https://github.com/koorikla-evil/x \
    https://github.com/koorikla/../platform https://github.com/koorikla/.. https://github.com/koorikla/a/b \
    http://github.com/koorikla/x "https://github.com/koorikla/x?y=1" https://u:p@github.com/koorikla/x \
    https://github.com.evil.io/koorikla/x file:///etc/passwd git@github.com:koorikla/x.git "" \
    "$(printf 'https://github.com/koorikla/ok\nhttps://attacker.example/x')"
  wl=$(cw "$wf" "$S.gitops.properties.workloadPath.pattern")
  accepts "$wf workloadPath" "$wl" deploy/openchoreo/workload.yaml deploy/openchoreo/api.yaml
  rejects "$wf workloadPath" "$wl" .github/workflows/ci.yaml deploy/openchoreo/../../.github/workflows/ci.yaml \
    deploy/openchoreo/sub/x.yaml /deploy/openchoreo/x.yaml deploy/openchoreo/x.yml README.md deploy/openchoreo/.yaml
  br=$(cw "$wf" "$S.repository.properties.revision.properties.branch.pattern")
  accepts "$wf branch" "$br" main release/1.2 feature_x
  rejects "$wf branch" "$br" --upload-pack=touch -b "" "a b"
  co=$(cw "$wf" "$S.repository.properties.revision.properties.commit.pattern")
  accepts "$wf commit" "$co" "" abc1234 0123456789abcdef0123456789abcdef01234567
  rejects "$wf commit" "$co" --upload-pack=x main abc HEAD~1
  for f in docker.properties.context docker.properties.filePath repository.properties.appPath; do
    rp=$(cw "$wf" "$S.$f.pattern")
    accepts "$wf $f" "$rp" . Dockerfile ./app app/sub/ .docker/Dockerfile build/Dockerfile.prod
    rejects "$wf $f" "$rp" .. ../x a/../../registry-auth /registry-auth -x "" "a//b"
  done
done
url=$(cw helm-chart "$S.repository.properties.url.pattern")
rejects "helm-chart url" "$url" https://attacker.example/x.git https://github.com/other/x
rejects "helm-chart chart.path" "$(cw helm-chart "$S.chart.properties.path.pattern")" ../x /etc

# --- step scripts (ci/scripts/workflow) -----------------------------------------------------------------------------
WF="$ROOT/ci/scripts/workflow"
TMPP=$(cd "$TMP" && pwd -P)   # physical path: the scripts compare realpath results against their pod paths
# stage <root>: copy ci/scripts/workflow to <root>/opt/scripts (the toolbox's copy), next to ci/scripts/common, with
# its pod paths (/work/, /tmp/, /ci/, /cosign/, /registry-ca/, /etc/, ...) pointing under <root>. Paths without a trailing `/` (DOCKER_CONFIG=/registry-auth,
# `cd /tmp`) stay as they are. The tests create the pod's mounts under <root>.
stage() {
  local root=$1 f
  rm -rf "$root"; mkdir -p "$root/opt/scripts/workflow" "$root/tmp" "$root/work" "$root/etc/ssl/certs"
  cp -R "$ROOT/ci/scripts/common" "$root/opt/scripts/common"
  for f in "$WF"/*.sh; do
    sed -E "s#/(work|tmp|ci|registry-auth|registry-ca|cosign|buildkitd|etc)/#$root/\1/#g" "$f" > "$root/opt/scripts/workflow/${f##*/}"
  done
  printf 'system roots\n' > "$root/etc/ssl/certs/ca-certificates.crt"
}

# --- guards.sh: repository allowlist and scoped credentials ---------------------------------------------------------
GUARDS="$WF/guards.sh"
assert_eq "$(grep -c 'GIT_ASKPASS=' "$TMP/plane.yaml" || true)" 0 "no global GIT_ASKPASS anywhere"
for step in checkout gitops; do
  assert_match "$(cat "$WF/$step.sh")" 'source "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/guards.sh"' "$step.sh sources guards.sh"
  assert_match "$(cat "$WF/$step.sh")" $'\ngit_access "\\$REPO"\n' "$step.sh calls git_access before any git command"
done

SEC="$TMP/git-secret"; mkdir -p "$SEC"; printf 'builder' > "$SEC/username"; printf 'TOKEN-FAKE-123' > "$SEC/password"
ALLOWED="https://github.com/koorikla/ https://git.example.com/team/"
# guard <cmd>: run cmd after sourcing guards.sh in a clean environment (no user gitconfig); OUT = stdout+stderr, RC = rc
guard() {
  if env -i PATH="$PATH" HOME="$TMP/home" TMPDIR="$TMP" GIT_SECRET_DIR="$SEC" GIT_ALLOWED_PREFIXES="$ALLOWED" \
      GUARDS="$GUARDS" bash -c 'set -euo pipefail; source "$GUARDS"; '"$1" > "$TMP/guard.out" 2>&1; then RC=0; else RC=$?; fi
  OUT=$(cat "$TMP/guard.out")
}
mkdir -p "$TMP/home"
fill() { printf 'git_access %q; printf "url=%%s\\\\n\\\\n" %q | git credential fill 2>&1 || true' "$1" "$2"; }

guard "$(fill https://github.com/koorikla/hello-world.git https://github.com/koorikla/hello-world.git)"; out=$OUT
assert_match "$out" 'password=TOKEN-FAKE-123' "allowed repo: credential helper answers"
guard "$(fill https://git.example.com/team/app https://git.example.com/team/app)"; out=$OUT
assert_match "$out" 'password=TOKEN-FAKE-123' "second allowed prefix: credential helper answers"
for victim in https://attacker.example/koorikla/x.git https://github.com/other/x.git https://github.com/koorikla-evil/x.git \
  https://git.example.com/other/x; do
  guard "$(fill https://github.com/koorikla/hello-world.git "$victim")"; out=$OUT
  assert_eq "$([[ "$out" == *TOKEN-FAKE-123* ]] && echo leaked || echo kept)" kept "token not sent to $victim (redirect/401)"
done
for bad in https://attacker.example/x.git https://github.com/other/x https://github.com/koorikla-evil/x \
  https://github.com/koorikla/../platform https://github.com/koorikla/a/b "file:///$TMP" "ext::sh -c touch% /tmp/pwned" \
  "$(printf 'https://github.com/koorikla/ok\nhttps://attacker.example/x')"; do
  guard "git_access $(printf %q "$bad"); echo REACHED"; out=$OUT
  assert_eq "$RC:$([[ "$out" == *REACHED* ]] && echo reached || echo stopped)" "1:stopped" "git_access refuses '$bad'"
  assert_match "$out" 'not under an allowed prefix' "git_access says why for '$bad'"
done
# the operator-facing messages, word for word
guard 'git_access https://attacker.example/x.git'
assert_eq "$OUT" ">> repository 'https://attacker.example/x.git' is not under an allowed prefix ($ALLOWED)" \
  "foreign host: exact message"
guard 'GIT_ALLOWED_PREFIXES=""; git_access https://github.com/koorikla/x; echo REACHED'; out=$OUT
assert_eq "$RC:$out" "1:>> repository 'https://github.com/koorikla/x' is not under an allowed prefix (none)" \
  "empty allowlist refuses everything"
for ref in --upload-pack=touch -b "a b"; do
  guard "check_ref $(printf %q "$ref")"
  assert_eq "$RC:$OUT" "1:>> invalid git ref '$ref'" "check_ref refuses '$ref' (exact message)"
done
guard 'check_ref main; check_ref ""; check_ref 0123abc'
assert_eq "$RC" 0 "check_ref accepts main, empty, a sha"
for wl in .github/workflows/ci.yaml deploy/openchoreo/../../x.yaml deploy/openchoreo/a/b.yaml; do
  guard "check_workload_path $(printf %q "$wl")"
  assert_eq "$RC:$OUT" "1:>> gitops.workloadPath must be deploy/openchoreo/<name>.yaml (got '$wl')" \
    "check_workload_path refuses '$wl' (exact message)"
done
guard 'check_workload_path deploy/openchoreo/workload.yaml'
assert_eq "$RC" 0 "check_workload_path accepts deploy/openchoreo/workload.yaml"
# https only: file:// (and every other transport) is off even for a URL that slipped through
git init -q --bare "$TMP/bare.git"
guard "git_access https://github.com/koorikla/x; git ls-remote file://$TMP/bare.git && echo LISTED"; out=$OUT
assert_eq "$([[ "$out" == *LISTED* ]] && echo listed || echo blocked)" blocked "protocol.allow never: file:// blocked"
guard 'git_access https://github.com/koorikla/x; env | grep -c "^GIT_ASKPASS=" || true'; out=$OUT
assert_eq "$out" 0 "git_access leaves no GIT_ASKPASS"
guard 'git_access https://github.com/koorikla/x; echo "$GIT_CONFIG_NOSYSTEM $GIT_CONFIG_GLOBAL"'
assert_eq "$OUT" "1 /dev/null" "git_access: no system or global gitconfig"
# No token (the platform GitHub App is not installed on the repository, so ESO's generator never wrote <run>-git): the
# run stops with the reason instead of an anonymous clone and a failing push at the end (#34).
rm -f "$TMP/git-credential"
out=$(env -i PATH="$PATH" HOME="$TMP/home" TMPDIR="$TMP" GIT_SECRET_DIR="$TMP/none" GIT_SECRET_WAIT=0 GIT_SECRET=run-1-git \
  RUN_NAMESPACE=workflows-default GIT_ALLOWED_PREFIXES="https://github.com/koorikla/" \
  GUARDS="$GUARDS" bash -c 'set -euo pipefail; source "$GUARDS"; git_access https://github.com/koorikla/x; echo REACHED' 2>&1 || true)
assert_eq "$([[ "$out" == *REACHED* ]] && echo reached || echo stopped):$([[ -e "$TMP/git-credential" ]] && echo helper || echo none)" \
  "stopped:none" "no git token: the run stops, no anonymous clone"
assert_eq "$out" ">> no GitHub token for https://github.com/koorikla/x: Secret run-1-git was not created.\
 The platform GitHub App must be installed on this repository with Contents: Read and write\
 (GitHub: Settings > Applications > the App > Configure > Repository access). Status:\
 kubectl -n workflows-default describe externalsecret run-1-git;\
 GitHub's answer (e.g. 422 not accessible to the installation): kubectl -n external-secrets logs\
 deploy/external-secrets | grep run-1-git" "no git token: exact message (Secret, App permission hint, ExternalSecret, ESO log)"
assert_matches "$out" <<'CASES'
no git token: says which Secret | no GitHub token for https://github.com/koorikla/x: Secret run-1-git was not created
no git token: says what to fix | GitHub App must be installed on this repository
no git token: points at the ExternalSecret | kubectl -n workflows-default describe externalsecret run-1-git
no git token: points at GitHub's answer (ESO log) | logs deploy/external-secrets \| grep run-1-git
CASES

# --- the templates call these scripts: data only, no code in the YAML (#393) -----------------------------------------
# Every step of koorikla-build and koorikla-helm-chart runs one versioned script from ci/scripts/workflow: the toolbox's
# copy (/opt/koorikla-ci/scripts), or in the toolchain and BuildKit images the /ci copy an init container makes. No
# `eval`, no inline `args:` script, no env var that holds code; the guards above are what runs.
pods='.spec.templates[] | (.container, .initContainers[]?, .sidecars[]?) | select(. != null)'
for t in koorikla-build koorikla-helm-chart; do
  assert_eq "$(cwt "$t" '... comments=""' | grep -cw 'eval' || true)" 0 "$t: no eval"
  # each lists the offenders (container / env var names): empty means none
  assert_eq "$(cwt "$t" "$pods | select(has(\"args\")) | .name // \"main\"")" "" "$t: no container carries an args script"
  assert_eq "$(cwt "$t" '.spec.templates[] | select(has("script")) | .name')" "" "$t: no Argo script template"
  assert_eq "$(cwt "$t" "$pods | .env[]? | select(.value | test(\"\\n\")) | .name")" "" "$t: no env var holds code"
done
assert_eq "$(grep -c 'BUILD_GUARDS' "$TMP/plane.yaml" || true)" 0 "no BUILD_GUARDS env left"
cmds() { cwt "$1" '.spec.templates[] | .name as $n | ((.initContainers[]? | $n + "/init " + (.command | join(" "))), (.container | select(. != null) | $n + " " + (.command | join(" "))))'; }
O=/opt/koorikla-ci/scripts/workflow
assert_eq "$(cmds koorikla-build)" "checkout bash $O/checkout.sh
check/init bash $O/check-init.sh
check bash /ci/scripts/workflow/check.sh
check-with-postgres/init bash $O/check-init.sh
check-with-postgres bash /ci/scripts/workflow/check.sh
scan-fs bash $O/scan-fs.sh
build/init cp -R /opt/koorikla-ci/scripts /ci/scripts
build sh /ci/scripts/workflow/build.sh
scan-image bash $O/scan-image.sh
sbom bash $O/sbom.sh
sign bash $O/sign.sh
gitops bash $O/gitops.sh" "koorikla-build: every step runs its ci/scripts/workflow script (build: POSIX sh)"
assert_eq "$(cmds koorikla-helm-chart)" "package bash $O/helm-package.sh
sign bash $O/sign.sh" "koorikla-helm-chart: package and sign run their scripts"
# each called script ships in the toolbox (ci/scripts is the toolbox's /opt/koorikla-ci/scripts and the /ci copy)
for s in $( (cmds koorikla-build; cmds koorikla-helm-chart) | grep -o '/[a-z/-]*/workflow/[a-z-]*\.sh' | sort -u); do
  assert_eq "$([[ -f "$ROOT/ci/scripts/workflow/${s##*/}" ]] && echo ships)" ships "$s ships as ci/scripts/workflow/${s##*/}"
done
for step in checkout gitops; do   # the guards' env: allowlist, Secret name and namespace for the operator messages
  assert_eq "$(cwt koorikla-build ".spec.templates[] | select(.name == \"$step\") | [.container.env[].name | select(test(\"^(GIT_ALLOWED_PREFIXES|GIT_SECRET|RUN_NAMESPACE|REPO)$\"))] | sort | join(\" \")")" \
    "GIT_ALLOWED_PREFIXES GIT_SECRET REPO RUN_NAMESPACE" "$step: guards.sh gets REPO, GIT_ALLOWED_PREFIXES, GIT_SECRET, RUN_NAMESPACE"
done

# --- gitops.sh: only a real Workload under deploy/openchoreo/ is rewritten, through the GitHub contents API (#34) -----
# Runs gitops.sh with a fake `git clone` (a copy of a fixture repository, symlinks kept) and a fake `curl` that records
# the request: one PUT to <api>/repos/<owner>/<repo>/contents/<workload> with the token only in a header file,
# compare-and-swap on the file's blob sha, a 409 re-reads and retries, any other status stops with the reason.
assert_eq "$(grep -c 'git push' "$WF/gitops.sh" || true)" 0 "gitops: no git push (the API commits as the App)"
assert_eq "$(grep -c 'GIT_AUTHOR' "$WF/gitops.sh" || true)" 0 "gitops: no git identity of its own"
# The step runs in the Linux toolbox (GNU coreutils); `realpath -e` does not exist on macOS/BSD. Off Linux, put a GNU
# realpath first on PATH (brew coreutils: grealpath) or skip these runtime checks.
WL_PATH=$PATH
if ! realpath -e / >/dev/null 2>&1; then
  if command -v grealpath >/dev/null 2>&1; then
    mkdir -p "$TMP/gnu"; ln -sf "$(command -v grealpath)" "$TMP/gnu/realpath"; WL_PATH="$TMP/gnu:$PATH"
  else
    WL_SKIP=1
  fi
fi
# symlink <target> <link>: a real symlink or nothing (rc 1). Git Bash's `ln -s` silently copies unless MSYS allows
# native links (developer mode or admin): try that, and never let a copy stand in for a link in the refusal checks.
symlink() {
  ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]] && return 0
  rm -rf "$2"
  MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]] && return 0
  rm -rf "$2"; return 1
}
# One probe: can this shell create a symlink and copy it as one (the fake clone's `cp -R`; the link may dangle while
# the copy runs)? Git Bash without Windows developer mode cannot: `ln -s` copies and `cp` fails on a link. Only the
# symlink-refusal cases need links; they SKIP there with a count (and FAIL on Linux/macOS, where they must run).
mkdir -p "$TMP/link-probe/a"
if symlink missing "$TMP/link-probe/a/l" && MSYS=winsymlinks:nativestrict cp -R "$TMP/link-probe/a" "$TMP/link-probe/b" 2>/dev/null &&
  [[ -L "$TMP/link-probe/b/l" ]]; then LINKS=1; else LINKS=""; fi
REAL_GIT=$(command -v git)
GX="$TMPP/gx"; GB="$TMP/gxbin"; mkdir -p "$GB"
cat > "$GB/git" <<'FAKE'
#!/bin/bash
if [ "$1" = clone ]; then MSYS=winsymlinks:nativestrict cp -R "$GITOPS_SRC" "${@: -1}"; exit 0; fi
exec "$REAL_GIT" "$@"
FAKE
# fake curl: record argv (one line per call), keep the body + auth header, answer with the next code of $CODES
cat > "$GB/curl" <<'FAKE'
#!/bin/bash
n=$(( $(cat "$CALLS" 2>/dev/null | wc -l) + 1 )); printf '%s\n' "$*" >> "$CALLS"
while [ $# -gt 1 ]; do
  case "$1" in -o) out=$2; shift ;; --data-binary) cp "${2#@}" "$CALLS.body$n" ;; -H) [[ "$2" == @* ]] && cp "${2#@}" "$CALLS.auth" ;; esac
  shift
done
code=$(printf '%s\n' $CODES | sed -n "${n}p")
case "$code" in
  20*) printf '{"commit":{"sha":"c0ffee","author":{"name":"koorikla-promotion-gate[bot]"}}}' > "$out" ;;
  *) printf '{"message":"Resource not accessible by integration"}' > "$out" ;;
esac
printf '%s' "$code"
FAKE
chmod +x "$GB/git" "$GB/curl"
gitops() {   # gitops <source repo> <codes> <image> [source commit] [workload path] -> RC, OUT; curl calls in $GX.calls
  rm -rf "$GX.calls"*; stage "$GX"
  if env -i PATH="$GB:$WL_PATH" HOME="$GX" TMPDIR="$GX" REAL_GIT="$REAL_GIT" GITOPS_SRC="$1" CALLS="$GX.calls" CODES="$2" \
      GIT_SECRET_DIR="$SEC" REPO=https://github.com/koorikla/hello-world.git GIT_ALLOWED_PREFIXES="https://github.com/koorikla/" \
      GITHUB_API_URL=https://api.github.com GITOPS_BRANCH=main WORKLOAD_PATH="${5:-deploy/openchoreo/workload.yaml}" \
      IMAGE="$3" COMMIT_SHA="${4:-bbb}" SHORT_SHA=bbb COMPONENT=hello PROJECT=demo NAMESPACE=default RUN=run-1 \
      bash "$GX/opt/scripts/workflow/gitops.sh" > "$GX.out" 2>&1; then RC=0; else RC=$?; fi
  OUT=$(cat "$GX.out")
}
in_repo=" in https://github.com/koorikla/hello-world.git@main"
fence_msg() { [[ "$1" == *"not found (or a symlink"* || "$1" == *"is not an OpenChoreo Workload"* || "$1" == *"resolves outside"* ]] && echo refused || echo passed; }
R="$TMP/repo"; mkdir -p "$R/deploy/openchoreo" "$R/.github/workflows"
printf 'apiVersion: openchoreo.dev/v1alpha1\nkind: Workload\nspec: {}\n' > "$R/deploy/openchoreo/workload.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$R/deploy/openchoreo/deploy.yaml"
printf 'kind: Workload\n' > "$R/.github/workflows/ci.yaml"
if [[ -n "${WL_SKIP:-}" ]]; then
  echo "  SKIP gitops Workload runtime checks: no GNU realpath (brew install coreutils); production runs them on Linux"
else
  gitops "$R" 201 new:1; assert_eq "$(fence_msg "$OUT")" passed "gitops: Workload accepted"
  gitops "$R" 201 new:1 bbb deploy/openchoreo/deploy.yaml
  assert_eq "$RC:$OUT" "1:>> deploy/openchoreo/deploy.yaml is not an OpenChoreo Workload" "gitops: another kind refused (exact message)"
  gitops "$R" 201 new:1 bbb deploy/openchoreo/missing.yaml
  assert_eq "$RC:$OUT" "1:>> deploy/openchoreo/missing.yaml not found (or a symlink on its path)$in_repo" "gitops: missing file refused"
  # Symlink fixtures are separate repositories, so the cases above never copy a link.
  if [[ -n "$LINKS" ]]; then
    RL="$TMP/repo-link"; cp -R "$R" "$RL"
    symlink ../../.github/workflows/ci.yaml "$RL/deploy/openchoreo/link.yaml" || LINKS=""
    R2="$TMP/repo2"; mkdir -p "$R2/deploy" "$R2/.github/workflows"
    printf 'kind: Workload\n' > "$R2/.github/workflows/ci.yaml"
    symlink ../.github/workflows "$R2/deploy/openchoreo" || LINKS=""
  fi
  if [[ -n "$LINKS" ]]; then
    gitops "$RL" 201 new:1 bbb deploy/openchoreo/link.yaml
    assert_eq "$RC:$OUT" "1:>> deploy/openchoreo/link.yaml not found (or a symlink on its path)$in_repo" "gitops: symlinked file refused"
    gitops "$R2" 201 new:1 bbb deploy/openchoreo/ci.yaml
    assert_eq "$RC:$OUT" "1:>> deploy/openchoreo/ci.yaml not found (or a symlink on its path)$in_repo" \
      "gitops: symlinked deploy/openchoreo directory refused (exact message)"
    assert_eq "$([[ -e "$GX.calls" ]] && echo called || echo none)" none "gitops: nothing sent for a refused Workload"
  elif [[ "$(os_name)" == windows ]]; then
    echo "  SKIP 3 gitops symlink-refusal assertions (symlinked Workload file, symlinked deploy/openchoreo, nothing sent):" \
      "this Git Bash cannot create and copy symlinks (enable Windows developer mode); Linux/macOS CI runs them"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: cannot create and copy symlinks on $(uname -s): the gitops symlink refusals must run here" >&2
  fi
fi
# The API path needs the Linux toolbox tools (GNU base64 -w0, realpath -e, LF-only jq output); skipped where they are
# missing and on Windows (Git Bash's jq prints CRLF; the Linux and arm CI jobs run these checks).
if base64 -w0 </dev/null >/dev/null 2>&1 && [[ -z "${WL_SKIP:-}" && "$(os_name)" != windows ]]; then
  SRC="$TMP/gxsrc"; mkdir -p "$SRC/deploy/openchoreo"
  printf 'apiVersion: openchoreo.dev/v1alpha1\nkind: Workload\nspec:\n  container:\n    image: old\n  source:\n    commit: aaa\n' \
    > "$SRC/deploy/openchoreo/workload.yaml"
  (cd "$SRC" && "$REAL_GIT" init -q -b main . && "$REAL_GIT" add -A && \
    "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)
  BLOB=$(cd "$SRC" && "$REAL_GIT" rev-parse HEAD:deploy/openchoreo/workload.yaml)
  gitops "$SRC" "201" new:1
  assert_eq "$RC" 0 "gitops API: committed"
  assert_match "$OUT" 'committed c0ffee to koorikla/hello-world@main as koorikla-promotion-gate\[bot\]' "gitops API: reports the bot commit"
  assert_eq "$(wc -l < "$GX.calls" | tr -d ' ')" 1 "gitops API: one request"
  call=$(cat "$GX.calls")
  assert_match "$call" '-X PUT' "gitops API: PUT"
  assert_match "$call" '--proto =https' "gitops API: https only"
  assert_match "$call" 'https://api.github.com/repos/koorikla/hello-world/contents/deploy/openchoreo/workload.yaml$' \
    "gitops API: the run's repository (.git removed) and the Workload path"
  assert_eq "$([[ "$call" == *TOKEN-FAKE-123* ]] && echo argv || echo header-file)" header-file "gitops API: token not in argv"
  assert_eq "$(cat "$GX.calls.auth")" "Authorization: Bearer TOKEN-FAKE-123" "gitops API: token in the auth header file"
  assert_eq "$(jq -r '[.branch, .sha] | join(" ")' "$GX.calls.body1")" "main $BLOB" "gitops API: branch + compare-and-swap blob sha"
  assert_eq "$(jq -r .message "$GX.calls.body1")" "chore(deploy): hello image bbb [skip ci]

OpenChoreo WorkflowRun run-1 (default/demo/hello): new:1" "gitops API: commit message, word for word"
  body=$(jq -r .content "$GX.calls.body1" | base64 -d)
  assert_eq "$(printf '%s\n' "$body" | yq -r '.spec.container.image + " " + .spec.source.commit')" "new:1 bbb" "gitops API: new image + source commit"
  gitops "$SRC" "409 201" new:1
  assert_eq "$RC:$(wc -l < "$GX.calls" | tr -d ' ')" "0:2" "gitops API: 409 (branch moved) re-reads and retries"
  assert_match "$OUT" '>> main moved, re-reading \(attempt 1\)' "gitops API: says the branch moved"
  gitops "$SRC" "403" new:1
  assert_eq "$RC" 1 "gitops API: 403 fails the run"
  assert_eq "$OUT" ">> GitHub contents API (koorikla/hello-world deploy/openchoreo/workload.yaml): HTTP 403 Resource not accessible\
 by integration. The platform GitHub App needs Contents: Read and write on koorikla/hello-world, and a bypass if main is\
 protected" "gitops API: GitHub's answer and the App permission hint, word for word"
  gitops "$SRC" "201" old aaa
  assert_eq "$RC:$([[ -e "$GX.calls" ]] && echo called || echo none)" "0:none" "gitops API: unchanged Workload, no commit"
  assert_match "$OUT" '>> deploy/openchoreo/workload.yaml already at old' "gitops API: says it is already there"
else
  echo "  SKIP gitops API runtime checks: Linux toolbox tools only (GNU base64/realpath, LF jq output)"
fi

# --- sign.sh: no public Rekor upload unless the installation opts in ------------------------------------------------
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho "cosign $*"\necho "password: ${COSIGN_PASSWORD:-none}"\n' > "$FAKE/cosign"; chmod +x "$FAKE/cosign"
SG="$TMPP/sign"
sign() {   # sign <tlog-upload> [VAR=value...]: sign.sh with the real sign-image.sh and a fake cosign -> RC, OUT (cosign lines)
  local tlog=$1; shift
  stage "$SG"; mkdir -p "$SG/cosign" "$SG/work/out"
  printf 'fixture-pass' > "$SG/cosign/cosign.password"; printf '{}' > "$SG/work/out/trivy-vuln.json"
  if (cd "$SG" && env -i PATH="$FAKE:/usr/bin:/bin" HOME="$SG/tmp" TLOG_UPLOAD="$tlog" DIGEST_REF=r@sha256:1 COSIGN_KEY=k "$@" \
      bash "$SG/opt/scripts/workflow/sign.sh") > "$SG.out" 2>&1; then RC=0; else RC=$?; fi
  OUT=$(grep -E '^(cosign|password)' "$SG.out" || true)
}
CFG="--signing-config $SG/tmp/signing-config.json"
sign false VULN_PREDICATE="$SG/work/out/trivy-vuln.json" SBOM_PREDICATE="$SG/work/out/sbom.spdx.json"
assert_eq "$RC" 0 "koorikla-build sign: runs"
assert_eq "$(grep '^cosign' <<<"$OUT")" "cosign sign $CFG --yes --key k --recursive r@sha256:1
cosign attest $CFG --yes --key k --type vuln --predicate $SG/work/out/trivy-vuln.json r@sha256:1
cosign attest $CFG --yes --key k --type https://spdx.dev/Document/v2.3 --predicate $SG/work/out/sbom.spdx.json r@sha256:1" \
  "koorikla-build sign: index + platforms signed, vuln + SPDX 2.3 SBOM attested, all with the tlog-free signing config"
assert_eq "$(grep -c '^password: fixture-pass$' <<<"$OUT")" 3 "sign: COSIGN_PASSWORD from the cosign Secret"
assert_eq "$(yq -p json -o json -I0 '.' "$SG/tmp/signing-config.json")" \
  '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}' "signing config has no Rekor/TSA/Fulcio service"
out=$(PATH="$FAKE:/usr/bin:/bin" "$SG/tmp/bin/cosign" verify r)
assert_eq "${out%%$'\n'*}" "cosign verify r" "the cosign shim leaves other subcommands untouched"
sign false RECURSIVE=false
assert_eq "$RC:$(grep '^cosign' <<<"$OUT")" "0:cosign sign $CFG --yes --key k r@sha256:1" \
  "koorikla-helm-chart sign: the chart digest only, tlog-free signing config, no attestations"
sign true VULN_PREDICATE="$SG/work/out/trivy-vuln.json"
assert_eq "$RC:$(grep '^cosign' <<<"$OUT")" "0:cosign sign --yes --key k --recursive r@sha256:1
cosign attest --yes --key k --type vuln --predicate $SG/work/out/trivy-vuln.json r@sha256:1" "transparencyLog true: plain cosign (public Rekor)"
for t in koorikla-build koorikla-helm-chart; do
  assert_eq "$(cwt "$t" '.spec.arguments.parameters[] | select(.name == "tlog-upload") | .value')" false "$t: tlog-upload defaults to false"
done

# --- every step script parses (bash -n; build.sh is POSIX sh for the BuildKit image) -------------------------------
for f in "$WF"/*.sh; do
  sh_bin="bash"; [[ "$f" == */build.sh ]] && sh_bin="sh"
  assert_eq "$("$sh_bin" -n "$f" 2>&1 && echo ok)" ok "${f#"$ROOT"/} parses ($sh_bin -n)"
done

# --- ServiceAccount token only for Argo's executor ----------------------------------------------------------------
for t in koorikla-build koorikla-helm-chart; do
  assert_eq "$(cwt "$t" '.spec.automountServiceAccountToken')" false "$t: no SA token in run pods"
  assert_eq "$(cwt "$t" '.spec.executor.serviceAccountName')" workflow-sa "$t: executor (init/wait) uses workflow-sa"
done
for wf in go helm-chart; do
  assert_eq "$(cw "$wf" '.spec.runTemplate.spec.automountServiceAccountToken')" false "$wf runTemplate: no SA token in run pods"
  assert_eq "$(cw "$wf" '.spec.runTemplate.spec.executor.serviceAccountName')" workflow-sa "$wf runTemplate: executor SA"
done

finish
