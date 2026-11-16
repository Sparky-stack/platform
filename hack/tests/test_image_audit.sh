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

# extract_images: image keys, *Image keys, *_IMAGE env vars and YAML embedded in ConfigMap data (Argo Events keeps the
# EventBus images there); a ConfigMap script that merely mentions "image:" must not abort the extraction.
cat > "$TMP/render.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: { name: script }
data:
  run.sh: |
    echo "image: {{ broken"   # not YAML
    [ unbalanced
---
apiVersion: v1
kind: ConfigMap
metadata: { name: controller }
data:
  controller-config.yaml: |
    eventBus:
      jetstream:
        versions:
          - version: "2.10.29"
            natsImage: docker.io/library/nats:2.10.29
            configReloaderImage: docker.io/natsio/nats-server-config-reloader:0.14.0
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: d }
spec:
  template:
    spec:
      containers:
        - name: c
          image: quay.io/argoproj/argo-events:v1.9.11
          imagePullPolicy: IfNotPresent
          env:
            - { name: ARGO_EVENTS_IMAGE, value: quay.io/argoproj/argo-events:v1.9.11 }
            - { name: OTHER, value: not-an-image }
YAML
got=$(extract_images < "$TMP/render.yaml" | sort -u | tr '\n' ' ')
assert_eq "$got" "docker.io/library/nats:2.10.29 docker.io/natsio/nats-server-config-reloader:0.14.0 quay.io/argoproj/argo-events:v1.9.11 " \
  "extract_images: image, *Image keys in embedded ConfigMap YAML, *_IMAGE env; broken script ignored"

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


# enabled: catalog default / cluster toggle / --opt-in (OPT_IN)
CATALOG="$TMP/catalog.yaml"
printf 'addons:\n  on: { default: true }\n  off: { default: false }\n  plain: { namespace: x }\n' > "$CATALOG"
st() { if OPT_IN=$1 enabled "$2" "$3"; then echo on; else echo off; fi; }
assert_eq "$(st 0 on null)" on "enabled: default-true addon is on"
assert_eq "$(st 0 plain null)" on "enabled: no default = on"
assert_eq "$(st 0 on false)" off "enabled: cluster toggle false wins"
assert_eq "$(st 0 off null)" off "enabled: opt-in addon off without a toggle (default false is not read as empty)"
assert_eq "$(st 0 off true)" on "enabled: opt-in addon on with toggle true"
assert_eq "$(st 1 off null)" on "enabled: --opt-in renders opt-in addons"
assert_eq "$(st 1 off false)" off "enabled: --opt-in keeps an explicit false"
CATALOG="$ROOT/charts/platform/values.yaml"
for a in keda strimzi cloudnative-pg; do
  assert_eq "$(st 0 "$a" null)" off "enabled: $a not audited by default (opt-in)"
  assert_eq "$(st 1 "$a" null)" on "enabled: $a audited with --opt-in"
done

# extract_images: rendered image: fields plus images handed to operators by env / ConfigMap (not rendered as pods)
cat > "$TMP/render.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: op }
spec:
  template:
    spec:
      containers:
        - name: op
          image: quay.io/example/operator:1.0@sha256:0000000000000000000000000000000000000000000000000000000000000000
          env:
            - name: EXAMPLE_KAFKA_IMAGES
              value: |
                4.2.0=quay.io/example/kafka:1.0-kafka-4.2.0
                4.3.2=quay.io/example/kafka:1.0-kafka-4.3.2
            - name: EXAMPLE_REGISTRY_IMAGE_PREFIX
              value: cr.example.dev/prefix-only
            - name: LOG_LEVEL
              value: ghcr.io/not/an:image
---
apiVersion: v1
kind: ConfigMap
metadata: { name: cfg }
data:
  POSTGRES_IMAGE_NAME: ghcr.io/example/postgresql:18.6@sha256:1111111111111111111111111111111111111111111111111111111111111111
EOF
got=$(extract_images < "$TMP/render.yaml" | sort | tr '\n' ' ')
assert_eq "$got" "ghcr.io/example/postgresql:18.6@sha256:1111111111111111111111111111111111111111111111111111111111111111 quay.io/example/kafka:1.0-kafka-4.2.0 quay.io/example/kafka:1.0-kafka-4.3.2 quay.io/example/operator:1.0@sha256:0000000000000000000000000000000000000000000000000000000000000000 " \
  "extract_images: image fields, operator image env (version=image lines) and ConfigMap keys; no prefixes, no non-IMAGE env"

# extract_images: Crossplane packages (Functions, Providers) are images too; other kinds' spec.package are not
cat > "$TMP/render.yaml" <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata: { name: fn }
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.7.3@sha256:2222222222222222222222222222222222222222222222222222222222222222
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata: { name: p }
spec:
  package: xpkg.crossplane.io/crossplane-contrib/provider-aws-rds:v2.9.0
---
apiVersion: example.org/v1
kind: Thing
metadata: { name: t }
spec:
  package: not-an-image
EOF
got=$(extract_images < "$TMP/render.yaml" | sort | tr '\n' ' ')
assert_eq "$got" "xpkg.crossplane.io/crossplane-contrib/function-auto-ready:v0.7.3@sha256:2222222222222222222222222222222222222222222222222222222222222222 xpkg.crossplane.io/crossplane-contrib/provider-aws-rds:v2.9.0 " \
  "extract_images: Crossplane Function / Provider packages; spec.package of other kinds ignored"

finish
