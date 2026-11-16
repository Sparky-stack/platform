#!/usr/bin/env bash
# Workflow scripts (stdlib Python run by Argo Workflows): unit tests of their pure functions and template guards.
#   addons/openchoreo-platform/files/promotion-gate/gate.py  freeze windows incl. DST, releaseName edit, endpoints, pipeline
#   addons/argo-events/files/falco_response.py               priority filter, pod -> OpenChoreo component mapping
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_workflow_scripts =="
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
if out=$(cd "$ROOT/addons/argo-events/files" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest -q test_falco_response 2>&1); then
  assert_eq ok ok "falco_response.py unit tests"
else
  echo "$out" >&2
  assert_eq failed ok "falco_response.py unit tests"
fi
# The ClusterWorkflow embeds gate.py in a CEL template (and Argo templates it again).
# shellcheck disable=SC2016  # literal template markers
hits=$(grep -c -e '\${' -e '{{' "$dir/gate.py" || true)
assert_eq "$hits" "0" "gate.py contains no CEL/Argo template markers"

finish
