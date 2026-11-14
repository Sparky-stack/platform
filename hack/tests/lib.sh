# hack/tests/lib.sh — shared assertion helpers for bash contract tests.
# shellcheck shell=bash disable=SC2034
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (expected=%q actual=%q)\n' "$msg" "$expected" "$actual" >&2
  fi
}

assert_nonempty() {
  local val="$1" msg="$2"
  if [[ -n "$val" && "$val" != "null" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (empty)\n' "$msg" >&2
  fi
}

assert_match() {
  local val="$1" pat="$2" msg="$3"
  if [[ "$val" =~ $pat ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL: %s (value=%q did not match=%q)\n' "$msg" "$val" "$pat" >&2
  fi
}

finish() {
  echo "  $PASS passed, $FAIL failed"
  (( FAIL == 0 ))
}
