#!/usr/bin/env bash
# Promotion gate script (addons/openchoreo-platform/files/promotion-gate/gate.py): Python unit tests of its pure
# functions (freeze windows incl. DST, releaseName edit, endpoint URLs, pipeline lookup) and the templating guard.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_promotion_gate =="
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
# The ClusterWorkflow embeds gate.py in a CEL template (and Argo templates it again).
# shellcheck disable=SC2016  # literal template markers
hits=$(grep -c -e '\${' -e '{{' "$dir/gate.py" || true)
assert_eq "$hits" "0" "gate.py contains no CEL/Argo template markers"

finish
