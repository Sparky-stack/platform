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

repos=()
while IFS= read -r url; do
  if [[ -n "$url" ]]; then repos+=("$url"); fi
done < <(yq -r '.dependencies[]?.repository' charts/*/Chart.yaml addons/*/Chart.yaml 2>/dev/null \
  | tr -d '\r' | grep -E '^https?://' | sort -u)
for url in ${repos[@]+"${repos[@]}"}; do
  name="r$(sha1 "$url" | cut -c1-10)"
  helm repo list -o json 2>/dev/null | yq -e ".[] | select(.url == \"$url\")" >/dev/null 2>&1 \
    || helm repo add "$name" "$url" >/dev/null
done
[[ ${#repos[@]} -gt 0 ]] && helm repo update >/dev/null

for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  grep -q '^dependencies:' "$dir/Chart.yaml" || continue
  if [[ ! -d "$dir/charts" || -z "$(ls -A "$dir/charts" 2>/dev/null)" ]]; then
    echo "==> helm dependency build $dir"
    helm dependency build "$dir" >/dev/null
  fi
done
