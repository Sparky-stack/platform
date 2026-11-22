#!/usr/bin/env bash
# run-suite.sh <log dir> <unittest|contract> <path>: one suite of hack/test.sh's parallel phase (`helm unittest <chart>`
# or `bash <hack/tests/test_*.sh>`). Its output is buffered and printed in one piece when it ends (under a lock, so
# suites running side by side never interleave), headed by name, result and duration; "<seconds>\t<suite>\t<rc>" goes
# to <log dir>/results.tsv for the summary and the timing table. Always exits 0: hack/test.sh counts the failures.
set -uo pipefail
logs=$1 kind=$2 path=$3
case "$kind" in
  unittest) name="helm unittest $path"; cmd=(helm unittest "$path") ;;
  contract) name=$path; cmd=(bash "$path") ;;
  *) echo "run-suite.sh: unknown suite kind $kind" >&2; exit 2 ;;
esac
log=$(mktemp "$logs/suite.XXXXXX")
SECONDS=0
"${cmd[@]}" > "$log" 2>&1
rc=$?
secs=$SECONDS
if (( rc == 0 )); then result=ok; else result="FAILED (exit $rc)"; fi

until mkdir "$logs/lock" 2>/dev/null; do sleep 0.1; done
printf '==> %s: %s, %ss\n' "$name" "$result" "$secs"
cat "$log"
printf '%s\t%s\t%s\n' "$secs" "$name" "$rc" >> "$logs/results.tsv"
rmdir "$logs/lock"
rm -f "$log"
