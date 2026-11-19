#!/usr/bin/env bash
# Which parts of the repo a change touches, so PR CI validates only those (docs/dev-environment.md#scoped-pr-ci).
#   changed-units.sh [PATH...]          changed file paths (args, else one per line on stdin) -> units, one per line:
#                                       charts/<c>, addons/<a>, packages/<p>, docs/<doc>, ci, templates; `docs` when only
#                                       untested docs changed; `full` when a shared input changed or a path is unknown.
#   changed-units.sh --tests UNIT...    the hack/tests/test_*.sh contract tests related to those units.
# When unsure, answer `full`: a wasted CI minute is cheaper than a broken main.
set -euo pipefail
cd "$(dirname "$0")/.."

unit_of() {
  local r
  case "$1" in
    # Shared inputs: every render or tool reads them. charts/platform = catalog + ApplicationSets, charts/cluster =
    # the cluster labels addon renders select on; installations' installation.yaml and cluster files feed both.
    hack/* | bootstrap/* | charts/platform/* | charts/cluster/* | installations/*/installation.yaml | \
      installations/*/clusters/* | .github/workflows/ci.yaml) echo full ;;
    charts/*/* | addons/*/*) r=${1#*/}; echo "${1%%/*}/${r%%/*}" ;;
    installations/*/addons/*/*) r=${1#installations/*/addons/}; echo "addons/${r%%/*}" ;;
    packages/*/*) r=${1#packages/}; echo "packages/${r%%/*}" ;;
    ci/* | .github/workflows/app-*.yaml | .github/workflows/ci-selftest.yaml | .github/workflows/ci-toolbox.yaml) echo ci ;;
    templates/* | .github/workflows/templates.yaml) echo templates ;;
    docs/*) r=${1#docs/}; r="docs/${r%%/*}"; if [[ -n "$(related_tests "$r")" ]]; then echo "$r"; else echo docs; fi ;;
    wiki/* | *.md) echo docs ;;
    *) echo full ;;   # mise.toml, Taskfile.yml, prek.toml, renovate.json, other workflows, new top-level dirs, ...
  esac
}

# A contract test relates to a unit when it names the unit's path, or (charts/addons only) when it checks every
# chart or every rendered manifest (`addons/*`, `charts/*`, $RENDERED_DIR).
related_tests() {
  local t u
  for t in hack/tests/test_*.sh; do
    [[ "$t" != */test_changed_units.sh ]] || continue   # its fixtures name every kind of unit; hack/ changes run it
    for u in "$@"; do
      if grep -Eq "(^|[^A-Za-z0-9_./-])$u([^A-Za-z0-9_-]|\$)" "$t" ||
        { [[ "$u" == charts/* || "$u" == addons/* ]] && grep -Eq '(addons|charts)/\*|RENDERED_DIR' "$t"; }; then
        echo "$t"
        break
      fi
    done
  done
}

if [[ "${1:-}" == "--tests" ]]; then
  shift
  related_tests "$@"
  exit 0
fi

units=$(if (( $# > 0 )); then printf '%s\n' "$@"; else cat; fi | tr -d '\r' | while IFS= read -r p; do
  if [[ -n "$p" ]]; then unit_of "$p"; fi
done | sort -u)

if [[ -z "$units" ]] || grep -qx full <<<"$units"; then
  echo full                                  # no paths at all is "unsure" too
elif [[ "$units" == docs ]]; then
  echo docs
else
  grep -vx docs <<<"$units"                  # docs ride along with the other units (check-docs always runs)
fi
