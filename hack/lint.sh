#!/usr/bin/env bash
# Offline lint check: build cached chart deps, helm lint all charts, validate YAML + shell scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in helm yq; do
  command -v "$bin" >/dev/null || { echo "missing tool: $bin" >&2; exit 1; }
done

first_inst=$(find installations -mindepth 1 -maxdepth 1 -type d | sort | head -n1)
first_cluster=$(find "$first_inst/clusters" -maxdepth 1 -name '*.yaml' | sort | head -n1)

for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if grep -q '^dependencies:' "$dir/Chart.yaml" && [[ ! -d "$dir/charts" || -z "$(ls -A "$dir/charts" 2>/dev/null)" ]]; then
    echo "==> helm dependency build $dir"
    helm dependency build "$dir" >/dev/null
  fi
  if [[ "$dir" == "charts/cluster" ]]; then
    if [[ ! -f "$dir/templates/capi-cluster.yaml" ]]; then
      echo "==> SKIP helm lint $dir (capi-cluster.yaml not present on this branch)"
      continue
    fi
    echo "==> helm lint $dir"
    helm lint "$dir" --values "$first_inst/installation.yaml" --values "$first_cluster" >/dev/null
  else
    echo "==> helm lint $dir"
    helm lint "$dir" >/dev/null
  fi
done

echo "==> Checking YAML syntax under installations/ and bootstrap/"
while IFS= read -r -d '' yf; do
  yq '.' "$yf" >/dev/null
done < <(find installations bootstrap -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

echo "==> Checking shell scripts"
while IFS= read -r -d '' sf; do
  bash -n "$sf"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x -P SCRIPTDIR "$sf"
  fi
done < <(find bootstrap hack -type f -name '*.sh' -print0)

echo "lint OK"
