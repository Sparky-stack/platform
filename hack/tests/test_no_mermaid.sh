#!/usr/bin/env bash
# shellcheck disable=SC2016  # the fixtures are literal Markdown backticks
# One diagram system (#270): every diagram is a generated SVG from docs/diagrams/src/build.py, embedded with <img>.
# Mermaid does not render in the GitHub mobile app, plain Markdown viewers or TechDocs without a plugin, so no
# ```mermaid (or ~~~mermaid, ```{mermaid}) fence may appear in any checked Markdown file or README template; the
# rule is in hack/check-docs.py. Negative cases on a fixture first, then the real repo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

# mermaid_fences <root>: "<path>:<line>" for every Mermaid fence hack/check-docs.py reports under <root> (the rule
# lives there so scoped PR CI, which always runs check-docs, catches a fence in a docs-only change; #355)
mermaid_fences() {
  { py "$ROOT/hack/check-docs.py" "$1" 2>&1 || true; } | sed -n 's/^  FAIL \(.*\): Mermaid fence;.*/\1/p'
}

# 1. negative cases: each fence style in each scanned path is reported; prose, other fences and vendored deps are not
fx="$TMP/repo"
mkdir -p "$fx/docs/runbooks" "$fx/addons/a/charts/dep" "$fx/charts/c" "$fx/packages/p" "$fx/hack"
printf '# ok\nMermaid is not used: see `mermaid` in prose.\n```bash\necho mermaid\n```\n' > "$fx/README.md"
cp "$fx/README.md" "$fx/docs/clean.md"
printf '# dep\n```mermaid\ngraph LR\n```\n' > "$fx/addons/a/charts/dep/README.md"   # vendored: skipped
printf '```{mermaid}\n' > "$fx/addons/a/charts/dep/README.md.gotmpl"                  # vendored: skipped
out=$(mermaid_fences "$fx")
assert_eq "$out" "" "clean fixture: no fences reported"

printf '# x\n\n```mermaid\nflowchart LR\n```\n' > "$fx/docs/runbooks/x.md"
printf '~~~ Mermaid\ngraph TD\n~~~\n' > "$fx/addons/a/README.md"
printf '```{mermaid}\n```\n' > "$fx/charts/c/README.md.gotmpl"
printf '  ````mermaid\n````\n' > "$fx/packages/p/README.md"
printf '# r\n```mermaid\n```\n' > "$fx/README.md"
printf '# n\n```mermaid\n```\n' > "$fx/hack/notes.md"
out=$(mermaid_fences "$fx")
assert_matches "$out" <<'CASES'
a ```mermaid fence in a nested doc is reported with its line | docs/runbooks/x.md:3
a ~~~ Mermaid fence (any case) in an addon README is reported | addons/a/README.md:1
a ```{mermaid} fence in a chart README template is reported | charts/c/README.md.gotmpl:1
an indented, longer fence in a package README is reported | packages/p/README.md:1
CASES
assert_eq "$(grep -cx 'README.md:2' <<<"$out" || true)" 1 "a fence in the root README is reported"
assert_match "$out" "hack/notes.md:2" "a fence in any other checked Markdown file (hack/) is reported"
n=$(grep -c . <<<"$out")
assert_eq "$n" 6 "exactly the six planted fences (vendored deps ignored)"

# 2. the repo itself
out=$(mermaid_fences "$ROOT")
assert_eq "$out" "" "no Mermaid fences in the repo (use docs/diagrams/src/build.py)"
html=$(grep -c '<img src="diagrams/architecture.svg"' "$ROOT/docs/architecture.md" || true)
assert_eq "$html" 1 "docs/architecture.md embeds the generated architecture.svg"

finish
