#!/usr/bin/env bash
# Build chart dependencies for every chart under charts/ and addons/.
# `helm dependency build` only resolves https repositories that are registered locally, so register each one
# (name = short hash of the URL, idempotent) before building. OCI dependencies need no registration.
set -euo pipefail
cd "$(dirname "$0")/.."

mapfile -t repos < <(yq -r '.dependencies[]?.repository' charts/*/Chart.yaml addons/*/Chart.yaml 2>/dev/null \
  | grep -E '^https?://' | sort -u)
for url in "${repos[@]}"; do
  name="r$(printf '%s' "$url" | sha1sum | cut -c1-10)"
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
