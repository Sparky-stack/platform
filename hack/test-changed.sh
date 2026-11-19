#!/usr/bin/env bash
# hack/test.sh for only what changed since BASE (default origin/main), committed or not: the scoping PR CI uses
# (docs/dev-environment.md#scoped-pr-ci). Shared inputs or unknown paths run the full suite (hack/changed-units.sh).
#   task test:changed            BASE=origin/release task test:changed
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

BASE=${BASE:-origin/main}
changed=$( {
  git diff --name-only "$(git merge-base "$BASE" HEAD)" HEAD
  git diff --name-only HEAD                    # uncommitted edits
  git ls-files --others --exclude-standard     # new, not yet added files
} | sort -u)
if [[ -z "$changed" ]]; then
  echo "==> nothing changed since $BASE"
  exit 0
fi

units=$(printf '%s\n' "$changed" | bash hack/changed-units.sh)
echo "==> changed since $BASE: ${units//$'\n'/ }"
if [[ "$units" == full ]]; then
  exec bash hack/test.sh
fi

echo "==> Checking Markdown links, paths and commands"
py hack/check-docs.py
[[ "$units" != docs ]] || exit 0

charts="" tests=""
for u in $units; do
  case "$u" in charts/* | addons/*) charts="$charts $u" ;; esac
done
# shellcheck disable=SC2086  # units are space-free paths
for t in $(bash hack/changed-units.sh --tests $units); do tests="$tests $t"; done
echo "==> related contract tests:${tests:- none}"

if [[ -n "$charts" ]]; then
  CHARTS="${charts# }" TESTS="${tests# }" exec bash hack/test.sh
fi
# No chart changed (packages/, ci/, templates/ only): their own workflows build them; run the related contract tests.
failed=0
for t in $tests; do bash "$t" || failed=$((failed + 1)); done
echo "$failed contract test(s) failed"
(( failed == 0 ))
