#!/usr/bin/env bash
# bootstrap/bootstrap.sh secret seeding, function by function, against a fake kubectl and a fake gh: no cluster is
# contacted. Checks credential precedence and warnings, the keys and values of every Secret applied, server-side apply,
# and that no secret value ever appears in a kubectl argv.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_bootstrap_secrets =="

# Real yq behind a wrapper: the scenarios run with a minimal PATH, and a mise shim would not find its config there.
REAL_YQ=$(mise which yq 2>/dev/null || command -v yq)
[[ -x "$REAL_YQ" ]] || { echo "  yq not found" >&2; exit 1; }

R="$TMP/root"; BIN="$TMP/bin"
mkdir -p "$R/bootstrap" "$R/hack" "$BIN"
cp -R "$ROOT/hack/lib" "$R/hack/"
cp -R "$ROOT/installations" "$R/"
# bootstrap.sh minus its dispatcher, plus a hook that runs $HARNESS_CALL after load_inst.
sed '/^case "\$CMD" in$/,$d' "$ROOT/bootstrap/bootstrap.sh" > "$R/bootstrap/bs.sh"
# shellcheck disable=SC2016  # literal code for the generated script
printf '%s\n' 'load_inst; eval "$HARNESS_CALL"' >> "$R/bootstrap/bs.sh"
LOCAL_INST="$R/installations/local/installation.yaml"
cp "$LOCAL_INST" "$TMP/local-installation.orig"

printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_YQ" > "$BIN/yq"

# Fake kubectl: logs argv, refuses the homelab context, captures server-side applies, answers a few gets from FAKE_*.
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$HLOG/calls"
for a in "$@"; do [[ "$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }; done
args=" $* "
case "$args" in
  *" apply "*" -f - "*)
    n=$(ls "$HLOG" | grep -c '^apply\.' || true)
    cat > "$HLOG/apply.$n.yaml"; exit 0 ;;
  *" delete secret "*) exit 0 ;;
  *" get externalsecret platform-repo-creds "*)
    [[ "${FAKE_REPO_CREDS_READY:-}" == 1 ]] && printf 'True'; exit 0 ;;
  *" get secret platform-repo-creds "*)
    printf '%s' "${FAKE_REPO_CREDS_URL:-}" | base64; exit 0 ;;
  *" get secret platform-repo-bootstrap "*)
    [[ "${FAKE_BOOTSTRAP_EXISTS:-}" == 1 ]]; exit $? ;;
  *" get secret platform-ghcr "*)
    [[ -n "${FAKE_GHCR_YAML:-}" ]] || exit 1
    cat "$FAKE_GHCR_YAML"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$HLOG/calls"
case "$*" in
  "auth token") echo gho_FAKEGHTOKEN ;;
  "api user --jq .login") [[ "${FAKE_GH_APIFAIL:-}" == 1 ]] && exit 1; echo fakeuser ;;
  "api -i user") [[ "${FAKE_GH_APIFAIL:-}" == 1 ]] && exit 1
    printf 'HTTP/2 200\r\nx-oauth-scopes: %s\r\n\r\n{}' "${FAKE_GH_SCOPES:-repo, read:org}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/"*

PEM="$TMP/app.pem"
printf -- '-----BEGIN FAKE KEY-----\nFAKEPEMBODY\n-----END FAKE KEY-----\n' > "$PEM"
chmod 600 "$PEM"
SECRETS='github_pat_FAKE|ghp_FAKE|gho_FAKE|GHCRFAKE|FAKEPEMBODY'

# run <name> <call> [VAR=val ...]: run a bootstrap function in a clean environment; sets RC, OUT (stdout+stderr,
# colours stripped) and HLOG (calls, apply.N.yaml).
run() {
  local name=$1 call=$2; shift 2
  HLOG="$TMP/out/$name"; mkdir -p "$HLOG"; : > "$HLOG/calls"
  if env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" SYSTEMROOT="${SYSTEMROOT:-}" TMPDIR="$TMP" HLOG="$HLOG" \
      KUBE_CTX=fake INST=local HARNESS_CALL="$call" "$@" "$BASH" "$R/bootstrap/bs.sh" > "$HLOG/out" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$HLOG/out")
  # Invariants for every scenario: no secret value in any argv, only the fake context, every apply server-side.
  assert_eq "$(grep -Ec "$SECRETS" "$HLOG/calls" || true)" 0 "$name: no secret value in argv"
  assert_eq "$(grep -c -- '--context fake' "$HLOG/calls" || true)" "$(grep -c '^kubectl' "$HLOG/calls" || true)" "$name: only the fake context"
  assert_eq "$(grep '^kubectl' "$HLOG/calls" | grep ' apply ' | grep -vc -- '--server-side --field-manager=platform-bootstrap --force-conflicts' || true)" 0 "$name: applies are server-side"
  assert_eq "$(grep -Ec -- 'create secret|--from-literal|--from-file|last-applied' "$HLOG/calls" || true)" 0 "$name: no client-side secret building"
}
# applied <name> -> file of the last applied object with that metadata.name ("" if none)
applied() {
  local f hit=""
  for f in "$HLOG"/apply.*.yaml; do
    [[ -f "$f" ]] || continue
    [[ "$(yq '.metadata.name' "$f")" == "$1" ]] && hit=$f
  done
  printf '%s' "$hit"
}
# q <name> <yq expr>: query the last applied object of that name; empty (not an error) when there is none, so a
# regression shows up as failed assertions instead of aborting the run.
q()    { local f; f=$(applied "$1"); [[ -z "$f" ]] || yq -r "$2" "$f"; }
keys() { q "$1" '.data // {} | keys | sort | join(",")'; }
val()  { q "$1" ".data[\"$2\"] // \"\" | @base64d"; }
meta() { q "$1" ".metadata.$2 // \"\""; }
has()  { [[ "$1" =~ $2 ]] && echo yes || echo no; }
nra()  { printf '%s\n' "$(cat "$TMP/local-installation.orig")" > "$LOCAL_INST"; [[ -z "${1:-}" ]] || \
           ( v=$1 yq -i '.secrets.nodeRegistryAuth.enabled = (strenv(v) == "true")' "$LOCAL_INST" ); }

S=cmd_secrets
nra true

# --- platform-github: GitHub App -----------------------------------------------------------------------------------
run app "$S" GITHUB_APP_ID=123 GITHUB_APP_INSTALLATION_ID=456 GITHUB_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$RC" 0 "app: rc"
assert_eq "$(keys platform-github)" "githubAppID,githubAppInstallationID,githubAppPrivateKey" "app: keys"
assert_eq "$(val platform-github githubAppID)" 123 "app: App ID kept as string"
assert_eq "$(val platform-github githubAppPrivateKey)" "$(cat "$PEM")" "app: private key from file"
assert_eq "$(meta platform-github namespace)" platform-secrets "app: namespace"
assert_eq "$(q platform-secrets .kind)" Namespace "app: namespace applied server-side"
assert_eq "$(has "$OUT" 'repoCreds.auth is token')" yes "app: warns repoCreds.auth mismatch"
assert_eq "$(has "$OUT" 'group/others')" no "app: 0600 key file, no mode warning"
assert_eq "$(keys openchoreo)" "admin-user-password,backstage-backend-secret,backstage-client-secret,developer-user-password,thunder-admin-password" "app: generated openchoreo keys"
assert_eq "$(val openchoreo-observability opensearch-username)" admin "app: fixed generated value"
assert_match "$(val openchoreo-observability opensearch-password)" '^Px9!' "app: @strong generated value"
gen=$(val openchoreo thunder-admin-password)
assert_eq "${#gen}" 24 "app: generated password length"
assert_eq "$(grep -c -- "$gen" "$HLOG/calls" || true)" 0 "app: generated password not in argv"

# repoCreds.auth from the env-/cluster- overlays the AppSet layers on top of values.yaml
SS="$R/installations/local/addons/secret-stores"; mkdir -p "$SS"
printf 'repoCreds:\n  auth: githubApp\n' > "$SS/env-mgmt.yaml"
run app_overlay "$S" GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(has "$OUT" 'repoCreds.auth is')" no "app: env-mgmt.yaml overlay satisfies the check"
printf 'repoCreds:\n  auth: token\n' > "$SS/cluster-mgmt.yaml"
run app_overlay2 "$S" GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(has "$OUT" 'repoCreds.auth is token \(.*cluster-mgmt\.yaml\)')" yes "app: cluster-mgmt.yaml overlay wins and is named"
rm -rf "$SS"

run app_partial "$S" GITHUB_APP_ID=123
assert_eq "$RC" 1 "app partial: fails closed"
assert_eq "$(has "$OUT" 'needs GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY_FILE')" yes "app partial: message"
run app_badkey "$S" GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY_FILE=/nonexistent.pem
assert_eq "$RC" 1 "app unreadable key: fails"

if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* && "$(uname -s)" != CYGWIN* ]]; then
  cp "$PEM" "$TMP/open.pem"; chmod 644 "$TMP/open.pem"
  run app_keymode "$S" GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY_FILE="$TMP/open.pem"
  assert_eq "$(has "$OUT" 'GITHUB_APP_PRIVATE_KEY_FILE .* accessible by group/others')" yes "app: warns on 0644 key file"
fi

run app_precedence "$S" GITHUB_APP_ID=1 GITHUB_APP_INSTALLATION_ID=2 GITHUB_APP_PRIVATE_KEY_FILE="$PEM" PLATFORM_GITHUB_TOKEN=github_pat_FAKE
assert_eq "$(keys platform-github)" "githubAppID,githubAppInstallationID,githubAppPrivateKey" "App env wins over a token"

# --- platform-github: tokens ---------------------------------------------------------------------------------------
run token "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE
assert_eq "$RC" 0 "token: rc"
assert_eq "$(keys platform-github)" "token,username" "token: keys"
assert_eq "$(val platform-github token)" github_pat_FAKE "token: value"
assert_eq "$(val platform-github username)" git "token: username defaults to git"
assert_eq "$(has "$OUT" 'WARN: (using GITHUB_TOKEN|PLATFORM_GITHUB_TOKEN is)')" no "token: fine-grained PAT, no warning"

run token_legacy "$S" GITHUB_TOKEN=github_pat_FAKE GITHUB_USER=bob
assert_eq "$(val platform-github token)" github_pat_FAKE "GITHUB_TOKEN still accepted"
assert_eq "$(val platform-github username)" bob "GITHUB_USER still accepted"
assert_eq "$(has "$OUT" 'set the dedicated PLATFORM_GITHUB_TOKEN')" yes "GITHUB_TOKEN warns"
run token_both "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE GITHUB_TOKEN=ghp_FAKE PLATFORM_GITHUB_USER=alice
assert_eq "$(val platform-github token)" github_pat_FAKE "PLATFORM_GITHUB_TOKEN wins over GITHUB_TOKEN"
assert_eq "$(val platform-github username)" alice "PLATFORM_GITHUB_USER"
run token_classic "$S" PLATFORM_GITHUB_TOKEN=ghp_FAKE
assert_eq "$(has "$OUT" 'classic PAT \(ghp_\)')" yes "warns on classic PAT"
run token_oauth "$S" PLATFORM_GITHUB_TOKEN=gho_FAKE
assert_eq "$(has "$OUT" 'OAuth token \(gho_')" yes "warns on OAuth token"

# --- platform-ghcr ---------------------------------------------------------------------------------------------------
run ghcr "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE GHCR_TOKEN=ghp_GHCRFAKE GHCR_USER=machine
assert_eq "$(keys platform-ghcr)" "token,username" "ghcr: keys"
assert_eq "$(val platform-ghcr token)" ghp_GHCRFAKE "ghcr: token"
assert_eq "$(val platform-ghcr username)" machine "ghcr: user"
assert_eq "$(meta platform-ghcr 'annotations["platform.koorikla.io/seeded-from"]')" env "ghcr: source annotation"
run ghcr_nouser "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE GHCR_TOKEN=ghp_GHCRFAKE
assert_eq "$RC" 1 "ghcr without user: fails"
assert_eq "$(has "$OUT" 'also set GHCR_USER')" yes "ghcr without user: message"

run gh_noscope "$S"
assert_eq "$RC" 0 "gh: rc"
assert_eq "$(val platform-github token)" gho_FAKEGHTOKEN "gh: platform-github from gh"
assert_eq "$(val platform-github username)" fakeuser "gh: login"
assert_eq "$(applied platform-ghcr)" "" "gh without read:packages: platform-ghcr not seeded"
assert_eq "$(has "$OUT" 'lacks read:packages')" yes "gh without read:packages: says so"
assert_eq "$(has "$OUT" 'nodeRegistryAuth: \{enabled: false\}')" yes "gh without read:packages: points at nodeRegistryAuth"
run gh_scope "$S" FAKE_GH_SCOPES="repo, read:packages"
assert_eq "$(val platform-ghcr token)" gho_FAKEGHTOKEN "gh with read:packages: platform-ghcr seeded"
assert_eq "$(meta platform-ghcr 'annotations["platform.koorikla.io/seeded-from"]')" gh "gh with read:packages: annotated"
run gh_override "$S" FAKE_GH_SCOPES="repo, read:packages" GHCR_TOKEN=ghp_GHCRFAKE GHCR_USER=bob
assert_eq "$(val platform-ghcr username)" bob "GHCR_TOKEN wins over the gh token"
run gh_apifail "$S" FAKE_GH_APIFAIL=1
assert_eq "$RC" 0 "gh api failure: not fatal"
assert_eq "$(val platform-github username)" git "gh api failure: username git"
assert_eq "$(has "$OUT" "gh api user failed")" yes "gh api failure: warns"
assert_eq "$(applied platform-ghcr)" "" "gh api failure: scopes unknown, platform-ghcr not seeded"

# stale platform-ghcr from an earlier run
printf 'metadata:\n  annotations:\n    platform.koorikla.io/seeded-from: gh\ndata:\n  token: %s\n' "$(printf x | base64)" > "$TMP/ghcr-gh.yaml"
printf 'data:\n  token: %s\n' "$(printf gho_X | base64)" > "$TMP/ghcr-old.yaml"
printf 'metadata:\n  annotations:\n    platform.koorikla.io/seeded-from: env\ndata:\n  token: %s\n' "$(printf x | base64)" > "$TMP/ghcr-env.yaml"
run stale_gh_nra "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_GHCR_YAML="$TMP/ghcr-gh.yaml"
assert_eq "$(grep -c 'delete secret platform-ghcr' "$HLOG/calls" || true)" 0 "stale gh copy kept while nodeRegistryAuth needs it"
assert_eq "$(has "$OUT" 'still holds the gh CLI token')" yes "stale gh copy reported"
nra false
run stale_gh "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_GHCR_YAML="$TMP/ghcr-gh.yaml"
assert_eq "$(grep -c 'delete secret platform-ghcr' "$HLOG/calls" || true)" 1 "stale gh-seeded platform-ghcr deleted"
run stale_old "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_GHCR_YAML="$TMP/ghcr-old.yaml"
assert_eq "$(grep -c 'delete secret platform-ghcr' "$HLOG/calls" || true)" 1 "stale gho_ platform-ghcr (no annotation) deleted"
run stale_env "$S" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_GHCR_YAML="$TMP/ghcr-env.yaml"
assert_eq "$(grep -c 'delete secret platform-ghcr' "$HLOG/calls" || true)" 0 "user-seeded platform-ghcr kept"
assert_eq "$(has "$OUT" 'platform-ghcr: kept from an earlier run')" yes "user-seeded platform-ghcr reported"
nra true

nra false
run nra_off "$S" FAKE_GH_SCOPES="repo, read:packages"
assert_eq "$(applied platform-ghcr)" "" "nodeRegistryAuth off: gh token not copied"
assert_eq "$(has "$OUT" 'not needed \(secrets.nodeRegistryAuth.enabled=false\)')" yes "nodeRegistryAuth off: reported (false not read as default)"
nra ""
run nra_repo_default "$S" NO_GH=1
assert_eq "$(has "$OUT" 'not needed')" yes "installations/local: nodeRegistryAuth off (public images)"
nra true

# --- other keys -----------------------------------------------------------------------------------------------------
run no_gh "$S" NO_GH=1
assert_eq "$(applied platform-github)" "" "NO_GH=1: platform-github skipped"
assert_eq "$(grep -c '^gh ' "$HLOG/calls" || true)" 0 "NO_GH=1: gh not called"
run push_app "$S" NO_GH=1 GITHUB_PUSH_APP_ID=9 GITHUB_PUSH_APP_INSTALLATION_ID=8 GITHUB_PUSH_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(keys platform-github-app)" "githubAppID,githubAppInstallationID,githubAppPrivateKey" "push App: keys"
assert_eq "$(val platform-github-app githubAppInstallationID)" 8 "push App: installation"
run push_partial "$S" NO_GH=1 GITHUB_PUSH_APP_ID=9
assert_eq "$RC" 1 "push App partial: fails closed"
run gate_app "$S" NO_GH=1 GITHUB_GATE_APP_ID=7 GITHUB_GATE_APP_INSTALLATION_ID=6 GITHUB_GATE_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(keys promotion-gate-github)" "githubAppID,githubAppInstallationID,githubAppPrivateKey" "gate App: keys"
assert_eq "$(val promotion-gate-github githubAppID)" 7 "gate App: app id"
assert_eq "$(val promotion-gate-github githubAppPrivateKey | grep -c FAKEPEMBODY)" 1 "gate App: private key from the file"
assert_eq "$(applied platform-github-app)" "" "gate App: does not seed the push App"
run gate_partial "$S" NO_GH=1 GITHUB_GATE_APP_INSTALLATION_ID=6
assert_eq "$RC" 1 "gate App partial: fails closed"

# --- Argo CD bootstrap repo secret ----------------------------------------------------------------------------------
B=seed_argocd_repo_secret
run repo_app "$B" GITHUB_APP_ID=123 GITHUB_APP_INSTALLATION_ID=456 GITHUB_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(keys platform-repo-bootstrap)" "githubAppID,githubAppInstallationID,githubAppPrivateKey,type,url" "repo app: keys"
assert_eq "$(meta platform-repo-bootstrap namespace)" argocd "repo app: namespace"
assert_eq "$(meta platform-repo-bootstrap 'labels["argocd.argoproj.io/secret-type"]')" repo-creds "repo app: repo-creds label"
assert_eq "$(val platform-repo-bootstrap url)" "$(yq '.installation.githubOrg' "$LOCAL_INST")" "repo app: url = githubOrg"
assert_eq "$(val platform-repo-bootstrap githubAppPrivateKey)" "$(cat "$PEM")" "repo app: private key"
run repo_token "$B" PLATFORM_GITHUB_TOKEN=github_pat_FAKE
assert_eq "$(keys platform-repo-bootstrap)" "password,type,url,username" "repo token: keys"
assert_eq "$(val platform-repo-bootstrap password)" github_pat_FAKE "repo token: password"
assert_eq "$(val platform-repo-bootstrap type)" git "repo token: type"
run repo_gh "$B"
assert_eq "$(val platform-repo-bootstrap username)" fakeuser "repo gh: username"
run repo_gh_apifail "$B" FAKE_GH_APIFAIL=1
assert_eq "$RC" 0 "repo gh api failure: not fatal"
assert_eq "$(val platform-repo-bootstrap username)" git "repo gh api failure: username git"
run repo_none "$B" NO_GH=1
assert_eq "$(applied platform-repo-bootstrap)" "" "repo none: skipped"
run repo_nonkube "BACKEND=aws; $B"
assert_eq "$(applied platform-repo-bootstrap)" "" "repo non-kubernetes backend: no gh fallback"

ORG_URL=$(yq '.installation.githubOrg' "$LOCAL_INST")
run repo_retire "$B" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_REPO_CREDS_READY=1 FAKE_REPO_CREDS_URL="$ORG_URL" FAKE_BOOTSTRAP_EXISTS=1
assert_eq "$(applied platform-repo-bootstrap)" "" "repo-creds Ready: no bootstrap secret seeded"
assert_eq "$(grep -c 'delete secret platform-repo-bootstrap' "$HLOG/calls" || true)" 1 "repo-creds Ready: bootstrap secret deleted"
run repo_otherurl "$B" PLATFORM_GITHUB_TOKEN=github_pat_FAKE FAKE_REPO_CREDS_READY=1 FAKE_REPO_CREDS_URL=https://github.com/other FAKE_BOOTSTRAP_EXISTS=1
assert_eq "$(keys platform-repo-bootstrap)" "password,type,url,username" "repo-creds for another URL: bootstrap secret kept"
assert_eq "$(grep -c 'delete secret' "$HLOG/calls" || true)" 0 "repo-creds for another URL: nothing deleted"
run repo_wait "wait_retire_repo_bootstrap" REPO_CREDS_WAIT=0 FAKE_BOOTSTRAP_EXISTS=1
assert_eq "$(has "$OUT" 'platform-repo-bootstrap kept')" yes "up: not Ready within REPO_CREDS_WAIT, kept with a hint"
run repo_wait_ready "wait_retire_repo_bootstrap" REPO_CREDS_WAIT=0 FAKE_BOOTSTRAP_EXISTS=1 FAKE_REPO_CREDS_READY=1 FAKE_REPO_CREDS_URL="$ORG_URL"
assert_eq "$(grep -c 'delete secret platform-repo-bootstrap' "$HLOG/calls" || true)" 1 "up: Ready, bootstrap secret deleted"

finish
