#!/usr/bin/env bash
# In-cluster build guards (addons openchoreo-platform + openchoreo-workflow-plane), negative tests first:
#   - the ClusterWorkflow schema patterns reject foreign hosts/owners, traversal and option injection
#   - BUILD_GUARDS (koorikla-build checkout/gitops) refuses foreign repositories and hands the git token only to the
#     allowed prefixes (real `git credential fill`), https only
#   - gitops rewrites only a real OpenChoreo Workload under deploy/openchoreo/ (no symlink out, no other kind)
#   - signing skips the public Rekor log unless the installation opts in (cosign v3 signing config)
#   - run pods get no ServiceAccount token (only Argo's executor containers do)
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

# --- BUILD_GUARDS: repository allowlist and scoped credentials ----------------------------------------------------
GUARDS=$(cwt koorikla-build '.spec.templates[] | select(.name == "gitops") | .container.env[] | select(.name == "BUILD_GUARDS") | .value')
assert_nonempty "$GUARDS" "BUILD_GUARDS present in gitops"
assert_eq "$(cwt koorikla-build '.spec.templates[] | select(.name == "checkout") | .container.env[] | select(.name == "BUILD_GUARDS") | .value')" \
  "$GUARDS" "checkout and gitops share one BUILD_GUARDS"
for step in checkout gitops; do
  sc=$(cwt koorikla-build ".spec.templates[] | select(.name == \"$step\") | .container.args[0]")
  assert_match "$sc" 'eval "\$BUILD_GUARDS"' "$step evaluates BUILD_GUARDS"
  assert_match "$sc" 'git_access "\$REPO"' "$step calls git_access before any git command"
done
assert_eq "$(grep -c 'GIT_ASKPASS=' "$TMP/plane.yaml" || true)" 0 "no global GIT_ASKPASS anywhere"

SEC="$TMP/git-secret"; mkdir -p "$SEC"; printf 'builder' > "$SEC/username"; printf 'TOKEN-FAKE-123' > "$SEC/password"
# guard <cmd>: run cmd after BUILD_GUARDS in a clean environment (no user gitconfig); OUT = stdout+stderr, RC = rc
guard() {
  if env -i PATH="$PATH" HOME="$TMP/home" TMPDIR="$TMP" GIT_SECRET_DIR="$SEC" \
      GIT_ALLOWED_PREFIXES="https://github.com/koorikla/ https://git.example.com/team/" \
      GUARDS="$GUARDS" bash -c 'set -euo pipefail; eval "$GUARDS"; '"$1" > "$TMP/guard.out" 2>&1; then RC=0; else RC=$?; fi
  OUT=$(cat "$TMP/guard.out")
}
mkdir -p "$TMP/home"
fill() { printf 'git_access %q; printf "url=%%s\\n\\n" %q | git credential fill 2>&1 || true' "$1" "$2"; }

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
guard 'GIT_ALLOWED_PREFIXES=""; git_access https://github.com/koorikla/x; echo REACHED'; out=$OUT
assert_eq "$RC" 1 "empty allowlist refuses everything"
for ref in --upload-pack=touch -b "a b"; do
  guard "check_ref $(printf %q "$ref")"
  assert_eq "$RC" 1 "check_ref refuses '$ref'"
done
guard 'check_ref main; check_ref ""; check_ref 0123abc'
assert_eq "$RC" 0 "check_ref accepts main, empty, a sha"
for wl in .github/workflows/ci.yaml deploy/openchoreo/../../x.yaml deploy/openchoreo/a/b.yaml; do
  guard "check_workload_path $(printf %q "$wl")"
  assert_eq "$RC" 1 "check_workload_path refuses '$wl'"
done
guard 'check_workload_path deploy/openchoreo/workload.yaml'
assert_eq "$RC" 0 "check_workload_path accepts deploy/openchoreo/workload.yaml"
# https only: file:// (and every other transport) is off even for a URL that slipped through
git init -q --bare "$TMP/bare.git"
guard "git_access https://github.com/koorikla/x; git ls-remote file://$TMP/bare.git && echo LISTED"; out=$OUT
assert_eq "$([[ "$out" == *LISTED* ]] && echo listed || echo blocked)" blocked "protocol.allow never: file:// blocked"
guard 'git_access https://github.com/koorikla/x; env | grep -c "^GIT_ASKPASS=" || true'; out=$OUT
assert_eq "$out" 0 "git_access leaves no GIT_ASKPASS"
# No token (the platform GitHub App is not installed on the repository, so ESO's generator never wrote <run>-git): the
# run stops with the reason instead of an anonymous clone and a failing push at the end (#34).
rm -f "$TMP/git-credential"
out=$(env -i PATH="$PATH" HOME="$TMP/home" TMPDIR="$TMP" GIT_SECRET_DIR="$TMP/none" GIT_SECRET_WAIT=0 GIT_SECRET=run-1-git \
  RUN_NAMESPACE=workflows-default GIT_ALLOWED_PREFIXES="https://github.com/koorikla/" \
  GUARDS="$GUARDS" bash -c 'set -euo pipefail; eval "$GUARDS"; git_access https://github.com/koorikla/x; echo REACHED' 2>&1 || true)
assert_eq "$([[ "$out" == *REACHED* ]] && echo reached || echo stopped):$([[ -e "$TMP/git-credential" ]] && echo helper || echo none)" \
  "stopped:none" "no git token: the run stops, no anonymous clone"
assert_match "$out" 'no GitHub token for https://github.com/koorikla/x: Secret run-1-git was not created' "no git token: says which Secret"
assert_match "$out" 'GitHub App must be installed on this repository' "no git token: says what to fix"
assert_match "$out" 'kubectl -n workflows-default describe externalsecret run-1-git' "no git token: points at the ExternalSecret"
assert_match "$out" 'logs deploy/external-secrets \| grep run-1-git' "no git token: points at GitHub's answer (ESO log)"

# --- gitops: only a real Workload under deploy/openchoreo/ is rewritten -------------------------------------------
GITOPS=$(cwt koorikla-build '.spec.templates[] | select(.name == "gitops") | .container.args[0]')
CHECK=$(printf '%s\n' "$GITOPS" | awk '/Only an OpenChoreo Workload/{f=1} f{print} /is not an OpenChoreo Workload/{exit}')
assert_match "$CHECK" 'realpath -e' "gitops workload check extracted"
# The gitops step runs in the Linux toolbox (GNU coreutils); `realpath -e` does not exist on macOS/BSD. Off Linux,
# put a GNU realpath first on PATH (brew coreutils: grealpath) or skip these runtime checks.
WL_PATH=$PATH
if ! realpath -e / >/dev/null 2>&1; then
  if command -v grealpath >/dev/null 2>&1; then
    mkdir -p "$TMP/gnu"; ln -sf "$(command -v grealpath)" "$TMP/gnu/realpath"; WL_PATH="$TMP/gnu:$PATH"
  else
    WL_SKIP=1
  fi
fi
wl_check() {   # wl_check <repo dir> <path> -> RC
  if (cd "$1" && env -i PATH="$WL_PATH" WORKLOAD_PATH="$2" REPO=r GITOPS_BRANCH=b CHECK="$CHECK" GUARDS="$GUARDS" \
      bash -c 'set -euo pipefail; eval "$GUARDS"; eval "$CHECK"' >/dev/null 2>&1); then RC=0; else RC=$?; fi
}
# symlink <target> <link>: a real symlink or nothing (rc 1). Git Bash's `ln -s` silently copies unless MSYS allows
# native links (developer mode or admin): try that, and never let a copy stand in for a link in the refusal checks.
symlink() {
  ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]] && return 0
  rm -rf "$2"
  MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]] && return 0
  rm -rf "$2"; return 1
}
R="$TMP/repo"; mkdir -p "$R/deploy/openchoreo" "$R/.github/workflows"
printf 'apiVersion: openchoreo.dev/v1alpha1\nkind: Workload\nspec: {}\n' > "$R/deploy/openchoreo/workload.yaml"
printf 'apiVersion: apps/v1\nkind: Deployment\n' > "$R/deploy/openchoreo/deploy.yaml"
printf 'kind: Workload\n' > "$R/.github/workflows/ci.yaml"
symlink ../../.github/workflows/ci.yaml "$R/deploy/openchoreo/link.yaml" && LINKS=1 || LINKS=""
if [[ -n "${WL_SKIP:-}" ]]; then
  echo "  SKIP gitops Workload runtime checks: no GNU realpath (brew install coreutils); production runs them on Linux"
else
  wl_check "$R" deploy/openchoreo/workload.yaml; assert_eq "$RC" 0 "gitops: Workload accepted"
  wl_check "$R" deploy/openchoreo/deploy.yaml; assert_eq "$RC" 1 "gitops: another kind refused"
  wl_check "$R" deploy/openchoreo/missing.yaml; assert_eq "$RC" 1 "gitops: missing file refused"
  if [[ -n "$LINKS" ]]; then
    wl_check "$R" deploy/openchoreo/link.yaml; assert_eq "$RC" 1 "gitops: symlinked file refused"
  fi
fi
R2="$TMP/repo2"; mkdir -p "$R2/deploy" "$R2/.github/workflows"
printf 'kind: Workload\n' > "$R2/.github/workflows/ci.yaml"
if symlink ../.github/workflows "$R2/deploy/openchoreo"; then
  wl_check "$R2" deploy/openchoreo/ci.yaml; assert_eq "$RC" 1 "gitops: symlinked deploy/openchoreo directory refused"
else
  LINKS=""
fi
if [[ -z "$LINKS" ]]; then
  [[ "$(os_name)" == windows ]] \
    || { FAIL=$((FAIL + 1)); echo "  FAIL: cannot create symlinks on $(uname -s): the symlink refusals must run here" >&2; }
  echo "  SKIP gitops symlink refusals: this Git Bash cannot create symlinks (enable Windows developer mode); Linux/macOS CI runs them"
fi

# --- build: context and Dockerfile must stay inside the checkout ---------------------------------------------------
BUILD=$(cwt koorikla-build '.spec.templates[] | select(.name == "build") | .container.args[0]')
assert_match "$BUILD" 'resolves outside the repository' "build refuses a context outside /work/source"

# --- signing: no public Rekor upload unless the installation opts in ----------------------------------------------
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho "cosign $*"\n' > "$FAKE/cosign"; chmod +x "$FAKE/cosign"
for t in koorikla-build koorikla-helm-chart; do
  SIGN=$(cwt "$t" '.spec.templates[] | select(.name == "sign") | .container.args[0]')
  SHIM=$(printf '%s\n' "$SIGN" | awk '/if \[ "\$TLOG_UPLOAD" != true \]/{f=1} f{print} f && /^fi$/{exit}')
  assert_match "$SHIM" 'signing-config' "$t: sign has the transparency-log switch"
  assert_eq "$(cwt "$t" '.spec.arguments.parameters[] | select(.name == "tlog-upload") | .value')" false "$t: tlog-upload defaults to false"
  rm -rf "${TMP:?}/bin" "${TMP:?}/signing-config.json"
  out=$(cd "$TMP" && env -i PATH="$FAKE:/usr/bin:/bin" TLOG_UPLOAD=false SHIM="${SHIM//\/tmp\//$TMP/}" \
    bash -c 'set -euo pipefail; eval "$SHIM"; cosign sign --yes --key k r@sha256:1; cosign attest --yes --type vuln r@sha256:1; cosign verify r' 2>&1)
  assert_match "$out" "cosign sign --signing-config $TMP/signing-config.json --yes --key k" "$t: sign gets the tlog-free signing config"
  assert_match "$out" "cosign attest --signing-config $TMP/signing-config.json --yes --type vuln" "$t: attest gets it too"
  assert_match "$out" "cosign verify r" "$t: other subcommands untouched"
  assert_eq "$(yq -p json -o json -I0 '.' "$TMP/signing-config.json")" \
    '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","rekorTlogConfig":{},"tsaConfig":{}}' "$t: signing config has no Rekor/TSA/Fulcio service"
  out=$(cd "$TMP" && env -i PATH="$FAKE:/usr/bin:/bin" TLOG_UPLOAD=true SHIM="${SHIM//\/tmp\//$TMP/}" \
    bash -c 'set -euo pipefail; eval "$SHIM"; cosign sign --yes --key k r@sha256:1' 2>&1)
  assert_eq "$out" "cosign sign --yes --key k r@sha256:1" "$t: transparencyLog true: plain cosign (public Rekor)"
done

# --- every rendered step script parses (bash -n; build runs sh in the BuildKit image) ------------------------------
for t in koorikla-build koorikla-helm-chart; do
  for step in $(cwt "$t" '.spec.templates[] | select(.container.args) | .name'); do
    cwt "$t" ".spec.templates[] | select(.name == \"$step\") | .container.args[0]" > "$TMP/step.sh"
    sh_bin="bash"; [[ "$step" == build ]] && sh_bin="sh"
    assert_eq "$("$sh_bin" -n "$TMP/step.sh" 2>&1 && echo ok)" ok "$t/$step script parses ($sh_bin -n)"
  done
done
bash -n <(printf '%s\n' "$GUARDS") && assert_eq ok ok "BUILD_GUARDS parses"

# --- gitops: the commit goes through the GitHub contents API as the App (#34) ---------------------------------------
# Runs the rendered gitops script with a fake `git clone` (a local copy) and a fake `curl` that records the request:
# one PUT to <api>/repos/<owner>/<repo>/contents/<workload> with the token only in a header file, compare-and-swap on
# the file's blob sha, a 409 re-reads and retries, any other status stops with the reason. Linux toolbox tools
# (GNU base64 -w0, realpath -e, LF-only jq output); skipped where they are missing and on Windows (Git Bash's jq
# prints CRLF; the step only ever runs in the Linux toolbox, the Linux and arm CI jobs run these checks).
GITOPS_SCRIPT=$(cwt koorikla-build '.spec.templates[] | select(.name == "gitops") | .container.args[0]')
assert_eq "$(printf '%s\n' "$GITOPS_SCRIPT" | grep -c 'git push' || true)" 0 "gitops: no git push (the API commits as the App)"
assert_eq "$(printf '%s\n' "$GITOPS_SCRIPT" | grep -c 'GIT_AUTHOR' || true)" 0 "gitops: no git identity of its own"
if base64 -w0 </dev/null >/dev/null 2>&1 && [[ -z "${WL_SKIP:-}" && "$(os_name)" != windows ]]; then
  REAL_GIT=$(command -v git)
  GX="$TMP/gx"; GB="$TMP/gxbin"; SRC="$TMP/gxsrc"; mkdir -p "$GB"
  rm -rf "$SRC"; mkdir -p "$SRC/deploy/openchoreo"
  printf 'apiVersion: openchoreo.dev/v1alpha1\nkind: Workload\nspec:\n  container:\n    image: old\n  source:\n    commit: aaa\n' \
    > "$SRC/deploy/openchoreo/workload.yaml"
  (cd "$SRC" && "$REAL_GIT" init -q -b main . && "$REAL_GIT" add -A && \
    "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)
  BLOB=$(cd "$SRC" && "$REAL_GIT" rev-parse HEAD:deploy/openchoreo/workload.yaml)
  printf '#!/bin/bash\nif [ "$1" = clone ]; then cp -R "%s" "${@: -1}"; exit 0; fi\nexec "%s" "$@"\n' "$SRC" "$REAL_GIT" > "$GB/git"
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
  gitops() {   # gitops <codes> <image> [source commit] -> RC, OUT; calls in $GX.calls
    rm -rf "$GX" "$GX.calls"*; mkdir -p "$GX"
    if env -i PATH="$GB:$WL_PATH" HOME="$GX" TMPDIR="$GX" CALLS="$GX.calls" CODES="$1" GIT_SECRET_DIR="$SEC" \
        REPO=https://github.com/koorikla/hello-world.git GIT_ALLOWED_PREFIXES="https://github.com/koorikla/" \
        GITHUB_API_URL=https://api.github.com GITOPS_BRANCH=main WORKLOAD_PATH=deploy/openchoreo/workload.yaml \
        IMAGE="$2" COMMIT_SHA="${3:-bbb}" SHORT_SHA=bbb COMPONENT=hello PROJECT=demo NAMESPACE=default RUN=run-1 \
        GUARDS="$GUARDS" S="${GITOPS_SCRIPT//\/tmp/$GX}" \
        bash -c 'set -euo pipefail; BUILD_GUARDS=$GUARDS; eval "$S"' > "$GX.out" 2>&1; then RC=0; else RC=$?; fi
    OUT=$(cat "$GX.out")
  }
  gitops "201" new:1
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
  assert_match "$(jq -r .message "$GX.calls.body1")" '^chore\(deploy\): hello image bbb \[skip ci\]' "gitops API: commit message"
  body=$(jq -r .content "$GX.calls.body1" | base64 -d)
  assert_eq "$(printf '%s\n' "$body" | yq -r '.spec.container.image + " " + .spec.source.commit')" "new:1 bbb" "gitops API: new image + source commit"
  gitops "409 201" new:1
  assert_eq "$RC:$(wc -l < "$GX.calls" | tr -d ' ')" "0:2" "gitops API: 409 (branch moved) re-reads and retries"
  gitops "403" new:1
  assert_eq "$RC" 1 "gitops API: 403 fails the run"
  assert_match "$OUT" 'HTTP 403 Resource not accessible by integration' "gitops API: shows GitHub's answer"
  assert_match "$OUT" 'needs Contents: Read and write on koorikla/hello-world' "gitops API: says what to fix"
  gitops "201" old aaa
  assert_eq "$RC:$([[ -e "$GX.calls" ]] && echo called || echo none)" "0:none" "gitops API: unchanged Workload, no commit"
else
  echo "  SKIP gitops API runtime checks: Linux toolbox tools only (GNU base64/realpath, LF jq output)"
fi

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
