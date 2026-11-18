#!/usr/bin/env bash
# Build chart dependencies for every chart under charts/ and addons/.
# `helm dependency build` only resolves https repositories that are registered locally, so register each one
# (name = short hash of the URL, idempotent) before building. OCI dependencies need no registration.
# Charts whose charts/ already holds exactly the locked tarballs are not rebuilt (cache), so every Chart.lock is first
# checked against its Chart.yaml (hack/lib/chartlock.py, helm's own digest): a stale lock fails here on a warm tree exactly as it would on a clean
# checkout or in Argo CD's repo-server.
# Charts that pin dependency digests (Chart.yaml annotation, see hack/lib/chartlock.py) get their tarballs checked on
# every run: a mismatching cached tarball is rebuilt, a freshly downloaded one that still mismatches fails.
# `helm repo update` only touches the repositories these charts use: a stale or retired repository registered in the
# user's helm config (e.g. Istio's GCS bucket, 403 during upstream's scream tests) must not break the build.
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

# Repo registration + `helm repo update` (network) only for charts that still need deps built: a warm tree
# stays offline (git pre-commit hook, hack/hooks.sh charts, cached CI runs).
need_yamls=()
for dir in "${need_build[@]}"; do need_yamls+=("$dir/Chart.yaml"); done
repos=()
read_lines repos bash -c 'yq -r ".dependencies[]?.repository" "$@" 2>/dev/null | tr -d "\r" | grep -E "^https?://" | sort -u || true' _ "${need_yamls[@]}"
names=()
for url in ${repos[@]+"${repos[@]}"}; do
  # Reuse a registration of the same URL under any name, else add one named after the URL's hash.
  name=$(helm repo list -o json 2>/dev/null | yq -r "[.[] | select(.url == \"$url\")][0].name // \"\"" 2>/dev/null \
    | tr -d '\r' || true)
  if [[ -z "$name" ]]; then
    name="r$(sha1 "$url" | cut -c1-10)"
    retry_with_backoff 4 2 helm repo add "$name" "$url" --force-update >/dev/null
  fi
  names+=("$name")
done
[[ ${#names[@]} -gt 0 ]] && retry_with_backoff 4 2 helm repo update "${names[@]}" >/dev/null

for dir in "${need_build[@]}"; do
  echo "==> helm dependency build $dir"
  retry_with_backoff 4 2 helm dependency build --skip-refresh "$dir" >/dev/null
done
if ! py hack/lib/chartlock.py --tarballs "${need_build[@]}" >&2; then
  echo "deps: downloaded chart tarballs differ from their pinned digests (see above)" >&2
  exit 1
fi
