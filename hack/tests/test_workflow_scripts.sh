#!/usr/bin/env bash
# Workflow scripts (stdlib Python run by Argo Workflows): unit tests of their pure functions and template guards.
#   addons/openchoreo-platform/files/promotion-gate/gate.py  freeze windows incl. DST, releaseName edit, endpoints, pipeline
#   addons/argo-events/files/falco_response.py               priority filter, pod -> OpenChoreo component mapping
#   addons/openchoreo-platform/files/auto-build/auto_build.py one WorkflowRun per commit, GitOps hand-off not rebuilt,
#                                                             restarts/lost cache/redelivery never build twice (#164)
#   addons/argo-events WorkflowTemplate falco-response        the Falco event (tenant-controlled text) and what enrich
#                                                             derives from it reach steps only as env, never as code
#   ci/scripts/workflow (koorikla-build steps)                 checkout loop guard, check-env never run as code, build-arg
#                                                             parsing + context fence, the env of the scan/sbom/helm wrappers
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

# --- koorikla-build step scripts (ci/scripts/workflow): checkout, check, build, scan/sbom, helm package ---------------
# Run directly with the pod's mounts staged under a temp root; guards.sh, gitops.sh and sign.sh: test_build_guards.sh.
WF="$ROOT/ci/scripts/workflow"
TMPP=$(cd "$TMP" && pwd -P)   # physical path: build.sh compares realpath results against its pod paths
# stage <root>: copy ci/scripts/workflow to <root>/opt/scripts (the toolbox's copy), next to stubs of the scripts it
# calls, with its pod paths (/work/, /tmp/, /ci/, /registry-ca/, /etc/, ...) pointing under <root>. Paths without a
# trailing `/` (DOCKER_CONFIG=/registry-auth) stay as they are. The stubs print the env they were called with.
stage() {
  local root=$1 f
  rm -rf "$root"; mkdir -p "$root/opt/scripts/workflow" "$root/opt/scripts/common" "$root/opt/scripts/helm" "$root/tmp" \
    "$root/work/source" "$root/etc/ssl/certs" "$root/registry-auth" "$root/home"
  for f in "$WF"/*.sh; do
    sed -E "s#/(work|tmp|ci|registry-auth|registry-ca|cosign|buildkitd|etc)/#$root/\1/#g" "$f" > "$root/opt/scripts/workflow/${f##*/}"
  done
  for f in common/scan-fs.sh common/scan-image.sh common/sbom.sh helm/check.sh helm/package-push.sh; do
    printf '#!/bin/sh\necho "%s"\nenv | grep -E "^(SCAN_PATH|IGNORE_FILE|IMAGE_REF|IMAGE_SRC|SOURCE|PLATFORM|SSL_CERT_FILE|DOCKER_CONFIG|CHART_PATH|HELM_REGISTRY_CONFIG)=" | sort\n' \
      "$f" > "$root/opt/scripts/$f"
    chmod +x "$root/opt/scripts/$f"
  done
  printf 'system roots\n' > "$root/etc/ssl/certs/ca-certificates.crt"
  printf '{}' > "$root/registry-auth/config.json"
}

# checkout.sh: the fetch and the loop guard (a commit that only touches the GitOps directory is not rebuilt). A fake git
# points origin at a local fixture repository (file://, allowed for this fetch only: guards.sh allows https only).
# Git Bash: Windows git and file:// fixture paths do not mix; the step only ever runs in the Linux toolbox.
if [[ "$(os_name)" == windows ]]; then
  echo "  SKIP 7 checkout assertions on Windows (Windows git + file:// fixture; the step runs in the Linux toolbox, Linux/macOS run them)"
else
  REAL_GIT=$(command -v git)
  UP="$TMP/upstream"; mkdir -p "$UP/deploy/openchoreo"
  ugit() { "$REAL_GIT" -C "$UP" -c user.name=t -c user.email=t@t "$@"; }
  printf 'v1\n' > "$UP/main.go"; printf 'kind: Workload\n' > "$UP/deploy/openchoreo/workload.yaml"
  ugit init -q -b main; ugit add -A; ugit commit -q -m init; ugit branch root
  printf 'v2\n' > "$UP/main.go"; ugit commit -q -am "app change"; APP_SHA=$(ugit rev-parse HEAD)
  ugit checkout -q -b mixed; printf 'v3\n' > "$UP/main.go"; printf 'kind: Workload # 3\n' > "$UP/deploy/openchoreo/workload.yaml"
  ugit commit -q -am "app + workload"; ugit checkout -q main
  printf 'kind: Workload # 2\n' > "$UP/deploy/openchoreo/workload.yaml"; ugit commit -q -am "chore(deploy): hand-off"
  HANDOFF_SHA=$(ugit rev-parse HEAD)
  CB="$TMP/cobin"; mkdir -p "$CB"
  cat > "$CB/git" <<'FAKE'
#!/bin/bash
case "$1" in
  remote) [ "$2" = add ] && set -- remote add "$3" "file://$UPSTREAM" ;;
  fetch) set -- -c protocol.file.allow=always "$@" ;;
esac
exec "$REAL_GIT" "$@"
FAKE
  chmod +x "$CB/git"
  SEC="$TMP/git-secret"; mkdir -p "$SEC"; printf 'builder' > "$SEC/username"; printf 'fixture-token' > "$SEC/password"
  CO="$TMPP/co"
  checkout() {   # checkout <branch> [commit] -> RC, OUT; outputs under $CO/tmp
    stage "$CO"
    if env -i PATH="$CB:$PATH" HOME="$CO/tmp" TMPDIR="$CO" REAL_GIT="$REAL_GIT" UPSTREAM="$UP" GIT_SECRET_DIR="$SEC" \
        REPO=https://github.com/koorikla/hello-world.git GIT_ALLOWED_PREFIXES="https://github.com/koorikla/" BRANCH="$1" \
        COMMIT="${2:-}" WORKLOAD_PATH=deploy/openchoreo/workload.yaml bash "$CO/opt/scripts/workflow/checkout.sh" > "$CO.out" 2>&1
    then RC=0; else RC=$?; fi
    OUT=$(cat "$CO.out")
  }
  outputs() { printf '%s %s %s' "$(cat "$CO/tmp/commit-sha")" "$(cat "$CO/tmp/short-sha")" "$(cat "$CO/tmp/skip")"; }
  checkout main
  assert_eq "$RC:$(outputs)" "0:$HANDOFF_SHA ${HANDOFF_SHA:0:7} true" "checkout: a GitOps-only commit is not rebuilt (skip=true)"
  assert_match "$OUT" ">> $HANDOFF_SHA only changes deploy/openchoreo/ \(GitOps hand-off or promotion\): nothing to build" \
    "checkout: says why it skips"
  checkout main "$APP_SHA"
  assert_eq "$RC:$(outputs)" "0:$APP_SHA ${APP_SHA:0:7} false" "checkout: the requested commit, an app change is built"
  assert_eq "$(cat "$CO/work/source/main.go")" v2 "checkout: /work/source holds that commit"
  checkout mixed
  assert_eq "$RC:$(cat "$CO/tmp/skip")" "0:false" "checkout: app + GitOps change is built"
  checkout root
  assert_eq "$RC:$(cat "$CO/tmp/skip")" "0:false" "checkout: a first commit (no parent in the shallow fetch) is built"
  checkout --upload-pack=touch
  assert_eq "$RC:$OUT:$([[ -d "$CO/work/source/.git" ]] && echo fetched || echo none)" "1:>> invalid git ref '--upload-pack=touch':none" \
    "checkout: an option-like ref is refused before any git command"
fi

# check-init.sh + check.sh: check-env (tenant-set JSON) reaches the stack check as plain env values, never as code. Linux
# toolbox jq (Git Bash's jq prints CRLF into env.sh; the step only ever runs in the Linux toolbox).
if [[ "$(os_name)" != windows ]]; then
  CK="$TMPP/ck"; stage "$CK"; mkdir -p "$CK/ci" "$CK/work/source/app" "$CK/opt/scripts/teststack"
  # shellcheck disable=SC2016  # the fake stack check expands at run time
  printf '#!/bin/bash\necho "pwd=$(pwd) WORKDIR=$WORKDIR"\necho "FLAG=$FLAG|EVIL=$EVIL|N=$N|Q=$Q"\n' > "$CK/opt/scripts/teststack/check.sh"
  # shellcheck disable=SC2016  # literal $(...): it must never run
  check_env='{"FLAG":"x y","EVIL":"$(touch '"$CK"'/pwned)","N":3,"Q":"it'"'"'s"}'
  if env -i PATH="$PATH" CI_SCRIPTS="$CK/opt/scripts" CHECK_ENV="$check_env" bash "$CK/opt/scripts/workflow/check-init.sh" \
      > "$CK.out" 2>&1; then RC=0; else RC=$?; fi
  assert_eq "$RC:$([[ -f "$CK/ci/scripts/workflow/check.sh" && -f "$CK/ci/scripts/teststack/check.sh" ]] && echo copied)" "0:copied" \
    "check-init: copies ci/scripts to /ci/scripts"
  # shellcheck disable=SC2016  # check-setup expands in the step
  capture env -i PATH="$PATH" STACK=teststack APP_PATH=./app CHECK_SETUP='echo setup-ran > "$WORKDIR/setup"' \
    bash "$CK/ci/scripts/workflow/check.sh"
  assert_eq "$RC" 0 "check: runs ci/scripts/<stack>/check.sh"
  assert_match "$OUT" "pwd=$CK/work/source/app WORKDIR=$CK/work/source/app" "check: in /work/source/<app-path>, WORKDIR exported"
  assert_match "$OUT" "FLAG=x y\|EVIL=\\\$\(touch $CK/pwned\)\|N=3\|Q=it's" "check: check-env values arrive literally"
  assert_eq "$([[ -e "$CK/pwned" ]] && echo ran || echo literal)" literal "check: a check-env value is never run as code"
  assert_eq "$(cat "$CK/work/source/app/setup" 2>/dev/null)" setup-ran "check: check-setup runs first, in WORKDIR"
else
  echo "  SKIP 6 check-init/check assertions on Windows (Git Bash jq writes CRLF into env.sh; Linux/macOS run them)"
fi

# build.sh (POSIX sh in the BuildKit image): build-arg JSON parsing without jq, the context fence, digest outputs. A fake
# buildctl-daemonless.sh records its arguments, one per line, and answers with build metadata.
BB="$TMP/bkbin"; mkdir -p "$BB"
cat > "$BB/buildctl-daemonless.sh" <<'FAKE'
#!/bin/sh
printf '%s\n' "$@" > "$BUILD_CALL"
while [ $# -gt 0 ]; do [ "$1" = --metadata-file ] && meta=$2; shift; done
if [ -n "${NO_DIGEST:-}" ]; then echo '{}' > "$meta"; else printf '{"containerimage.digest": "sha256:0123abcd"}' > "$meta"; fi
FAKE
chmod +x "$BB/buildctl-daemonless.sh"
BD="$TMPP/bd"; stage "$BD"; printf 'FROM scratch\n' > "$BD/work/source/Dockerfile"
build() {   # build [VAR=value...] -> RC, OUT; buildctl arguments in $BD.call
  rm -f "$BD.call"
  if env -i PATH="$BB:$PATH" HOME="$BD/home" BUILD_CALL="$BD.call" IMAGE_REPO=reg.local:5000/demo/hello \
      REGISTRY_HOST=reg.local:5000 SHORT_SHA=abc1234 DOCKER_CONTEXT=. DOCKERFILE_PATH=Dockerfile BUILD_ARGS='[]' \
      PLATFORMS=linux/amd64,linux/arm64 BUILD_CACHE=true "$@" sh "$BD/opt/scripts/workflow/build.sh" > "$BD.out" 2>&1
  then RC=0; else RC=$?; fi
  OUT=$(cat "$BD.out")
}
build_args() { grep '^build-arg:' "$BD.call" | tr '\n' ';'; }
build
assert_eq "$RC:$(build_args)" "0:build-arg:VERSION=abc1234;" "build: VERSION build-arg from the short sha"
assert_eq "$(cat "$BD/tmp/digest-ref") $(cat "$BD/tmp/image")" \
  "reg.local:5000/demo/hello@sha256:0123abcd reg.local:5000/demo/hello:abc1234@sha256:0123abcd" "build: digest-ref + image outputs"
assert_matches "$(tr '\n' ' ' < "$BD.call")" <<'CASES'
build: every platform | --opt platform=linux/amd64,linux/arm64
build: SLSA provenance | --opt attest:provenance=mode=min
build: push by tag, OCI media types | --output type=image,name=reg.local:5000/demo/hello:abc1234,push=true,oci-mediatypes=true
build: registry cache | --export-cache type=registry,ref=reg.local:5000/demo/hello:buildcache,mode=max,image-manifest=true,oci-mediatypes=true --import-cache type=registry,ref=reg.local:5000/demo/hello:buildcache
CASES
build BUILD_CACHE=false
assert_eq "$RC:$(grep -c -e '-cache$' "$BD.call" || true)" "0:0" "build: build-cache false, no cache flags"
build BUILD_ARGS='[{"name":"A","value":"1"},{"name":"B","value":"x y"}, {"value":"no-name"}, {"name":"EMPTY","value":""}]'
assert_eq "$RC:$(build_args)" "0:build-arg:VERSION=abc1234;build-arg:A=1;build-arg:B=x y;build-arg:EMPTY=;" \
  "build: build-args JSON -> --opt build-arg:NAME=VALUE (an entry without a name is skipped)"
build BUILD_ARGS="$(printf '[\n  {\n    "name": "A",\n    "value": "1"\n  },\n  {\n    "name": "B",\n    "value": "2"\n  }\n]')"
assert_eq "$RC:$(build_args)" "0:build-arg:VERSION=abc1234;build-arg:A=1;build-arg:B=2;" "build: pretty-printed build-args JSON"
build DOCKERFILE_PATH=nope/Dockerfile
assert_eq "$RC:$OUT" "1:>> Dockerfile not found: nope/Dockerfile" "build: a missing Dockerfile stops the build"
# The context and Dockerfile must resolve inside the checkout: the pod also mounts the registry push credentials.
build DOCKER_CONTEXT=..
assert_eq "$RC:$OUT:$([[ -e "$BD.call" ]] && echo built || echo none)" "1:>> $BD/work/source/.. resolves outside the repository:none" \
  "build: a ../ context is refused"
build DOCKERFILE_PATH=../../registry-auth/config.json
assert_eq "$RC:$OUT" "1:>> $BD/work/source/../../registry-auth resolves outside the repository" "build: a ../ Dockerfile is refused"
# Git Bash without developer mode: `ln -s` copies (not a link), so the case SKIPs there (FAILs on Linux/macOS).
link_ctx() {   # a real symlink or nothing (Git Bash's plain `ln -s` silently copies)
  ln -s "$BD/registry-auth" "$BD/work/source/ctx" 2>/dev/null && [[ -L "$BD/work/source/ctx" ]] && return 0
  rm -rf "$BD/work/source/ctx"
  MSYS=winsymlinks:nativestrict ln -s "$BD/registry-auth" "$BD/work/source/ctx" 2>/dev/null && [[ -L "$BD/work/source/ctx" ]] && return 0
  rm -rf "$BD/work/source/ctx"; return 1
}
if link_ctx; then
  build DOCKER_CONTEXT=ctx
  assert_eq "$RC:$OUT" "1:>> $BD/work/source/ctx resolves outside the repository" "build: a symlinked context root is refused"
elif [[ "$(os_name)" == windows ]]; then
  echo "  SKIP 1 build assertion (symlinked context root): this Git Bash cannot create symlinks (enable Windows developer mode)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: cannot create a symlink on $(uname -s): the symlinked-context case must run here" >&2
fi
build NO_DIGEST=1
assert_eq "$RC:$(grep -c '^>> no digest in build metadata$' <<<"$OUT")" "1:1" "build: no digest in the metadata fails the build"
# Harbor CA + proxy-cache mirrors: buildkitd trusts the CA for the registry and its mirrors; buildctl through SSL_CERT_FILE.
mkdir -p "$BD/registry-ca" "$BD/buildkitd"; printf 'harbor ca\n' > "$BD/registry-ca/ca.crt"
printf '[registry."docker.io"]\n  mirrors = ["harbor.local/dockerhub"]\n' > "$BD/buildkitd/buildkitd.toml"
build
assert_eq "$RC:$(cat "$BD/home/.config/buildkit/buildkitd.toml")" "0:[registry.\"docker.io\"]
  mirrors = [\"harbor.local/dockerhub\"]
[registry.\"reg.local:5000\"]
  ca = [\"$BD/registry-ca/ca.crt\"]" "build: mirrors from buildkitd-config + the registry CA"
assert_match "$OUT" '   docker.io -> harbor.local/dockerhub' "build: logs the mirrors"
assert_eq "$(cat "$BD/home/ca.pem")" "system roots
harbor ca" "build: buildctl trusts the system roots + the registry CA"

# scan-fs.sh, scan-image.sh, sbom.sh, helm-package.sh: the env they hand to the ci/scripts they wrap.
TW="$TMPP/tw"; stage "$TW"; printf 'CVE-1\n' > "$TW/work/source/.trivyignore"
wrap() { local s=$1; shift; capture env -i PATH="$PATH" "$@" bash "$TW/opt/scripts/workflow/$s.sh"; OUT=${OUT//$'\n'/;}; }
wrap scan-fs APP_PATH=./app IGNORE_REL=.trivyignore
assert_eq "$RC:$OUT" "0:common/scan-fs.sh;IGNORE_FILE=$TW/work/source/.trivyignore;SCAN_PATH=$TW/work/source/app" \
  "scan-fs: app path + the repository's trivy-ignore file"
wrap scan-fs APP_PATH=. IGNORE_REL=missing
assert_eq "$RC:$OUT" "0:common/scan-fs.sh;SCAN_PATH=$TW/work/source/." "scan-fs: no ignore file when the repository has none"
wrap scan-image DIGEST_REF=r@sha256:1 IGNORE_REL=
assert_eq "$RC:$OUT" "0:common/scan-image.sh;DOCKER_CONFIG=/registry-auth;IMAGE_REF=r@sha256:1;IMAGE_SRC=remote;SSL_CERT_FILE=$TW/tmp/ca.pem" \
  "scan-image: the pushed digest, from the registry, with the registry's trust and auth"
assert_eq "$(cat "$TW/tmp/ca.pem")" "system roots" "registry trust: system roots without a registry CA"
mkdir -p "$TW/registry-ca"; printf 'harbor ca\n' > "$TW/registry-ca/ca.crt"
wrap sbom DIGEST_REF=r@sha256:1 PLATFORMS=linux/arm64,linux/amd64
assert_eq "$RC:$OUT" "0:common/sbom.sh;DOCKER_CONFIG=/registry-auth;IMAGE_REF=r@sha256:1;PLATFORM=linux/arm64;SOURCE=registry;SSL_CERT_FILE=$TW/tmp/ca.pem" \
  "sbom: the first platform of the pushed digest"
assert_eq "$(cat "$TW/tmp/ca.pem")" "system roots
harbor ca" "registry trust: system roots + the registry CA"
mkdir -p "$TW/out"; printf 'reg/charts/x@sha256:2' > "$TW/out/image_digest_ref"
wrap helm-package CHART_DIR=./charts/x PUSH=true CI_OUT_DIR="$TW/out"
assert_eq "$RC:$OUT" "0:helm/check.sh;CHART_PATH=$TW/work/source/charts/x;HELM_REGISTRY_CONFIG=$TW/registry-auth/config.json;SSL_CERT_FILE=$TW/tmp/ca.pem;helm/package-push.sh;CHART_PATH=$TW/work/source/charts/x;HELM_REGISTRY_CONFIG=$TW/registry-auth/config.json;SSL_CERT_FILE=$TW/tmp/ca.pem" \
  "helm-package: check.sh then package-push.sh on the chart path"
assert_eq "$(cat "$TW/tmp/digest-ref")" "reg/charts/x@sha256:2" "helm-package: pushed digest as output"
wrap helm-package CHART_DIR=. PUSH=false CI_OUT_DIR="$TW/out"
assert_eq "$RC:$(cat "$TW/tmp/digest-ref")" "0:none" "helm-package: no push, digest-ref none"

# falco-response (docs/observability.md "Falco response"): the event is a Falco alert whose output fields tenants control
# (command lines), so `{{`/`{{=` in it is possible. Steps get it (and the enrich result) only as env values; in source,
# args or command Argo would template it into code.
event_in_code() {   # event_in_code <rendered falco-response.yaml> -> offending template names, one per line
  yq -N 'select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.script or .container)
    | {"name": .name, "code": ((.script // .container) | del(.env) | tostring)}
    | select(.code | test("workflow\\.parameters\\.event|inputs\\.parameters\\.context")) | .name' "$1"
}
helm template argo-events "$ROOT/addons/argo-events" --namespace argo-events --set workflowPlane=true \
  -s templates/falco-response.yaml > "$TMP/falco-response.yaml"
assert_nonempty "$(yq -N 'select(.kind == "WorkflowTemplate") | .metadata.name' "$TMP/falco-response.yaml")" \
  "WorkflowTemplate falco-response renders"
assert_eq "$(event_in_code "$TMP/falco-response.yaml")" "" "falco-response passes the event to steps only as env"
# shellcheck disable=SC2016  # literal Argo template marker
yq '(select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.name == "enrich") | .script.source) |=
  . + " {{workflow.parameters.event}}"' "$TMP/falco-response.yaml" > "$TMP/falco-response-bad.yaml"
assert_eq "$(event_in_code "$TMP/falco-response-bad.yaml")" "enrich" "negative: the event spliced into a script source is caught"
dir="$ROOT/addons/openchoreo-platform/files/promotion-gate"
if ! pick_python; then
  echo "  SKIP python >= 3.9 not found"
  finish
  exit 0
fi
if ! "$PYTHON" -c 'import zoneinfo; zoneinfo.ZoneInfo("Europe/Tallinn")' >/dev/null 2>&1; then
  echo "  SKIP no IANA time zone data for Python (pip install tzdata on Windows)"
  finish
  exit 0
fi
if out=$(cd "$dir" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest -q test_gate 2>&1); then
  assert_eq ok ok "gate.py unit tests"
else
  echo "$out" >&2
  assert_eq failed ok "gate.py unit tests"
fi
if out=$(cd "$ROOT/addons/argo-events/files" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest -q test_falco_response 2>&1); then
  assert_eq ok ok "falco_response.py unit tests"
else
  echo "$out" >&2
  assert_eq failed ok "falco_response.py unit tests"
fi
if out=$(cd "$ROOT/addons/openchoreo-platform/files/auto-build" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest -q test_auto_build 2>&1); then
  assert_eq ok ok "auto_build.py unit tests"
else
  echo "$out" >&2
  assert_eq failed ok "auto_build.py unit tests"
fi
# shellcheck disable=SC2016  # literal template marker
hits=$(grep -c -e '{{' "$ROOT/addons/openchoreo-platform/files/auto-build/auto_build.py" || true)
assert_eq "$hits" "0" "auto_build.py contains no Argo template markers"
# The ClusterWorkflow embeds gate.py in a CEL template (and Argo templates it again).
# shellcheck disable=SC2016  # literal template markers
hits=$(grep -c -e '\${' -e '{{' "$dir/gate.py" || true)
assert_eq "$hits" "0" "gate.py contains no CEL/Argo template markers"

finish
