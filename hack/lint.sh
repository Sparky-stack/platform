#!/usr/bin/env bash
# Offline lint check: build cached chart deps, helm lint all charts, validate YAML + shell scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in helm helm-docs yq; do
  command -v "$bin" >/dev/null || { echo "missing tool: $bin" >&2; exit 1; }
done

first_inst=$(find installations -mindepth 1 -maxdepth 1 -type d | sort | head -n1)
first_cluster=$(find "$first_inst/clusters" -maxdepth 1 -name '*.yaml' | sort | head -n1)

./hack/deps.sh
for dir in charts/* addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  if [[ "$dir" == "charts/cluster" ]]; then
    echo "==> helm lint $dir (scope cluster, scope fleet)"
    helm lint "$dir" --values "$first_inst/installation.yaml" --values "$first_cluster" >/dev/null
    helm lint "$dir" --values "$first_inst/installation.yaml" --set scope=fleet >/dev/null
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
done < <(find bootstrap hack .devcontainer -type f -name '*.sh' -print0)

echo "==> Checking Markdown links, paths and commands"
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh
py hack/check-docs.py

echo "==> Checking chart READMEs are in sync with helm-docs"
for root in charts addons; do
  helm-docs --chart-search-root "$root" --template-files ../hack/helm-docs/README.md.gotmpl --template-files README.md.gotmpl >/dev/null 2>&1
done
git diff --exit-code -- '*/README.md'

echo "lint OK"
