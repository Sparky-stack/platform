#!/usr/bin/env bash
# Build chart dependencies for every chart under charts/ and addons/.
# `helm dependency build` only resolves https repositories that are registered locally, so register each one
# (name = short hash of the URL, idempotent) before building. OCI dependencies need no registration.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

repos=()
while IFS= read -r url; do
  if [[ -n "$url" ]]; then repos+=("$url"); fi
done < <(yq -r '.dependencies[]?.repository' charts/*/Chart.yaml addons/*/Chart.yaml 2>/dev/null \
  | tr -d '\r' | grep -E '^https?://' | sort -u)
# Repo registration + `helm repo update` (network) only when some chart still needs its deps built: a warm tree
# stays offline (git pre-commit hook, hack/hooks.sh charts).
for dir in charts/* addons/*; do
  if [[ -f "$dir/Chart.yaml" ]] && grep -q '^dependencies:' "$dir/Chart.yaml" \
    && [[ ! -d "$dir/charts" || -z "$(ls -A "$dir/charts" 2>/dev/null)" ]]; then break; fi
  dir=""
done
[[ -n "$dir" ]] || repos=()
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
