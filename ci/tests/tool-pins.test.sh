#!/usr/bin/env bash
# Contract: CI tools have one declared, pinned version that Renovate updates; nothing installs "latest" at run time
# (#389, #364). Scope: .github/workflows/*.yaml and ci/scripts/**, the code app CI runs (GitHub Actions and in-cluster).
#   bash ci/tests/tool-pins.test.sh      (bash 3.2 compatible; run by ci-selftest.yaml)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
fails=0
ok() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  fails=$((fails + 1))
}

files="$(ls .github/workflows/*.yaml; find ci/scripts -type f)"
# shellcheck disable=SC2086 # word splitting of the file list is intended (no spaces in these paths)
scan() { grep -nE "$1" ${files} || true; }

# 1. No run-time compiles or unpinned package installs.
hits="$(scan 'cargo install')"
if [[ -z "${hits}" ]]; then ok "no cargo install"; else fail "no cargo install"; printf '%s\n' "${hits}"; fi
hits="$(scan 'gem install' | grep -vE -- '(--version|-v) ' || true)"
if [[ -z "${hits}" ]]; then ok "every gem install names a version"; else fail "every gem install names a version"; printf '%s\n' "${hits}"; fi
hits="$(scan '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh([[:space:]]|$)|(ba|z)?sh[[:space:]]+<\([[:space:]]*(curl|wget)')"
if [[ -z "${hits}" ]]; then ok "no curl | bash"; else fail "no curl | bash"; printf '%s\n' "${hits}"; fi

# 2. setup-trivy installs the toolbox's Trivy, not latest.
trivy="$(sed -n 's/^ARG TRIVY_VERSION=//p' ci/toolbox/Dockerfile)"
[[ -n "${trivy}" ]] || fail "TRIVY_VERSION found in ci/toolbox/Dockerfile"
# setup_trivy_versions FILE - "<line>: <version or MISSING>" per setup-trivy step (version: within the step's with:).
setup_trivy_versions() {
  awk '
    /uses: aquasecurity\/setup-trivy@/ { if (at) print at ": MISSING"; at = FNR; next }
    at && /^[[:space:]]*-[[:space:]]/ { print at ": MISSING"; at = 0 }
    at && /^[[:space:]]+version:/ { v = $2; print at ": " v; at = 0 }
    END { if (at) print at ": MISSING" }' "$1"
}
bad=""
n=0
for f in .github/workflows/*.yaml; do
  while IFS= read -r l; do
    [[ -n "${l}" ]] || continue
    n=$((n + 1))
    [[ "${l#*: }" == "v${trivy}" ]] || bad="${bad}${f}:${l}"$'\n'
  done <<EOF
$(setup_trivy_versions "${f}")
EOF
done
if [[ -z "${bad}" && "${n}" -gt 0 ]]; then
  ok "${n} setup-trivy steps pin version v${trivy} (= ci/toolbox TRIVY_VERSION)"
else
  fail "setup-trivy steps pin version v${trivy} (= ci/toolbox TRIVY_VERSION)"
  printf '%s' "${bad}"
fi

# 3. taiki-e/install-action: every tool@<x.y.z>, and no silent fallback to compiling from source.
tools="$(awk '/uses: taiki-e\/install-action@/ { at = 1; next }
  at && /^[[:space:]]+tool:/ { sub(/^[[:space:]]+tool:[[:space:]]*/, ""); print; at = 0 }' .github/workflows/*.yaml | tr -s ', ' '\n')"
unpinned="$(printf '%s\n' "${tools}" | grep -vE '^$|@[0-9]+\.[0-9]+\.[0-9]+$' || true)"
if [[ -n "${tools}" && -z "${unpinned}" ]]; then
  ok "install-action tools pinned: $(printf '%s' "${tools}" | tr '\n' ' ')"
else
  fail "install-action tools pinned to x.y.z"
  printf '%s\n' "${unpinned}"
fi
uses="$(awk '/uses: taiki-e\/install-action@/ { n++ } END { print n + 0 }' .github/workflows/*.yaml)"
fallbacks="$(awk '/^[[:space:]]+fallback: none$/ { n++ } END { print n + 0 }' .github/workflows/*.yaml)"
if [[ "${uses}" == "${fallbacks}" ]]; then ok "install-action steps set fallback: none"; else fail "install-action steps set fallback: none (${fallbacks}/${uses})"; fi

# 4. Every toolbox tool version is Renovate data (a "# renovate:" line right above its ARG).
missing="$(awk '/^ARG [A-Z0-9_]+_VERSION=/ && prev !~ /^# renovate: datasource=[^ ]+ depName=[^ ]+/ { print FNR ": " $0 }
  { prev = $0 }' ci/toolbox/Dockerfile)"
if [[ -z "${missing}" ]]; then ok "ci/toolbox ARG versions carry # renovate: annotations"; else fail "ci/toolbox ARG versions carry # renovate: annotations"; printf '%s\n' "${missing}"; fi

[[ "${fails}" -eq 0 ]] || {
  printf '%s check(s) failed\n' "${fails}"
  exit 1
}
printf 'all tool-pin checks passed\n'
