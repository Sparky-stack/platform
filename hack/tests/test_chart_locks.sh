#!/usr/bin/env bash
# Every Chart.lock matches its Chart.yaml (helm's digest, hack/lib/chartlock.py), so `helm dependency build` works on
# a clean checkout and in Argo CD's repo-server even when the local charts/ cache would hide a stale lock.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/hack/lib/portable.sh"

echo "== test_chart_locks =="
cd "$ROOT"
dirs=()
for d in charts/* addons/*; do
  if [[ -f "$d/Chart.yaml" ]] && grep -q '^dependencies:' "$d/Chart.yaml"; then dirs+=("$d"); fi
done
out=$(py hack/lib/chartlock.py "${dirs[@]}" 2>&1) && rc=0 || rc=$?
assert_eq "$rc:$out" "0:" "every Chart.lock in sync with its Chart.yaml (${#dirs[@]} charts)"

# Negative: a Chart.yaml edit after the lock (the PR #5 regression: a condition added) is caught, and so is a missing
# lock; restoring the field brings it back in sync.
mk() { rm -rf "$TMP/c"; mkdir -p "$TMP/c"; cp addons/external-dns/Chart.yaml addons/external-dns/Chart.lock "$TMP/c/"; }
mk; yq -i 'del(.dependencies[0].condition)' "$TMP/c/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'out of sync' "dropping a dependency condition is detected"
mk; yq -i '.dependencies[0].version = "0.0.1"' "$TMP/c/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'out of sync' "a version bump without a lock update is detected"
mk; rm "$TMP/c/Chart.lock"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'without a Chart.lock' "a missing lock is detected"
mk
assert_eq "$(py hack/lib/chartlock.py "$TMP/c"; echo $?)" "0" "unchanged copy stays in sync"
# deps.sh runs the check before its cache skip
assert_match "$(cat hack/deps.sh)" 'chartlock.py' "hack/deps.sh checks locks before skipping cached charts"

finish
