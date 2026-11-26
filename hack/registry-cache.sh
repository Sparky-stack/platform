#!/usr/bin/env bash
# Host pull-through registry caches for the local installation (docs/dev-environment.md "Registry caches").
# Usage: hack/registry-cache.sh up|status|clean|k3s-config <out-file>        (task cache:status, task cache:clean)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

INST_FILE="installations/${INST:-local}/installation.yaml"
# registry 3.0.0 (distribution), multi-arch index digest (docs/conventions.md invariant 9).
IMAGE="docker.io/library/registry:3.0.0@sha256:6c5666b861f3505b116bb9aa9b25175e71210414bd010d92035ff64018f9457e"
NETWORK=kind

# mirrors: "<upstream> <remote>" per line from installation.yaml.
mirrors() { yq '.registry.hostCache.mirrors[] | .upstream + " " + .remote' "$INST_FILE" | tr -d '\r'; }
# name <upstream>: container + volume name, also the CAPD/k3d mirror host (charts/cluster derives it the same way).
name() { echo "platform-cache-${1//./-}"; }

# low_disk: true when Docker's host data dir has less than REGISTRY_CACHE_MIN_FREE_GIB (default 10) free.
low_disk() {
  local root
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null | tr -d '\r')
  [[ -d "$root" ]] && (( $(free_gb "$root") < ${REGISTRY_CACHE_MIN_FREE_GIB:-10} ))
}

cmd_up() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
  if low_disk && [[ -z "$(docker ps -aq --filter label=platform.koorikla.io/registry-cache=true)" ]]; then
    echo "WARN: less than ${REGISTRY_CACHE_MIN_FREE_GIB:-10} GiB free for Docker: registry caches not created (pulls go upstream)" >&2
    return 0
  fi
  local upstream remote n
  while read -r upstream remote; do
    n=$(name "$upstream")
    if [[ "$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null || true)" == true ]]; then
      continue
    fi
    docker rm -f "$n" >/dev/null 2>&1 || true
    # MSYS_NO_PATHCONV: Git Bash on Windows would rewrite the container path /var/lib/registry.
    MSYS_NO_PATHCONV=1 docker run -d --name "$n" --network "$NETWORK" --restart unless-stopped \
      --label platform.koorikla.io/registry-cache=true \
      -v "$n:/var/lib/registry" \
      -e REGISTRY_PROXY_REMOTEURL="$remote" -e REGISTRY_PROXY_TTL=720h \
      -e OTEL_TRACES_EXPORTER=none \
      "$IMAGE" >/dev/null
    echo "registry cache $n -> $remote"
  done < <(mirrors)
}

cmd_status() {
  docker ps -a --filter label=platform.koorikla.io/registry-cache=true --format '{{.Names}}\t{{.Status}}'
  docker system df -v 2>/dev/null | grep -E '^platform-cache-' || true
}

cmd_clean() {
  local ids
  ids=$(docker ps -aq --filter label=platform.koorikla.io/registry-cache=true)
  # shellcheck disable=SC2086 # one id per word
  [[ -z "$ids" ]] || docker rm -f $ids >/dev/null
  local upstream remote
  while read -r upstream remote; do
    docker volume rm "$(name "$upstream")" >/dev/null 2>&1 || true
  done < <(mirrors)
  echo "registry caches removed"
}

# k3s-config <out>: k3s registries.yaml mirroring every cached upstream (for k3d --registry-config).
cmd_k3s_config() {
  local out="$1" upstream remote
  {
    echo "mirrors:"
    while read -r upstream remote; do
      printf '  "%s":\n    endpoint: ["http://%s:5000"]\n' "$upstream" "$(name "$upstream")"
    done < <(mirrors)
  } > "$out"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  clean) cmd_clean ;;
  k3s-config) cmd_k3s_config "${2:?usage: $0 k3s-config <out-file>}" ;;
  *) echo "usage: $0 up|status|clean|k3s-config <out-file>" >&2; exit 2 ;;
esac
