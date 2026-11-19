#!/usr/bin/env bash
# Workflow scripts (stdlib Python run by Argo Workflows): unit tests of their pure functions and template guards.
#   addons/openchoreo-platform/files/promotion-gate/gate.py  freeze windows incl. DST, releaseName edit, endpoints, pipeline
#   addons/argo-events/files/falco_response.py               priority filter, pod -> OpenChoreo component mapping
#   addons/openchoreo-platform/files/auto-build/auto_build.py one WorkflowRun per commit, GitOps hand-off not rebuilt,
#                                                             restarts/lost cache/redelivery never build twice (#164)
#   addons/argo-events WorkflowTemplate falco-response        the Falco event (tenant-controlled text) and what enrich
#                                                             derives from it reach steps only as env, never as code
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

# falco-response (docs/observability.md "Falco response"): the event is a Falco alert whose output fields tenants control
# (command lines), so `{{`/`{{=` in it is possible. Steps get it (and the enrich result) only as env values; in source,
# args or command Argo would template it into code.
event_in_code() {   # event_in_code <rendered falco-response.yaml> -> offending template names, one per line
  yq -N 'select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.script or .container)
    | {"name": .name, "code": ((.script // .container) | del(.env) | tostring)}
    | select(.code | test("workflow\\.parameters\\.event|inputs\\.parameters\\.context")) | .name' "$1"
}
helm template argo-events "$ROOT/addons/argo-events" --namespace argo-events --set workflowPlane=true \
  -s templates/falco-response.yaml > "$TMP/falco-response.yaml"
assert_nonempty "$(yq -N 'select(.kind == "WorkflowTemplate") | .metadata.name' "$TMP/falco-response.yaml")" \
  "WorkflowTemplate falco-response renders"
assert_eq "$(event_in_code "$TMP/falco-response.yaml")" "" "falco-response passes the event to steps only as env"
# shellcheck disable=SC2016  # literal Argo template marker
yq '(select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.name == "enrich") | .script.source) |=
  . + " {{workflow.parameters.event}}"' "$TMP/falco-response.yaml" > "$TMP/falco-response-bad.yaml"
assert_eq "$(event_in_code "$TMP/falco-response-bad.yaml")" "enrich" "negative: the event spliced into a script source is caught"
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
if out=$(cd "$ROOT/addons/openchoreo-platform/files/auto-build" && PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m unittest -q test_auto_build 2>&1); then
  assert_eq ok ok "auto_build.py unit tests"
else
  echo "$out" >&2
  assert_eq failed ok "auto_build.py unit tests"
fi
# shellcheck disable=SC2016  # literal template marker
hits=$(grep -c -e '{{' "$ROOT/addons/openchoreo-platform/files/auto-build/auto_build.py" || true)
assert_eq "$hits" "0" "auto_build.py contains no Argo template markers"
# The ClusterWorkflow embeds gate.py in a CEL template (and Argo templates it again).
# shellcheck disable=SC2016  # literal template markers
hits=$(grep -c -e '\${' -e '{{' "$dir/gate.py" || true)
assert_eq "$hits" "0" "gate.py contains no CEL/Argo template markers"

finish
