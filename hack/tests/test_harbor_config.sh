#!/usr/bin/env bash
# addons/harbor files/harbor-config.py against an in-memory fake Harbor API (hack/tests/harbor_config_mock.py), with
# the desired state the chart renders: creates everything, idempotent on re-run, robot secrets from env, no secret in
# the output, 401 on wrong admin credentials.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_harbor_config =="
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
pick_python || { echo "  SKIP: python3 not found"; exit 0; }
./hack/deps.sh >/dev/null 2>&1 || true
helm template harbor addons/harbor --namespace harbor --values installations/local/installation.yaml \
  --set harbor.externalURL=https://harbor.openchoreo.localhost:9443 \
  | yq 'select(.kind == "ConfigMap" and .data["state.json"]) | .data["state.json"]' > "$TMP/state.json"
assert_nonempty "$(cat "$TMP/state.json")" "chart renders state.json"
if py hack/tests/harbor_config_mock.py addons/harbor/files/harbor-config.py "$TMP/state.json"; then
  assert_eq ok ok "harbor-config.py mock-API smoke test"
else
  assert_eq failed ok "harbor-config.py mock-API smoke test"
fi
find addons/harbor -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
finish
