#!/usr/bin/env bash
# bootstrap/bootstrap.sh secret seeding, function by function, against a fake kubectl and a fake gh: no cluster is
# contacted. Checks credential precedence and warnings, the keys and values of every Secret applied, server-side apply,
# and that no secret value ever appears in a kubectl argv.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bootstrap_harness
cp "$ROOT/bootstrap/root-app.yaml" "$R/bootstrap/"   # root_app_manifest
LOCAL_INST="$R/installations/local/installation.yaml"
cp "$LOCAL_INST" "$TMP/local-installation.orig"

# The yq wrapper logs its argv too: secret values reach yq only through the environment (strenv), never as arguments.
# shellcheck disable=SC2016  # literal code for the generated wrapper
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "yq $*" >> "$HLOG/calls"\nexec "%s" "$@"\n' "$REAL_YQ" > "$BIN/yq"

# Fake kubectl: logs argv, refuses the homelab context, captures server-side applies, answers a few gets from FAKE_*.
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$HLOG/calls"
for a in "$@"; do [[ "$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }; done
args=" $* "
if [[ -n "${FAKE_KUBE_ERR:-}" && "$args" == *" get "* ]]; then
  printf '%s\n' "$FAKE_KUBE_ERR" >&2
  exit 1
fi
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
    if [[ -n "${FAKE_GHCR_YAML:-}" ]]; then cat "$FAKE_GHCR_YAML"; exit 0; fi
    [[ "$args" == *" --ignore-not-found "* ]] && exit 0
    printf 'Error from server (NotFound): secrets "platform-ghcr" not found\n' >&2; exit 1 ;;
  *" get secret "*)   # existing Secrets live at $FAKE_SECRET_DIR/<name>.yaml
    n=""; prev=""; for a in "$@"; do [[ "$prev" == secret ]] && n=$a; prev=$a; done
    if [[ -n "${FAKE_SECRET_DIR:-}" && -f "$FAKE_SECRET_DIR/$n.yaml" ]]; then
      case "$args" in
        *" -o yaml "*) cat "$FAKE_SECRET_DIR/$n.yaml" ;;
        *" -o name "*) printf 'secret/%s\n' "$n" ;;
      esac
      exit 0
    fi
    [[ "$args" == *" --ignore-not-found "* ]] && exit 0
    printf 'Error from server (NotFound): secrets "%s" not found\n' "$n" >&2; exit 1 ;;
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
# Fake docker: `cosign generate-key-pair` into the -v mounted dir (seed_cosign_secret); records the dir, the workdir,
# whether Git Bash path conversion was off and whether COSIGN_PASSWORD arrived through the environment. The host dir
# is everything before the last `:` (on Windows it is C:/Users/..., a drive colon of its own).
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >> "$HLOG/calls"
[[ "${1:-}" == inspect ]] && { printf '%s\n' "${FAKE_K3D_IP:-}"; exit 0; }   # seed_byo_kubeconfigs: node IP on kind
printf '%s' "${MSYS_NO_PATHCONV:-}" > "$HLOG/cosign-noconv"
[[ "${FAKE_DOCKER_FAIL:-}" == 1 ]] && { prev=""; for a in "$@"; do [[ "$prev" == -v ]] && printf '%s' "${a%:*}" > "$HLOG/cosign-dir"; prev=$a; done; exit 1; }
prev=""
for a in "$@"; do
  [[ "$prev" == -w ]] && printf '%s' "$a" > "$HLOG/cosign-workdir"
  if [[ "$prev" == -v ]]; then
    d=${a%:*}; printf '%s' "$d" > "$HLOG/cosign-dir"
    [[ "${a##*:}" == /keys && -d "$d" ]] || { echo "fake docker: bad bind mount $a" >&2; exit 1; }
    printf -- '-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nFAKECOSIGNKEY\n-----END ENCRYPTED SIGSTORE PRIVATE KEY-----\n' > "$d/cosign.key"   # gitleaks:allow: fake key from the docker stub
    printf -- '-----BEGIN PUBLIC KEY-----\nFAKEPUB\n-----END PUBLIC KEY-----\n' > "$d/cosign.pub"
  fi
  prev=$a
done
printf '%s' "${#COSIGN_PASSWORD}" > "$HLOG/cosign-pass-len"
EOF
# Fake k3d (seed_byo_kubeconfigs): `k3d kubeconfig get <name>` answers only while FAKE_K3D_KUBECONFIG names a file.
cat > "$BIN/k3d" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "k3d $*" >> "$HLOG/calls"
[[ "$1 $2" == "kubeconfig get" && -n "${FAKE_K3D_KUBECONFIG:-}" ]] || exit 1
cat "$FAKE_K3D_KUBECONFIG"
EOF
chmod +x "$BIN/"*

PEM="$TMP/app.pem"
printf -- '-----BEGIN FAKE KEY-----\nFAKEPEMBODY\n-----END FAKE KEY-----\n' > "$PEM"
chmod 600 "$PEM"
SECRETS='github_pat_FAKE|ghp_FAKE|gho_FAKE|GHCRFAKE|FAKEPEMBODY|FAKECOSIGNKEY|FAKEKEEP|GHLOGINFakeSec'

# run <name> <call> [VAR=val ...]: run a bootstrap function in a clean environment; sets RC, OUT (stdout+stderr,
# colours stripped) and HLOG (calls, apply.N.yaml).
run() {
  local name=$1 call=$2; shift 2
  run_isolated "$name" "$R/bootstrap/bs.sh" KUBE_CTX=fake INST=local HARNESS_CALL="$call" "$@"
  # Invariants for every scenario: no secret value in any argv, only the fake context, every apply server-side.
  assert_eq "$(grep -Ec "$SECRETS" "$HLOG/calls" || true)" 0 "$name: no secret value in argv"
  assert_eq "$(grep -Ec "$SECRETS" "$HLOG/out" || true)" 0 "$name: no secret value in the output"
  assert_eq "$(grep -c -- '--context fake' "$HLOG/calls" || true)" "$(grep -c '^kubectl' "$HLOG/calls" || true)" "$name: only the fake context"
  assert_eq "$(grep '^kubectl' "$HLOG/calls" | grep ' apply ' | grep -vc -- '--server-side --field-manager=platform-bootstrap --force-conflicts' || true)" 0 "$name: applies are server-side"
  assert_eq "$(grep -Ec -- 'create secret|--from-literal|--from-file|last-applied' "$HLOG/calls" || true)" 0 "$name: no client-side secret building"
}
# applied <name> -> file of the last applied object with that metadata.name ("" if none)
applied() {
  local f hit=""
  for f in "$HLOG"/apply.*.yaml; do
    [[ -f "$f" ]] || continue
    grep -q "^  name: $1$" "$f" && hit=$f
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
assert_eq "$(keys openchoreo)" "admin-user-password,backstage-backend-secret,backstage-client-secret,developer-user-password,service-mcp-client-secret,thunder-admin-password" "app: generated openchoreo keys"
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
run gate_none "$S" NO_GH=1
assert_eq "$(applied promotion-gate-github)" "" "gate App unset: nothing seeded"
assert_eq "$(has "$OUT" 'no GITHUB_GATE_APP_\*: auto-build and PR previews stay off')" yes "gate App unset: says what stays off"
run repo_admin_app "$S" NO_GH=1 GITHUB_REPO_ADMIN_APP_ID=5 GITHUB_REPO_ADMIN_APP_INSTALLATION_ID=4 GITHUB_REPO_ADMIN_APP_PRIVATE_KEY_FILE="$PEM"
assert_eq "$(keys github-repo-admin)" "githubAppID,githubAppInstallationID,githubAppPrivateKey" "repo-admin App: keys"
assert_eq "$(val github-repo-admin githubAppInstallationID)" 4 "repo-admin App: installation"
assert_eq "$(val github-repo-admin githubAppPrivateKey | grep -c FAKEPEMBODY)" 1 "repo-admin App: private key from the file"
assert_eq "$(applied promotion-gate-github)" "" "repo-admin App: does not seed the gate App"
run repo_admin_partial "$S" NO_GH=1 GITHUB_REPO_ADMIN_APP_ID=5
assert_eq "$RC" 1 "repo-admin App partial: fails closed"
run repo_admin_none "$S" NO_GH=1
assert_eq "$(applied github-repo-admin)" "" "repo-admin App unset: nothing seeded (an earlier seed is left as is)"

# --- root app: secrets.githubGateApp.enabled follows the seeded key (#192) -------------------------------------------
mkdir -p "$TMP/gate-seeded"; printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: promotion-gate-github\n' > "$TMP/gate-seeded/promotion-gate-github.yaml"
gate_param() { printf '%s\n' "$OUT" | yq -r '.spec.source.helm.parameters // [] | map(select(.name == "secrets.githubGateApp.enabled")) | .[0].value // "none"'; }
run root_gate_on "root_app_manifest" FAKE_SECRET_DIR="$TMP/gate-seeded"
assert_eq "$(gate_param)" true "root app: gate App seeded -> secrets.githubGateApp.enabled=true"
assert_eq "$(printf '%s\n' "$OUT" | yq -r '.spec.source.helm.valueFiles[0]')" ../../installations/local/installation.yaml "root app: value file of the installation"
run root_gate_off "root_app_manifest" FAKE_SECRET_DIR="$TMP/empty"
assert_eq "$(gate_param)" false "root app: no gate App -> secrets.githubGateApp.enabled=false (fork without the App converges)"
yq -i '.secrets.githubGateApp.enabled = false' "$LOCAL_INST"
run root_gate_forced "root_app_manifest" FAKE_SECRET_DIR="$TMP/gate-seeded"
assert_eq "$(gate_param)" false "root app: installation.yaml false wins over a seeded key"
yq -i '.secrets.backend = "aws" | del(.secrets.githubGateApp)' "$LOCAL_INST"
run root_gate_aws "root_app_manifest" FAKE_SECRET_DIR="$TMP/gate-seeded"
assert_eq "$(gate_param)" none "root app: other backends -> no parameter, installation.yaml decides"
assert_eq "$(grep -c 'get secret promotion-gate-github' "$HLOG/calls" || true)" 0 "root app: other backends -> no secret lookup"
# --- root app: registry.hostCache.enabled (host pull-through caches) follows installation.yaml and REGISTRY_CACHE ---
cache_param() { printf '%s\n' "$OUT" | yq -r '.spec.source.helm.parameters // [] | map(select(.name == "registry.hostCache.enabled")) | .[0].value // "none"'; }
run root_cache_on "root_app_manifest" FAKE_SECRET_DIR="$TMP/empty"
assert_eq "$(cache_param)" true "root app: local installation.yaml -> registry.hostCache.enabled=true"
run root_cache_off "root_app_manifest" FAKE_SECRET_DIR="$TMP/empty" REGISTRY_CACHE=0
assert_eq "$(cache_param)" false "root app: REGISTRY_CACHE=0 -> registry.hostCache.enabled=false (CAPD nodes keep Harbor)"
nra true

# --- no build PAT (#34): builds mint per-repository GitHub App tokens (ESO generator), nothing to seed ------------
run build_gh "$S"
assert_eq "$(applied platform-github-build)" "" "builds: the gh CLI token is never seeded as a build credential"
run build_pat "$S" NO_GH=1 PLATFORM_GITHUB_BUILD_TOKEN=github_pat_FAKE
assert_eq "$(applied platform-github-build)" "" "builds: a PAT in the environment is ignored (no long-lived build token)"
assert_eq "$(has "$OUT" 'github_pat_FAKE')" no "builds: the ignored PAT is not echoed"

# --- harbor + cosign-platform ---------------------------------------------------------------------------------------
run cosign "$S" NO_GH=1
assert_eq "$RC" 0 "cosign: rc"
assert_eq "$(keys harbor)" "admin-password,builder-secret,core-secret,csrf-key,database-password,jobservice-secret,nodes-secret,registry-http-secret,registry-password,secret-key" "harbor: keys"
hk=$(val harbor secret-key); assert_eq "${#hk}" 16 "harbor: secret-key exactly 16 chars"
hk=$(val harbor csrf-key); assert_eq "${#hk}" 32 "harbor: csrf-key exactly 32 chars"
assert_eq "$(keys openbao-unseal)" "key" "openbao-unseal: keys"
assert_match "$(val openbao-unseal key)" '^[0-9a-f]{64}$' "openbao-unseal: 64 hex chars (32-byte AES-256 static seal key)"
assert_eq "$(keys cosign-platform)" "cosign.key,cosign.password,cosign.pub" "cosign: keys"
assert_match "$(val cosign-platform cosign.key)" 'FAKECOSIGNKEY' "cosign: private key from the generated file"
cpass=$(val cosign-platform cosign.password)
assert_eq "${#cpass}" 32 "cosign: 32-char password"
assert_eq "$(cat "$HLOG/cosign-pass-len")" 32 "cosign: password reached docker through the environment"
assert_eq "$(grep -c -- "$cpass" "$HLOG/calls" || true)" 0 "cosign: password not in argv"
assert_eq "$(grep -c 'COSIGN_PASSWORD=' "$HLOG/calls" || true)" 0 "cosign: docker -e passes the name only"
assert_eq "$([[ -e "$(cat "$HLOG/cosign-dir")" ]] && echo left || echo removed)" removed "cosign: key dir removed"
assert_eq "$(cat "$HLOG/cosign-workdir")" /keys "cosign: container workdir /keys"
assert_eq "$(cat "$HLOG/cosign-noconv")" 1 "cosign: Git Bash argument path conversion off for docker"
run cosign_fail "$S" NO_GH=1 FAKE_DOCKER_FAIL=1
assert_eq "$([[ $RC -ne 0 ]] && echo failed || echo ok)" failed "cosign: docker failure fails the run"
assert_eq "$([[ -e "$(cat "$HLOG/cosign-dir")" ]] && echo left || echo removed)" removed "cosign: key dir removed on failure (trap)"
assert_eq "$(applied cosign-platform)" "" "cosign: nothing applied on failure"

# --- generated secrets: (a) NotFound generates, (b) existing keeps value, (c) API/timeout error aborts ---------------
# (a lost value here would rotate live credentials, e.g. the OpenBao static seal key = sealed data unreadable)
mkdir -p "$TMP/empty" "$TMP/existing"
run seed_notfound "seed_generated_secret openbao-unseal key=@hex32" FAKE_SECRET_DIR="$TMP/empty"
assert_eq "$RC" 0 "notfound: rc"
assert_match "$(val openbao-unseal key)" '^[0-9a-f]{64}$' "notfound: OpenBao seal key generated"

b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
printf 'apiVersion: v1\nkind: Secret\nmetadata: { name: openchoreo-observability, namespace: platform-secrets }\ndata:\n  opensearch-username: %s\n  opensearch-password: %s\n' \
  "$(b64 custom-admin)" "$(b64 'Px9!FAKEKEEPPASS')" > "$TMP/existing/openchoreo-observability.yaml"
printf 'apiVersion: v1\nkind: Secret\nmetadata: { name: openbao-unseal, namespace: platform-secrets }\ndata:\n  key: %s\n' \
  "$(b64 FAKEKEEPUNSEAL)" > "$TMP/existing/openbao-unseal.yaml"
printf 'apiVersion: v1\nkind: Secret\nmetadata: { name: cosign-platform, namespace: platform-secrets }\ndata:\n  cosign.key: %s\n' \
  "$(b64 FAKEKEEP_COSIGN)" > "$TMP/existing/cosign-platform.yaml"
run regen "seed_generated_secret openchoreo-observability opensearch-username=admin opensearch-password=@strong observer-client-secret; seed_generated_secret openbao-unseal key=@hex32; seed_cosign_secret" \
  FAKE_SECRET_DIR="$TMP/existing"
assert_eq "$RC" 0 "re-run: rc"
assert_eq "$(val openchoreo-observability opensearch-username)" custom-admin "re-run: existing value wins over the fixed default"
assert_eq "$(val openchoreo-observability opensearch-password)" 'Px9!FAKEKEEPPASS' "re-run: existing @strong value kept"
assert_match "$(val openchoreo-observability observer-client-secret)" '^[A-Za-z0-9]{24}$' "re-run: missing key generated"
assert_eq "$(val openbao-unseal key)" FAKEKEEPUNSEAL "re-run: OpenBao seal key kept"
assert_eq "$(applied cosign-platform)" "" "re-run: existing cosign-platform not re-applied"
assert_eq "$(grep -c '^docker ' "$HLOG/calls" || true)" 0 "re-run: existing cosign-platform does not run cosign"
assert_eq "$(grep -c FAKEKEEP "$HLOG/out" || true)" 0 "re-run: no secret value in the output"

# (c) Any non-NotFound kubectl failure (timeout, API down, RBAC) must abort without generating or applying anything.
applies_count() {
  local f n=0
  for f in "$HLOG"/apply.*.yaml; do [[ -f "$f" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}
run seed_api_timeout "seed_generated_secret openbao-unseal key=@hex32" \
  FAKE_SECRET_DIR="$TMP/existing" FAKE_KUBE_ERR="Unable to connect to the server: dial tcp 127.0.0.1:6443: i/o timeout"
assert_eq "$([[ $RC -ne 0 ]] && echo aborted || echo ok)" aborted "api timeout: seed_generated_secret aborts"
assert_eq "$(applies_count)" 0 "api timeout: nothing applied (OpenBao seal key untouched)"
assert_eq "$(has "$OUT" 'ERROR:.*openbao-unseal')" yes "api timeout: clear error names the secret"
assert_eq "$(grep -c FAKEKEEP "$HLOG/out" || true)" 0 "api timeout: no secret value in the output"

run seed_api_rbac "seed_generated_secret openchoreo thunder-admin-password" \
  FAKE_SECRET_DIR="$TMP/existing" FAKE_KUBE_ERR='Error from server (Forbidden): secrets "openchoreo" is forbidden'
assert_eq "$([[ $RC -ne 0 ]] && echo aborted || echo ok)" aborted "api rbac: seed_generated_secret aborts"
assert_eq "$(applies_count)" 0 "api rbac: nothing applied"
assert_eq "$(has "$OUT" 'ERROR:.*openchoreo')" yes "api rbac: clear error names the secret"

run cosign_api_timeout "seed_cosign_secret" \
  FAKE_SECRET_DIR="$TMP/existing" FAKE_KUBE_ERR="Unable to connect to the server: dial tcp 127.0.0.1:6443: i/o timeout"
assert_eq "$([[ $RC -ne 0 ]] && echo aborted || echo ok)" aborted "api timeout: seed_cosign_secret aborts"
assert_eq "$(applies_count)" 0 "api timeout: cosign-platform nothing applied"
assert_eq "$(grep -c '^docker ' "$HLOG/calls" || true)" 0 "api timeout: cosign keygen not started"
assert_eq "$(has "$OUT" 'ERROR:.*cosign-platform')" yes "api timeout: clear error names cosign-platform"
assert_eq "$(grep -c FAKEKEEP "$HLOG/out" || true)" 0 "api timeout: no cosign secret value in the output"

# --- lab logins: console, Thunder and Harbor admin passwords from a file outside the cluster (survive task down/up) --
# Values are compared as sha256 only, so not even a failing assertion prints one.
source "$ROOT/hack/lib/portable.sh"   # sha256_file, file_group_other_perms
LAB="$TMP/lab-config"; LABF="$LAB/koorikla-platform/lab-logins.env"
LOGINS="openchoreo:thunder-admin-password:THUNDER_ADMIN_PASSWORD openchoreo:admin-user-password:OPENCHOREO_ADMIN_PASSWORD
openchoreo:developer-user-password:OPENCHOREO_DEVELOPER_PASSWORD harbor:admin-password:HARBOR_ADMIN_PASSWORD"
hs() { printf '%s' "$1" > "$TMP/hs"; sha256_file "$TMP/hs"; }
file_val() { sed -n "s/^$1=//p" "$LABF"; }
# check_logins <name>: every applied lab login equals its file line, reaches neither the output nor an argv, and the
# file has one line per login. Sets HASHES to the sha256 of the applied values.
check_logins() {
  local l s k v a
  HASHES=""
  for l in $LOGINS; do
    IFS=: read -r s k v <<<"$l"
    a=$(val "$s" "$k")
    assert_match "$a" '^[A-Za-z0-9!]{24,}$' "$1: $s/$k seeded"
    assert_eq "$(hs "$a")" "$(hs "$(file_val "$v")")" "$1: $s/$k = $v in the file"
    assert_eq "$(grep -c "^$v=" "$LABF" || true)" 1 "$1: one $v line"
    assert_eq "$(grep -cF -- "$a" "$HLOG/out" || true)" 0 "$1: $v not in the output"
    assert_eq "$(grep -cF -- "$a" "$HLOG/calls" || true)" 0 "$1: $v not in any argv"
    HASHES="$HASHES $(hs "$a")"
  done
}
run lab_create "$S" NO_GH=1 XDG_CONFIG_HOME="$LAB"
assert_eq "$RC" 0 "lab logins: rc"
assert_eq "$([[ -f "$LABF" ]] && echo created || echo missing)" created "lab logins: missing file created under XDG_CONFIG_HOME"
[[ "$(os_name)" == windows ]] || assert_eq "$(file_group_other_perms "$LABF")" "------" "lab logins: file mode 600"
assert_match "$OUT" "lab logins: created $LABF" "lab logins: creation names the path"
assert_match "$OUT" "Harbor admin passwords: $LABF" "lab logins: secrets output names the path"
check_logins lab_create; first=$HASHES
assert_match "$(val harbor admin-password)" '[[:upper:]]' "lab logins: Harbor policy (upper)"
assert_match "$(val harbor admin-password)" '[[:digit:]]' "lab logins: Harbor policy (digit)"
assert_match "$(val harbor admin-password)" '[[:lower:]]' "lab logins: Harbor policy (lower)"
file1=$(sha256_file "$LABF")
# A clean rebuild (empty store): the same file, byte for byte, and the same values seeded.
run lab_rebuild "$S" NO_GH=1 XDG_CONFIG_HOME="$LAB"
assert_eq "$(sha256_file "$LABF")" "$file1" "lab logins: existing file reused byte for byte"
check_logins lab_rebuild
assert_eq "$HASHES" "$first" "lab logins: rebuild seeds the same passwords"
assert_eq "$(has "$OUT" 'lab logins: created')" no "lab logins: no second creation"
# The file wins over the store; a login missing from the file is appended, existing lines are kept as they are.
mkdir -p "$TMP/lab-store"
printf 'apiVersion: v1\nkind: Secret\nmetadata: { name: openchoreo }\ndata:\n  thunder-admin-password: %s\n  developer-user-password: %s\n' \
  "$(b64 FAKEKEEPSTORE1)" "$(b64 FAKEKEEPSTORE2)" > "$TMP/lab-store/openchoreo.yaml"
grep -v '^OPENCHOREO_DEVELOPER_PASSWORD=' "$LABF" > "$TMP/lab-partial"; cp "$TMP/lab-partial" "$LABF"
run lab_partial "seed_openchoreo_secret" XDG_CONFIG_HOME="$LAB" FAKE_SECRET_DIR="$TMP/lab-store"
assert_eq "$(hs "$(val openchoreo thunder-admin-password)")" "$(hs "$(file_val THUNDER_ADMIN_PASSWORD)")" "lab logins: file wins over the store"
assert_eq "$(file_val OPENCHOREO_DEVELOPER_PASSWORD)" FAKEKEEPSTORE2 "lab logins: missing line adopts the running stack's value"
sed '$d' "$LABF" > "$TMP/lab-head"
assert_eq "$(sha256_file "$TMP/lab-head")" "$(sha256_file "$TMP/lab-partial")" "lab logins: existing lines untouched (append only)"
# First run against a running stack: the file adopts the store's passwords, so nothing changes under Thunder.
rm -rf "$LAB"
run lab_adopt "seed_openchoreo_secret" XDG_CONFIG_HOME="$LAB" FAKE_SECRET_DIR="$TMP/lab-store"
assert_eq "$(file_val THUNDER_ADMIN_PASSWORD)" FAKEKEEPSTORE1 "lab logins: new file adopts the store's value"
assert_eq "$(val openchoreo thunder-admin-password)" FAKEKEEPSTORE1 "lab logins: adopted value seeded unchanged"
assert_eq "$(grep -c 'lab logins: created' "$HLOG/out" || true)" 1 "lab logins: adoption creates the file once"

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

# --- provider byo: platform store key byo-<name> (seed_byo_kubeconfigs) -----------------------------------------------
BYOF="$R/installations/local/clusters/zz-byotest.yaml"
printf 'name: byo-test\nprovider: byo\nenvironment: development\n' > "$BYOF"
KC="$TMP/byo.kubeconfig"
printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://0.0.0.0:41234\n    certificate-authority-data: Q0E=\nusers:\n- name: u\n  user:\n    token: FAKEKEEPBYOTOKEN\n' > "$KC"
run byo_file "seed_byo_kubeconfigs" BYO_KUBECONFIG_BYO_TEST="$KC"
assert_eq "$RC" 0 "byo file: rc"
assert_eq "$(keys byo-byo-test)" kubeconfig "byo file: key byo-<name>, property kubeconfig"
assert_eq "$(val byo-byo-test kubeconfig)" "$(cat "$KC")" "byo file: kubeconfig as given"
assert_eq "$(has "$OUT" 'from .BYO_KUBECONFIG_BYO_TEST')" yes "byo file: names its source"
run byo_k3d "seed_byo_kubeconfigs" FAKE_K3D_KUBECONFIG="$KC" FAKE_K3D_IP=172.18.0.99
assert_eq "$(val byo-byo-test kubeconfig | yq -r '.clusters[0].cluster.server')" https://172.18.0.99:6443 "byo k3d: API server = node IP on network kind"
assert_eq "$(val byo-byo-test kubeconfig | yq -r '.users[0].user.token')" FAKEKEEPBYOTOKEN "byo k3d: credentials kept"
run byo_k3d_nonet "seed_byo_kubeconfigs" FAKE_K3D_KUBECONFIG="$KC" FAKE_K3D_IP=
assert_eq "$RC" 1 "byo k3d off network kind: fails"
assert_eq "$(has "$OUT" 'not on docker network kind')" yes "byo k3d off network kind: says why"
run byo_none "seed_byo_kubeconfigs"
assert_eq "$RC" 0 "byo unseeded: not fatal"
assert_eq "$(applied byo-byo-test)" "" "byo unseeded: nothing applied"
assert_eq "$(has "$OUT" 'byo-byo-test: no .BYO_KUBECONFIG_BYO_TEST and no k3d cluster byo-test')" yes "byo unseeded: warns"
rm -f "$BYOF"

# --- github-login: OAuth App files + stable @strong Dex<->Thunder secret --------------------------------------------
GHL="$TMP/ghlogin-cfg"; GHL_DIR="$GHL/koorikla-platform"
run ghlogin_missing "seed_github_login_secret" XDG_CONFIG_HOME="$GHL"
assert_eq "$RC" 0 "github-login missing: rc"
assert_eq "$(applied github-login)" "" "github-login missing: nothing applied"
assert_match "$OUT" 'skipping GitHub login' "github-login missing: one-line note"
mkdir -p "$GHL_DIR"
printf '{"client_id":"Ov23liTestClient","owner":"Sparky-stack","redirect_uri":"http://dex.openchoreo.localhost:8080/callback"}\n' > "$GHL_DIR/github-login.json"
printf 'GHLOGINFakeSec999\n' > "$GHL_DIR/github-login.secret"
chmod 600 "$GHL_DIR/github-login.secret"
run ghlogin_seed "seed_github_login_secret" XDG_CONFIG_HOME="$GHL"
assert_eq "$RC" 0 "github-login present: rc"
assert_eq "$(keys github-login)" "github-client-id,github-client-secret,thunder-client-secret" "github-login: keys"
assert_eq "$(val github-login github-client-id)" Ov23liTestClient "github-login: client_id from json"
assert_eq "$(val github-login github-client-secret)" GHLOGINFakeSec999 "github-login: client_secret from secret file"
dex1=$(val github-login thunder-client-secret)
assert_match "$dex1" '^Px9![A-Za-z0-9]{24}$' "github-login: thunder-client-secret is @strong"
assert_eq "$(grep -cF -- "$dex1" "$HLOG/out" || true)" 0 "github-login: dex secret never in output"
assert_eq "$(grep -cF -- "$dex1" "$HLOG/calls" || true)" 0 "github-login: dex secret never in argv"
assert_eq "$(has "$OUT" 'group/others')" no "github-login: mode 600 secret file has no mode warning"
# Clean rebuild (empty store): same thunder-client-secret from lab-logins.env.
run ghlogin_rebuild "seed_github_login_secret" XDG_CONFIG_HOME="$GHL" FAKE_SECRET_DIR="$TMP/empty"
assert_eq "$(hs "$(val github-login thunder-client-secret)")" "$(hs "$dex1")" "github-login: rebuild keeps same dex secret"
# Root app parameter secrets.githubLogin.enabled follows platform-secrets/github-login.
mkdir -p "$TMP/ghlogin-seeded"; printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: github-login\n' > "$TMP/ghlogin-seeded/github-login.yaml"
ghl_param() { printf '%s\n' "$OUT" | yq -r '.spec.source.helm.parameters // [] | map(select(.name == "secrets.githubLogin.enabled")) | .[0].value // "none"'; }
run root_ghl_on "root_app_manifest" FAKE_SECRET_DIR="$TMP/ghlogin-seeded"
assert_eq "$(ghl_param)" true "root app: github-login seeded -> secrets.githubLogin.enabled=true"
run root_ghl_off "root_app_manifest" FAKE_SECRET_DIR="$TMP/empty"
assert_eq "$(ghl_param)" false "root app: no github-login -> secrets.githubLogin.enabled=false"
yq -i '.secrets.githubLogin.enabled = false' "$LOCAL_INST"
run root_ghl_forced "root_app_manifest" FAKE_SECRET_DIR="$TMP/ghlogin-seeded"
assert_eq "$(ghl_param)" false "root app: installation.yaml false wins over seeded github-login"
nra true

finish
