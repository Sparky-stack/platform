#!/usr/bin/env bash
# Offline lint check: build cached chart deps, helm lint all charts, validate YAML + shell scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in helm helm-docs yq; do
  command -v "$bin" >/dev/null || { echo "missing tool: $bin" >&2; exit 1; }
done

first_inst=$(find installations -mindepth 1 -maxdepth 1 -type d | sort | sed -n 1p)
first_cluster=$(find "$first_inst/clusters" -maxdepth 1 -name '*.yaml' | sort | sed -n 1p)

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

echo "==> Checking hack/ pipelines for early-exit readers (SIGPIPE under pipefail)"
# `cmd | grep -q`, `| grep -m1` and `| head` stop reading early; the writer then dies of SIGPIPE (exit 141) and pipefail
# fails the line at random, mostly under the parallel test runner. Capture first and read a here-string
# (grep -qx -- "$x" <<<"$out"), or use a reader that reads everything (sed -n 1p). Allowed: the probe helper r() of
# hack/tests/openbao_integration.sh, which runs in the OpenBao container's sh (no pipefail).
# shellcheck disable=SC2016  # literal $1 in the allowed line
early=$(grep -rnE --include='*.sh' \
  '(^|[^|])\|[[:space:]]*(grep([[:space:]]+-[[:alnum:]-]+)*[[:space:]]+(-[[:alnum:]]*[qm]|--quiet|--silent|--max-count)|head([[:space:]]|$))' \
  hack | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vF 'r() { id=$1;' || true)
if [[ -n "$early" ]]; then
  printf '%s\n' "$early" >&2
  echo "early-exit reader in a pipeline: capture the output first, then match a here-string" >&2
  exit 1
fi

echo "==> Checking Markdown links, paths and commands"
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh
py hack/check-docs.py

echo "==> Checking chart READMEs are in sync with helm-docs"
for root in charts addons; do
  helm-docs --chart-search-root "$root" --template-files ../hack/helm-docs/README.md.gotmpl --template-files README.md.gotmpl >/dev/null 2>&1
done
git diff --exit-code -- '*/README.md'

echo "==> Checking docs/reference/ is in sync with its sources (hack/gen-reference.py)"
py hack/gen-reference.py --check

echo "lint OK"
