#!/usr/bin/env bash
# hack/registry-cache.sh (host pull-through caches) against a fake docker: container/volume names match the mirror
# hosts charts/cluster renders for CAPD nodes, `up` keeps caches out of k3d (survive `task down`), the k3d
# registries.yaml mirrors every cached upstream, and `clean` removes containers and volumes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$DOCKER_LOG"
case "$1" in
  inspect) exit 1 ;;                      # no cache container running yet
  info) [[ -n "${FAKE_ROOT:-}" ]] && echo "$FAKE_ROOT" ;;
  ps) [[ "$*" == *-aq* && -z "${FAKE_NONE:-}" ]] && echo abc123 ;;
esac
exit 0
EOF
chmod +x "$BIN/docker"
export DOCKER_LOG="$TMP/docker.log"
fake_bin_yq "$BIN"
P="$BIN:/usr/bin:/bin"

PATH="$P" bash "$ROOT/hack/registry-cache.sh" k3s-config "$TMP/reg.yaml"
n=$(yq '.registry.hostCache.mirrors | length' "$ROOT/installations/local/installation.yaml")
assert_eq "$(yq '.mirrors | length' "$TMP/reg.yaml")" "$n" "k3s-config: one mirror per installation.yaml hostCache entry"
assert_eq "$(yq '.mirrors["docker.io"].endpoint[0]' "$TMP/reg.yaml")" "http://platform-cache-docker-io:5000" \
  "k3s-config: docker.io -> platform-cache-docker-io (same name as charts/cluster capi-registries)"
assert_eq "$(yq '.mirrors["registry.k8s.io"].endpoint[0]' "$TMP/reg.yaml")" "http://platform-cache-registry-k8s-io:5000" \
  "k3s-config: dots become dashes"

PATH="$P" bash "$ROOT/hack/registry-cache.sh" up >/dev/null
runs=$(grep -c '^run ' "$DOCKER_LOG" || true)
assert_eq "$runs" "$n" "up: one registry container per upstream"
run_line=$(grep '^run .*platform-cache-docker-io' "$DOCKER_LOG")
assert_matches "$run_line" <<'CASES'
up: on network kind (CAPD + k3d nodes resolve the name) | --network kind
up: survives docker/host restarts | --restart unless-stopped
up: named volume keeps the cache | -v platform-cache-docker-io:/var/lib/registry
up: docker.io proxies registry-1 | REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io
up: image pinned by digest | registry:3.0.0@sha256:
CASES
assert_eq "$(grep -c -- ' -p \| --publish' "$DOCKER_LOG" || true)" 0 "up: no host ports published"
assert_eq "$(grep -c k3d "$DOCKER_LOG" || true)" 0 "up: not attached to any k3d cluster (task down keeps it)"

: > "$DOCKER_LOG"
PATH="$P" bash "$ROOT/hack/registry-cache.sh" clean >/dev/null
assert_match "$(cat "$DOCKER_LOG")" "rm -f abc123" "clean: removes the labelled containers"
assert_eq "$(grep -c '^volume rm platform-cache-' "$DOCKER_LOG")" "$n" "clean: removes every cache volume"

# low disk: no caches are created (containerd then pulls upstream), unless they already exist
: > "$DOCKER_LOG"
PATH="$P" FAKE_ROOT="$TMP" FAKE_NONE=1 REGISTRY_CACHE_MIN_FREE_GIB=999999 bash "$ROOT/hack/registry-cache.sh" up 2>"$TMP/err" >/dev/null
assert_eq "$(grep -c '^run ' "$DOCKER_LOG" || true)" 0 "up: low disk -> no cache containers"
assert_match "$(cat "$TMP/err")" "registry caches not created" "up: low disk warns"

# bootstrap down never touches the caches (only `task cache:clean` does)
assert_eq "$(sed -n '/^cmd_down()/,/^}/p' "$ROOT/bootstrap/bootstrap.sh" | grep -c 'registry-cache\|platform-cache' || true)" 0 \
  "bootstrap down keeps the caches"

finish
