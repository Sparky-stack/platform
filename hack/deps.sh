#!/usr/bin/env bash
# Build chart dependencies for every chart under charts/ and addons/.
# `helm dependency build` only resolves https repositories that are registered locally, so register each one
# (name = short hash of the URL, idempotent) before building. OCI dependencies need no registration.
# Charts with a charts/ dir are not rebuilt (cache), so every Chart.lock is first checked against its Chart.yaml
# (hack/lib/chartlock.py, helm's own digest): a stale lock fails here on a warm tree exactly as it would on a clean
# checkout or in Argo CD's repo-server.
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

need_build=()
for dir in ${lock_dirs[@]+"${lock_dirs[@]}"}; do
  missing=0
  while IFS= read -r tgz; do
    [[ -z "$tgz" || -f "$dir/charts/$tgz" ]] || { missing=1; break; }
  done < <(awk '/^- name:/{gsub(/"/, "", $3); n=$3} /^  version:/{gsub(/"/, "", $2); print n"-"$2".tgz"}' "$dir/Chart.lock" | tr -d '\r')
  if [[ $missing -eq 1 ]]; then
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
for url in ${repos[@]+"${repos[@]}"}; do
  name="r$(sha1 "$url" | cut -c1-10)"
  helm repo list -o json 2>/dev/null | yq -e ".[] | select(.url == \"$url\")" >/dev/null 2>&1 \
    || retry_with_backoff 4 2 helm repo add "$name" "$url" --force-update >/dev/null
done
[[ ${#repos[@]} -gt 0 ]] && retry_with_backoff 4 2 helm repo update >/dev/null

for dir in "${need_build[@]}"; do
  echo "==> helm dependency build $dir"
  retry_with_backoff 4 2 helm dependency build --skip-refresh "$dir" >/dev/null
done
