#!/usr/bin/env bash
# Git hook commands behind prek.toml (task hooks:install / task hooks:run; docs/dev-environment.md "Git hooks").
# prek passes the matching files: the staged ones on `git commit`, every tracked one with --all-files (CI).
#   hack/hooks.sh gitleaks <file>...     secrets in the staged (index) content of the files
#   hack/hooks.sh py-compile <file>...   Python syntax (python -m py_compile without writing .pyc files)
#   hack/hooks.sh chart-lock <file>...   Chart.lock in sync with Chart.yaml for the charts the files belong to
#   hack/hooks.sh charts <file>...       helm lint + template + kubeconform (+ helm unittest) for those charts only,
#                                        via `CHARTS=... hack/test.sh` (same rendering as `task test`)
#   hack/hooks.sh commit-msg <msg-file>  warn (never fail) when the subject is not a conventional commit
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

# chart_dirs <file>...: the chart dirs (charts/<c>, addons/<a>) the files belong to, sorted, one per line. An
# installation's addon overlay (installations/<i>/addons/<a>/...) selects addons/<a>; installation and cluster files
# select charts/platform and charts/cluster (every addon renders with them too; `task test` / CI cover that).
chart_dirs() {
  local f d r
  for f in "$@"; do   # parameter expansion only: a subprocess per file is slow on Windows with --all-files
    case "$f" in
      charts/*/* | addons/*/*) r=${f#*/}; d=${f%%/*}/${r%%/*} ;;
      installations/*/addons/*/*) r=${f#installations/*/addons/}; d=addons/${r%%/*} ;;
      installations/*/installation.yaml | installations/*/clusters/*) printf '%s\n' charts/platform charts/cluster; continue ;;
      *) continue ;;
    esac
    if [[ -f "$d/Chart.yaml" ]]; then printf '%s\n' "$d"; fi
  done | sort -u
}

cmd_gitleaks() {
  local tmp ignore bin rc=0
  (( $# > 0 )) || return 0
  command -v gitleaks >/dev/null 2>&1 || { echo "gitleaks not on PATH: run 'mise install'" >&2; return 1; }
  # The real binary, resolved here in the (trusted) checkout: a mise shim run inside the temp copy below would read the
  # staged mise.toml there, which mise refuses as an untrusted config whenever a commit touches mise.toml.
  bin=$(mise which gitleaks 2>/dev/null) || bin=$(command -v gitleaks)
  # Scan what is about to be committed: the index copy of each file (git checkout-index), so partially staged files
  # are checked as staged, and untracked/ignored files (kubeconfigs, .env) never trip the hook. Paths stay
  # repo-relative, so .gitleaksignore fingerprints (<file>:<rule>:<line>) and `gitleaks:allow` comments apply.
  tmp=$(mktemp -d)
  printf '%s\0' "$@" | git checkout-index -z --stdin --force --prefix="$(native_path "$tmp")/"
  ignore=$(native_path "$ROOT/.gitleaksignore")
  (cd "$tmp" && "$bin" dir . --no-banner --redact --verbose --gitleaks-ignore-path "$ignore") || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

cmd_py_compile() {
  (( $# > 0 )) || return 0
  # compile() is what py_compile runs; skipping the .pyc keeps the worktree clean.
  py -c 'import sys
bad = 0
for f in sys.argv[1:]:
    try:
        with open(f, "rb") as fh:
            compile(fh.read(), f, "exec")
    except (SyntaxError, ValueError) as e:
        print(f"{f}: {e}")
        bad = 1
sys.exit(bad)' "$@"
}

cmd_chart_lock() {
  local dirs=() d
  read_lines dirs chart_dirs "$@"
  local locked=()
  for d in ${dirs[@]+"${dirs[@]}"}; do
    if grep -q '^dependencies:' "$d/Chart.yaml"; then locked+=("$d"); fi
  done
  (( ${#locked[@]} > 0 )) || return 0
  if [[ ! -f hack/lib/chartlock.py ]]; then
    # The offline Chart.lock digest check (helm's own hash) lands with hack/lib/chartlock.py; until then `task test`
    # catches a stale lock on a clean checkout (helm dependency build refuses it).
    echo "SKIP chart-lock: hack/lib/chartlock.py not on this branch yet (${#locked[@]} chart(s) with dependencies)"
    return 0
  fi
  py hack/lib/chartlock.py "${locked[@]}"
}

cmd_charts() {
  local dirs=()
  read_lines dirs chart_dirs "$@"
  (( ${#dirs[@]} > 0 )) || return 0
  echo "==> hack/test.sh for: ${dirs[*]}"
  CHARTS="${dirs[*]}" "${BASH:-bash}" hack/test.sh
}

# Conventional Commits 1.0 subject: type(scope)!: description. Squash merges make the PR title the commit on main,
# so branch commits only get a warning; git's own merge/revert/fixup subjects pass.
cmd_commit_msg() {
  local subject
  subject=$(tr -d '\r' < "${1:?usage: hooks.sh commit-msg <file>}" | awk '!/^#/ && NF && s == "" { s = $0 } END { print s }')
  case "$subject" in
    "Merge "* | "Revert \""* | "fixup! "* | "squash! "* | "amend! "* | "") return 0 ;;
  esac
  if ! printf '%s\n' "$subject" \
    | grep -Eq '^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([[:alnum:]_./,-]+\))?!?: [^[:space:]]'; then
    echo "WARN: commit subject is not a conventional commit (AGENTS.md): $subject" >&2
    echo "      expected: <type>(<scope>): <description>, type one of build chore ci docs feat fix perf refactor revert style test" >&2
  fi
  return 0
}

cmd=${1:-}
shift || true
case "$cmd" in
  gitleaks) cmd_gitleaks "$@" ;;
  py-compile) cmd_py_compile "$@" ;;
  chart-lock) cmd_chart_lock "$@" ;;
  charts) cmd_charts "$@" ;;
  commit-msg) cmd_commit_msg "$@" ;;
  chart-dirs) chart_dirs "$@" ;;
  *) echo "usage: $0 gitleaks|py-compile|chart-lock|charts|commit-msg|chart-dirs <file>..." >&2; exit 2 ;;
esac
