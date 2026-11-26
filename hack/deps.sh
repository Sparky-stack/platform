#!/usr/bin/env bash
# Build chart dependencies for every chart under charts/ and addons/ (cached when tarballs match Chart.lock and pins).
# Uses a throwaway HELM_REPOSITORY_CONFIG so stale entries in the user's helm config cannot break builds.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

lock_dirs=()
for dir in charts/* addons/*; do
  if [[ -f "$dir/Chart.yaml" ]] && grep -q '^dependencies:' "$dir/Chart.yaml"; then lock_dirs+=("$dir"); fi
done
if ! py hack/lib/chartlock.py ${lock_dirs[@]+"${lock_dirs[@]}"} >&2; then
  echo "deps: Chart.lock out of sync (see above); commit the updated lock" >&2
  exit 1
fi

# file:// dependencies (the library chart charts/lib) live in this repo: re-package them on every run (offline, cheap),
# since editing the library keeps its tarball name (name-version.tgz), so the cache below would keep the old copy.
for dir in ${lock_dirs[@]+"${lock_dirs[@]}"}; do
  for rel in $(yq -r '.dependencies[].repository | select(test("^file://")) | sub("^file://"; "")' "$dir/Chart.yaml" \
    | tr -d '\r'); do
    helm package "$dir/$rel" --destination "$dir/charts" >/dev/null
  done
done

# A chart's charts/ must hold exactly the tarballs its Chart.lock pins (name-version.tgz): a missing one (new or bumped
# dependency) or an extra one (removed/old dependency, e.g. from a partially restored CI cache, which Helm would still
# render as a subchart) rebuilds that chart from scratch.
bad_pins=$(py hack/lib/chartlock.py --tarballs ${lock_dirs[@]+"${lock_dirs[@]}"} 2>&1 | tr -d '\r' || true)
need_build=()
for dir in ${lock_dirs[@]+"${lock_dirs[@]}"}; do
  want=$(awk '/^- name:/{gsub(/"/, "", $3); n=$3} /^  version:/{gsub(/"/, "", $2); print n"-"$2".tgz"}' "$dir/Chart.lock" \
    | tr -d '\r' | LC_ALL=C sort)
  # shellcheck disable=SC2012  # chart tarball names (name-version.tgz) only
  have=$(ls -A "$dir/charts" 2>/dev/null | LC_ALL=C sort || true)
  if [[ "$want" != "$have" || $'\n'"$bad_pins" == *$'\n'"$dir: "* ]]; then
    rm -rf "$dir/charts"
    need_build+=("$dir")
  fi
done
[[ ${#need_build[@]} -eq 0 ]] && exit 0

# Repo registration (network) only for charts that still need deps built: a warm tree
# stays offline (git pre-commit hook, hack/hooks.sh charts, cached CI runs).
need_yamls=()
for dir in "${need_build[@]}"; do need_yamls+=("$dir/Chart.yaml"); done
repos=()
read_lines repos bash -c 'yq -r ".dependencies[]?.repository" "$@" 2>/dev/null | tr -d "\r" | grep -E "^https?://" | sort -u || true' _ "${need_yamls[@]}"
repo_tmp=$(mktemp -d)
trap 'rm -rf "$repo_tmp"' EXIT
HELM_REPOSITORY_CONFIG=$(native_path "$repo_tmp/repositories.yaml")
export HELM_REPOSITORY_CONFIG
for url in ${repos[@]+"${repos[@]}"}; do
  # `helm repo add` downloads the index (into HELM_REPOSITORY_CACHE as <name>-index.yaml), so no `helm repo update`.
  retry_with_backoff 4 2 helm repo add "r$(sha1 "$url" | cut -c1-10)" "$url" --force-update >/dev/null
done

for dir in "${need_build[@]}"; do
  echo "==> helm dependency build $dir"
  retry_with_backoff 4 2 helm dependency build --skip-refresh "$dir" >/dev/null
done
if ! py hack/lib/chartlock.py --tarballs "${need_build[@]}" >&2; then
  echo "deps: downloaded chart tarballs differ from their pinned digests (see above)" >&2
  exit 1
fi
