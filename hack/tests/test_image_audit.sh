#!/usr/bin/env bash
# hack/image-audit.sh helpers, offline: the deliberate multi-arch exception list (ARCH_EXCEPTIONS: prefix + expiry,
# nothing broader) and the shared renderer's installationParameters (hack/lib/addons.sh: Helm-evaluated, no regex).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_image_audit =="
# shellcheck source=../image-audit.sh
source "$ROOT/hack/image-audit.sh"

H=docker.io/goharbor/harbor-core:v2.15.4@sha256:7d2ba5304a729887cdec7cb222a82b500278423de230ae5150c386a6c332b112
assert_match "$(TODAY=2026-11-14 arch_exception "$H")" '^ok:Harbor 2\.15 .*until 2027-' "Harbor 2.15 image excepted"
assert_eq "$(TODAY=2099-01-01 arch_exception "$H")" "expired:2027-03-31" "exception expires (audit fails again)"
assert_eq "$(TODAY=2026-11-14 arch_exception docker.io/goharbor/harbor-core:v2.16.0)" "" "a Harbor bump drops the exception"
assert_eq "$(TODAY=2026-11-14 arch_exception docker.io/goharbor/harbor-core:v2.150.0)" "" "prefix ends in a dot: v2.150 is not v2.15.x"
assert_eq "$(TODAY=2026-11-14 arch_exception docker.io/library/python:3.14.10-alpine3.24)" "" "other images get no exception"
assert_eq "$(TODAY=2026-11-14 arch_exception docker.io/evil/harbor-core:v2.15.4)" "" "only the goharbor repositories"
assert_eq "${#ARCH_EXCEPTIONS[@]}" 8 "exactly the 8 Harbor images are excepted"
for e in "${ARCH_EXCEPTIONS[@]}"; do
  IFS='|' read -r prefix exp why <<<"$e"
  assert_match "$prefix" '^docker\.io/goharbor/[a-z-]+:v2\.15\.$' "exception $prefix is pinned to a Harbor 2.15 tag prefix"
  assert_match "$exp" '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$' "exception $prefix has an expiry date"
  assert_match "$why" 'remove at' "exception $prefix says when to remove it"
done
# every excepted image is documented as a deliberate exception
assert_match "$(cat "$ROOT/docs/build-plane.md")" 'ARCH_EXCEPTIONS' "docs/build-plane.md documents the exception list"

# installationParameters: one renderer (hack/lib/addons.sh), templates evaluated by Helm in the ApplicationSet.
# shellcheck source=../lib/addons.sh
( cd "$ROOT" && source hack/lib/addons.sh
  printf 'registry:\n  type: harbor\n  host: harbor.example.test:9443\nopenchoreo:\n  observability:\n    enabled: true\n  workflowPlane:\n    enabled: false\n' > "$TMP/inst.yaml"
  helm template platform charts/platform --namespace argocd --values "$TMP/inst.yaml" > "$TMP/platform.yaml"
  addon_installation_params "$TMP/platform.yaml" harbor > "$TMP/harbor.params"
  addon_installation_params "$TMP/platform.yaml" openchoreo-control-plane > "$TMP/ocp.params" )
assert_eq "$(cat "$TMP/harbor.params")" $'harbor.externalURL\thttps://harbor.example.test:9443' "installationParameters: embedded reference"
assert_match "$(cat "$TMP/ocp.params")" $'observability.enabled\ttrue' "installationParameters: nested path"
assert_match "$(cat "$TMP/ocp.params")" $'workflows.enabled\tfalse' "installationParameters: second parameter, other value"
assert_eq "$(grep -c . "$TMP/ocp.params")" 2 "installationParameters: one line per catalog entry"
assert_eq "$(grep -c 'eval_param' "$ROOT/hack/image-audit.sh" || true)" 0 "image-audit has no private template resolver"

finish
