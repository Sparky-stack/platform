#!/usr/bin/env bash
# Git hooks (prek.toml, hack/hooks.sh; docs/dev-environment.md "Git hooks"):
#   - nothing is fetched or floating: every repo is builtin/local/meta or pinned to a full commit SHA, local hooks run
#     as `system` (no hook environments, no additional_dependencies) and call only mise.toml tools or repo scripts
#   - shellcheck runs with hack/lint.sh's flags; the rule checker itself rejects floating revs (negative fixtures)
#   - gitleaks hook: fails on a secret in staged content, ignores untracked files and `gitleaks:allow` lines
#   - check-toml (prek builtin) rejects a duplicate key in mise.toml; chart-dirs mapping; commit-msg only warns
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

# tools_table from hack/tools.sh (bash 3.2: no `source <(...)`)
sed -n '/^tools_table()/,/^}/p' "$ROOT/hack/tools.sh" > "$TMP/fn.sh"
tools=$(cd "$ROOT" && FN="$TMP/fn.sh" bash -c '. "$FN"; tools_table' | awk '{ print $1 }' | tr '\n' ' ')

# check_config <prek.toml> <repo root>: one line per violation, nothing when the config is clean.
check_config() {
  py - "$1" "$2" "$tools" <<'EOF'
import os, re, shlex, sys
try:
    import tomllib
except ImportError:
    print("python >= 3.11 needed for tomllib"); sys.exit(0)
path, root, tools = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
with open(path, "rb") as f:
    cfg = tomllib.load(f)
for r in cfg.get("repos", []):
    repo = r.get("repo", "")
    if repo in ("builtin", "meta"):
        continue
    if repo != "local":
        if not re.fullmatch(r"[0-9a-f]{40}", str(r.get("rev", ""))):
            print(f"{repo}: rev {r.get('rev')!r} is not a full commit SHA")
        continue
    for h in r.get("hooks", []):
        hid = h.get("id", "?")
        if h.get("language") != "system":
            print(f"{hid}: language {h.get('language')!r}, want system (tools come from mise.toml)")
        for k in ("additional_dependencies", "language_version"):
            if k in h:
                print(f"{hid}: {k} set (prek would build an environment)")
        argv = shlex.split(h.get("entry", ""))
        if not argv:
            print(f"{hid}: empty entry")
        elif argv[0] == "bash":
            if len(argv) < 2 or not os.path.isfile(os.path.join(root, argv[1])):
                print(f"{hid}: script {argv[1:2]} not in the repo")
        elif argv[0] not in tools:
            print(f"{hid}: {argv[0]} is not a mise.toml tool")
EOF
}

assert_eq "$(check_config "$ROOT/prek.toml" "$ROOT")" "" "prek.toml: every hook pinned, local hooks use mise tools / repo scripts"

cat > "$TMP/bad.toml" <<'EOF'
[[repos]]
repo = "https://github.com/pre-commit/pre-commit-hooks"
rev = "v6.0.0"
hooks = [{ id = "trailing-whitespace" }]

[[repos]]
repo = "https://github.com/gitleaks/gitleaks"
rev = "a1b2c3d"
hooks = [{ id = "gitleaks" }]

[[repos]]
repo = "https://github.com/rhysd/actionlint"
rev = "03d0035246f3e81f36aed592ffb4bebf33a03106"
hooks = [{ id = "actionlint" }]

[[repos]]
repo = "local"
hooks = [
  { id = "py", language = "python", entry = "ruff", additional_dependencies = ["ruff==0.1"] },
  { id = "curl", language = "system", entry = "curl -fsSL https://example.com/x.sh" },
  { id = "gone", language = "system", entry = "bash hack/nope.sh" },
]
EOF
bad=$(check_config "$TMP/bad.toml" "$ROOT")
assert_match "$bad" "pre-commit-hooks: rev 'v6.0.0' is not a full commit SHA" "negative: tag rev rejected"
assert_match "$bad" "gitleaks: rev 'a1b2c3d' is not a full commit SHA" "negative: short SHA rejected"
assert_eq "$(grep -c 'actionlint' <<<"$bad" || true)" "0" "full SHA rev accepted"
assert_matches "$bad" <<'CASES'
negative: managed language rejected | py: language 'python'
negative: additional_dependencies rejected | py: additional_dependencies set
negative: tool outside mise.toml rejected | curl: curl is not a mise.toml tool
negative: missing script rejected | gone: script \['hack/nope.sh'\] not in the repo
CASES

# Same shellcheck flags as hack/lint.sh (task lint)
# shellcheck disable=SC2016  # $sf is literal text in hack/lint.sh
lint_flags=$(sed -n 's/^ *shellcheck \(.*\) "\$sf"$/\1/p' "$ROOT/hack/lint.sh")
hook_flags=$(sed -n 's/^entry = "shellcheck \(.*\)"$/\1/p' "$ROOT/prek.toml")
assert_nonempty "$lint_flags" "hack/lint.sh shellcheck flags found"
assert_eq "$hook_flags" "$lint_flags" "prek shellcheck flags = hack/lint.sh"

# chart-dirs: changed files -> chart dirs for CHARTS=... hack/test.sh
dirs=$(cd "$ROOT" && bash hack/hooks.sh chart-dirs addons/cilium/values.yaml addons/cilium/templates/x.yaml \
  installations/local/addons/harbor/values.yaml charts/platform/values.yaml README.md addons/no-such-addon/x \
  | tr '\n' ' ')
assert_eq "$dirs" "addons/cilium addons/harbor charts/platform " "chart-dirs maps chart, overlay and catalog files"
dirs=$(cd "$ROOT" && bash hack/hooks.sh chart-dirs installations/local/clusters/dev1.yaml | tr '\n' ' ')
assert_eq "$dirs" "charts/cluster charts/platform " "cluster file selects charts/platform + charts/cluster"

# commit-msg: warn only
printf 'feat(cluster): add x\n\n# comment\n' > "$TMP/msg-ok"
printf '# comment\nupdated stuff\n' > "$TMP/msg-bad"
printf "Merge branch 'main' into agent/x\n" > "$TMP/msg-merge"
out=$(cd "$ROOT" && bash hack/hooks.sh commit-msg "$TMP/msg-ok" 2>&1); rc=$?
assert_eq "$rc:$out" "0:" "conventional subject passes silently"
out=$(cd "$ROOT" && bash hack/hooks.sh commit-msg "$TMP/msg-bad" 2>&1); rc=$?
assert_eq "$rc" "0" "non-conventional subject does not block"
assert_match "$out" "WARN: commit subject is not a conventional commit.*updated stuff" "non-conventional subject warns"
out=$(cd "$ROOT" && bash hack/hooks.sh commit-msg "$TMP/msg-merge" 2>&1)
assert_eq "$out" "" "merge subject passes silently"

# A scratch repo with the hook scripts, for the gitleaks and prek checks below.
repo="$TMP/repo"
mkdir -p "$repo/hack/lib"
cp "$ROOT/hack/hooks.sh" "$repo/hack/"
cp "$ROOT/hack/lib/portable.sh" "$repo/hack/lib/"
cp "$ROOT/prek.toml" "$repo/"
: > "$repo/.gitleaksignore"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" config core.autocrlf false

if command -v gitleaks >/dev/null 2>&1; then
  # A GitHub token shape built at runtime, so this file itself holds no secret.
  tok="ghp_$(printf 'Zq8WmR2xKp4LbN7vT1cY9dHs3FgJ6uEa0iOw' | cut -c1-36)"
  printf 'token: %s\n' "$tok" > "$repo/leak.yaml"
  printf 'clean: true\n' > "$repo/clean.yaml"
  git -C "$repo" add clean.yaml leak.yaml
  out=$(cd "$repo" && bash hack/hooks.sh gitleaks clean.yaml leak.yaml 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" "1" "negative: gitleaks fails on a staged token"
  assert_match "$out" "File: +leak.yaml" "negative: finding reported with the repo-relative path"
  # Staged content is what counts: the worktree copy may already be clean.
  printf 'token: redacted\n' > "$repo/leak.yaml"
  out=$(cd "$repo" && bash hack/hooks.sh gitleaks leak.yaml 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" "1" "negative: gitleaks scans the index, not the worktree"
  assert_match "$out" "leaks found: 1" "negative: index copy holds the leak"
  git -C "$repo" add leak.yaml
  printf 'token: %s\n' "$tok" > "$repo/untracked.kubeconfig"
  if (cd "$repo" && bash hack/hooks.sh gitleaks clean.yaml leak.yaml >/dev/null 2>&1); then rc=0; else rc=1; fi
  assert_eq "$rc" "0" "clean staged files pass; untracked files are not scanned"
  printf 'token: %s   # gitleaks:allow\n' "$tok" > "$repo/allowed.yaml"
  git -C "$repo" add allowed.yaml
  if (cd "$repo" && bash hack/hooks.sh gitleaks allowed.yaml >/dev/null 2>&1); then rc=0; else rc=1; fi
  assert_eq "$rc" "0" "gitleaks:allow line passes"
  if command -v mise >/dev/null 2>&1; then
    # A commit touching mise.toml: the temp copy holds an untrusted mise.toml; a mise shim run there fails.
    cp "$ROOT/mise.toml" "$repo/mise.toml"
    git -C "$repo" add mise.toml
    out=$(cd "$repo" && MISE_TRUSTED_CONFIG_PATHS="$repo" bash hack/hooks.sh gitleaks mise.toml 2>&1) && rc=0 || rc=$?
    assert_eq "$rc" "0" "gitleaks hook passes on a staged mise.toml ($out)"
    git -C "$repo" rm -q --cached mise.toml; rm -f "$repo/mise.toml"
  fi
else
  echo "  SKIP gitleaks checks: gitleaks not on PATH (mise install)"
fi

if command -v prek >/dev/null 2>&1; then
  out=$(cd "$ROOT" && prek validate-config prek.toml 2>&1) && rc=0 || rc=1
  assert_eq "$rc" "0" "prek validate-config prek.toml ($out)"
  # The duplicate-key merge that once broke mise.toml must not get past check-toml.
  printf '[tools]\nhelm = "4.3.2"\nhelm = "4.3.1"\n' > "$repo/mise.toml"
  git -C "$repo" add mise.toml prek.toml hack
  if (cd "$repo" && PREK_HOME="$TMP/prek-home" prek run check-toml --files mise.toml >/dev/null 2>&1); then rc=0; else rc=1; fi
  assert_eq "$rc" "1" "negative: check-toml rejects a duplicate key in mise.toml"
else
  echo "  SKIP prek checks: prek not on PATH (mise install)"
fi

finish
