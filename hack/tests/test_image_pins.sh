#!/usr/bin/env bash
# Contract (docs/conventions.md invariant 9 + "Current practice only": images fully qualified, pinned by digest): every
# image this repo renders - every installation, every addon on every cluster it would run on, opt-in addons included,
# plus the CAPD node and k3d mgmt node images (hack/image-audit.sh --list --rendered --opt-in, the same renderer as the
# ApplicationSets) - is <registry host>/<path>[:tag]@sha256:<digest>. Covered references: `image` / `*Image` keys,
# `*_IMAGE` env vars, and those keys in YAML embedded in ConfigMaps (hack/image-audit.sh extract_images).
# Not covered (runtime, not rendered here): k3s system images, CAPI provider release manifests, k3d helpers, the CAPD
# load balancer, proxies controllers create at runtime (kgateway envoy, Istio waypoints come from rendered config).
# Exceptions: PIN_EXCEPTIONS only, exact image + source; an exception that matches nothing fails (remove it).
# With RENDERED_DIR (hack/test.sh) also: no label value carries a tag@digest (charts that copy image.tag into
# app.kubernetes.io/version; the API server rejects it, kubeconform does not check label syntax).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_image_pins =="

# <image>|<source substring (hack/image-audit.sh source column)>|<why; when to remove>
PIN_EXCEPTIONS=(
  # falcosidekick chart (falco 9.2.2) `helm test` pod (hook test-success): image hardcoded, no value to override it.
  # Argo CD does not run Helm test hooks, so the pod is never created.
  "curlimages/curl|addon falco|falcosidekick helm test pod; hardcoded upstream, never created by Argo CD"
  # falco-talon chart 0.5.0: image.tag is also written into the app.kubernetes.io/version label (a tag@digest is not a
  # valid label value) and the chart has no digest field. Registry qualified, tag = chart appVersion. Remove when the
  # chart takes a digest (or stops copying the tag into the label).
  "docker.io/falcosecurity/falco-talon:0.3.0|addon falco|falco-talon chart 0.5.0 cannot render a digest"
)

# pinned <ref> -> 0 when <ref> has a registry host and a sha256 digest
PIN_RE='^([a-z0-9-]+(\.[a-z0-9-]+)+|[a-z0-9.-]+:[0-9]+|localhost)(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]{1,128})?@sha256:[0-9a-f]{64}$'
pinned() { [[ "$1" =~ $PIN_RE ]]; }

D=sha256:0000000000000000000000000000000000000000000000000000000000000000
for ok in "docker.io/library/busybox:1.37.0@$D" "quay.io/argoproj/argocd@$D" "harbor.example.test:9443/apps/x:v1@$D" \
  "localhost:5000/x@$D"; do
  if pinned "$ok"; then assert_eq ok ok "pattern accepts $ok"; else assert_eq rejected accepted "pattern accepts $ok"; fi
done
for bad in "busybox:1.37.0" "busybox@$D" "curlimages/curl@$D" "docker.io/curlimages/curl:8.22.0" \
  "docker.io/library/busybox:latest" "ghcr.io/x/y:v1@sha256:abc" "ghcr.io/x/y:v1@$D-extra"; do
  if pinned "$bad"; then assert_eq accepted rejected "pattern rejects $bad"; else assert_eq ok ok "pattern rejects $bad"; fi
done

# Inventory: one hack/image-audit.sh run per installation, in parallel (read-only; dependencies built once here).
( cd "$ROOT" && ./hack/deps.sh >/dev/null )
pids=()
for inst_dir in "$ROOT"/installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  INST=$inst bash "$ROOT/hack/image-audit.sh" --list --rendered --opt-in > "$TMP/inv-$inst.tsv" 2> "$TMP/inv-$inst.err" &
  pids+=("$!:$inst")
done
for p in "${pids[@]}"; do
  if ! wait "${p%%:*}"; then
    cat "$TMP/inv-${p#*:}.err" >&2
    assert_eq failed ok "image inventory of installation ${p#*:}"
  fi
  warns=$(grep WARN "$TMP/inv-${p#*:}.err" || true)
  assert_eq "$warns" "" "every addon renders for installation ${p#*:} (no WARN)"
done
cat "$TMP"/inv-*.tsv | tr -d '\r' > "$TMP/inventory.tsv"
assert_match "$(wc -l < "$TMP/inventory.tsv" | tr -d ' ')" '^[1-9][0-9]+$' "the inventory found images"

: > "$TMP/used"
bad=0
while IFS=$'\t' read -r img src; do
  [[ -n "$img" ]] || continue
  pinned "$img" && continue
  excepted=""
  for e in "${PIN_EXCEPTIONS[@]}"; do
    IFS='|' read -r eimg esrc _ <<<"$e"
    if [[ "$img" == "$eimg" && "$src" == *"$esrc"* ]]; then excepted=$e; echo "$e" >> "$TMP/used"; fi
  done
  [[ -n "$excepted" ]] && continue
  bad=$((bad + 1))
  printf '  FAIL: not <registry>/<path>[:tag]@sha256:<digest>: %s  (%s)\n' "$img" "$src" >&2
done < "$TMP/inventory.tsv"
assert_eq "$bad" 0 "every rendered image is fully qualified and digest-pinned (or a listed exception)"
for e in "${PIN_EXCEPTIONS[@]}"; do
  n=$(grep -cxF "$e" "$TMP/used" || true)
  if (( n > 0 )); then
    assert_eq ok ok "exception still needed: ${e%%|*}"
  else
    assert_eq stale needed "exception ${e%%|*} matches no rendered image: remove it"
  fi
done

# Label values never carry a digest (only with the renders of hack/test.sh).
if [[ -n "${RENDERED_DIR:-}" && -d "$RENDERED_DIR" ]]; then
  labels=""
  for f in "$RENDERED_DIR"/*.yaml; do
    [[ -s "$f" ]] || continue
    l=$(yq -N '.. | select(tag == "!!map" and has("labels")) | .labels | select(tag == "!!map") | to_entries[]
      | select((.value | tag) == "!!str") | select(.value | test("@")) | .key + "=" + .value' "$f" 2>/dev/null || true)
    if [[ -n "$l" ]]; then labels="$labels$(basename "$f"): $l"$'\n'; fi
  done
  assert_eq "$labels" "" "no label value contains a tag@digest (rendered manifests of hack/test.sh)"
else
  echo "  SKIP label check (needs RENDERED_DIR: run through hack/test.sh)"
fi

finish
