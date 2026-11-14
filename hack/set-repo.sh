#!/usr/bin/env bash
# Rewrite the platform repoURL across bootstrap/, charts/ and installations/ (fork support).
# Usage: hack/set-repo.sh https://github.com/<you>/platform.git     (task set-repo REPO=... / make set-repo REPO=...)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

REPO="${1:-${REPO:-}}"
[[ -n "$REPO" ]] || { echo "usage: $0 <repo-url>  (e.g. https://github.com/you/platform.git)" >&2; exit 2; }
OLD=$(grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)
[[ -n "$OLD" ]] || { echo "no repoURL found in bootstrap/root-app.yaml" >&2; exit 1; }
if [[ "$OLD" == "$REPO" ]]; then
  echo "repoURL already $REPO"
  exit 0
fi

echo "Rewriting $OLD -> $REPO"
# Escape sed replacement metacharacters (&, \, and the | delimiter) and regex dots in the old URL.
old_re=$(printf '%s' "$OLD" | sed 's/[.[\*^$|]/\\&/g')
new_rep=$(printf '%s' "$REPO" | sed 's/[&\\|]/\\&/g')
files=()
while IFS= read -r f; do
  files+=("$f")
done < <(grep -rlF "$OLD" bootstrap charts installations || true)
if (( ${#files[@]} > 0 )); then
  sed_inplace "s|${old_re}|${new_rep}|g" "${files[@]}"
  printf '  %s\n' "${files[@]}"
fi
