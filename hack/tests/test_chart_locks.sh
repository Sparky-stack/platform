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
# Behaviour, not text: deps.sh on a scratch tree with one stale lock and a warm charts/ cache exits 1 before any
# network call (repo registration and builds come after the lock check).
rm -rf "$TMP/tree"; mkdir -p "$TMP/tree/hack/lib" "$TMP/tree/addons" "$TMP/tree/charts"
cp hack/deps.sh "$TMP/tree/hack/"; cp hack/lib/portable.sh hack/lib/chartlock.py "$TMP/tree/hack/lib/"
cp -R addons/external-dns "$TMP/tree/addons/"; mkdir -p "$TMP/tree/addons/external-dns/charts"
yq -i 'del(.dependencies[0].condition)' "$TMP/tree/addons/external-dns/Chart.yaml"
# A no-op helm on PATH: if deps.sh skipped the check it would "succeed" offline instead of failing.
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/helm"; chmod +x "$TMP/bin/helm"
out=$(PATH="$TMP/bin:$PATH" bash "$TMP/tree/hack/deps.sh" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "deps.sh fails on a stale lock even with a warm charts/ cache"
assert_match "$out" 'deps: Chart.lock out of sync' "deps.sh names the stale lock"

finish
