# Shared Crossplane composition-render Docker harness and query helpers.
# shellcheck shell=bash

# xp_check_docker: skip cleanly (exit 0) when crossplane CLI or a Linux Docker engine is absent.
xp_check_docker() {
  if ! command -v crossplane >/dev/null 2>&1; then
    echo "  SKIP crossplane render: crossplane CLI not found (mise install)"
    finish; exit 0
  fi
  if [[ "$(docker info --format '{{.OSType}}' 2>/dev/null | tr -d '\r')" != linux ]]; then
    echo "  SKIP crossplane render: needs a Linux Docker engine (functions run as containers)"
    finish; exit 0
  fi
}

xp_cleanup_run() {   # xp_cleanup_run <network>: remove the run's containers, then its network
  local ids
  ids=$( (docker ps -aq --filter "name=$1-"; docker ps -aq --filter "network=$1") 2>/dev/null | sort -u | tr '\n' ' ')
  # shellcheck disable=SC2086 # word-split container ids
  [[ -z "${ids// /}" ]] || docker rm -f $ids >/dev/null 2>&1 || true
  docker network rm "$1" >/dev/null 2>&1 || true
}

# xp_render_init <prefix>: create a run-scoped Docker network (cleaning leaked networks of dead PIDs) and register traps.
xp_render_init() {
  local net pid host out
  XP_LABEL=koorikla.platform/test=crossplane-render
  XP_HOST=$(uname -n)
  XP_NET="$1-$$-$RANDOM"
  # shellcheck disable=SC2329  # invoked indirectly via trap
  xp_cleanup() {
    local pids
    pids=$(jobs -p)
    # shellcheck disable=SC2086 # word-split pids
    [[ -z "$pids" ]] || kill $pids 2>/dev/null || true
    xp_cleanup_run "$XP_NET"
    [[ -z "${XP_FN_IMAGE:-}" ]] || docker rmi -f "$XP_FN_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$TMP"
  }
  trap xp_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while read -r net pid host; do
    [[ -n "$net" && "$host" == "$XP_HOST" ]] || continue
    kill -0 "$pid" 2>/dev/null || xp_cleanup_run "$net"
  done < <(docker network ls --filter "label=$XP_LABEL" \
    --format '{{.Name}} {{.Label "koorikla.platform/owner-pid"}} {{.Label "koorikla.platform/owner-host"}}' | tr -d '\r')
  if ! out=$(docker network create --label "$XP_LABEL" --label "koorikla.platform/owner-pid=$$" \
    --label "koorikla.platform/owner-host=$XP_HOST" "$XP_NET" 2>&1); then
    echo "$out" >&2
    echo "  hint: $(docker network ls -q | wc -l | tr -d ' ') Docker networks exist; networks left by killed renders:" \
      "docker network ls --filter name=crossplane-render- (remove only those without containers you own)" >&2
    assert_eq failed ok "crossplane render: create the run's Docker network $XP_NET"
    finish; exit 1
  fi
}

# xp_pull_images <image>...: pull missing images serially with retries so parallel renders never hit connection resets.
xp_pull_images() {
  local img
  for img in "$@"; do
    [[ -n "$img" && "$img" != null ]] || continue
    docker image inspect "$img" >/dev/null 2>&1 || retry_with_backoff 4 2 docker pull -q "$img" >/dev/null
  done
}

xp_yq() { yq -N "$1" "$2" | tr -d '\r' | sed '/^$/d'; }
xp_kinds() { xp_yq '.kind' "$1" | LC_ALL=C sort | uniq -c | awk '{print $2 "=" $1}' | tr '\n' ' '; }
