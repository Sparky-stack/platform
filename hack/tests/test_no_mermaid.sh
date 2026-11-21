#!/usr/bin/env bash
# shellcheck disable=SC2016  # the fixtures are literal Markdown backticks
# One diagram system (#270): every diagram is a generated SVG from docs/diagrams/src/build.py, embedded with <img>.
# Mermaid does not render in the GitHub mobile app, plain Markdown viewers or TechDocs without a plugin, so no
# ```mermaid (or ~~~mermaid, ```{mermaid}) fence may appear in docs/, README.md, addons/, charts/ or packages/.
# Negative cases on a fixture first, then the real repo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

# mermaid_fences <root>: "<path>:<line>" for every Mermaid fence under the scanned paths (Markdown and README
# templates; vendored chart dependencies under */charts/<dep>/ are not ours and are skipped)
mermaid_fences() {
  py - "$1" <<'EOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
fence = re.compile(r"^\s{0,3}(`{3,}|~{3,})\s*\{?\s*mermaid\b", re.IGNORECASE)
files = [root / "README.md"]
for top in ("docs", "addons", "charts", "packages"):
    if (root / top).is_dir():
        files += sorted(p for p in (root / top).rglob("*") if p.suffix in (".md", ".gotmpl") and p.is_file())
for f in files:
    rel = f.relative_to(root).as_posix()
    if not f.is_file() or re.match(r"(addons|charts)/[^/]+/charts/", rel):
        continue
    for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if fence.match(line):
            print(f"{rel}:{n}")
EOF
}

# 1. negative cases: each fence style in each scanned path is reported; prose, other fences and vendored deps are not
fx="$TMP/repo"
mkdir -p "$fx/docs/runbooks" "$fx/addons/a/charts/dep" "$fx/charts/c" "$fx/packages/p" "$fx/hack"
printf '# ok\nMermaid is not used: see `mermaid` in prose.\n```bash\necho mermaid\n```\n' > "$fx/README.md"
cp "$fx/README.md" "$fx/docs/clean.md"
printf '# dep\n```mermaid\ngraph LR\n```\n' > "$fx/addons/a/charts/dep/README.md"   # vendored: skipped
printf '```mermaid\n' > "$fx/hack/notes.md"                                            # not a scanned path
out=$(mermaid_fences "$fx")
assert_eq "$out" "" "clean fixture: no fences reported"

printf '# x\n\n```mermaid\nflowchart LR\n```\n' > "$fx/docs/runbooks/x.md"
printf '~~~ Mermaid\ngraph TD\n~~~\n' > "$fx/addons/a/README.md"
printf '```{mermaid}\n```\n' > "$fx/charts/c/README.md.gotmpl"
printf '  ````mermaid\n````\n' > "$fx/packages/p/README.md"
printf '# r\n```mermaid\n```\n' > "$fx/README.md"
out=$(mermaid_fences "$fx")
assert_match "$out" "docs/runbooks/x.md:3" "a \`\`\`mermaid fence in a nested doc is reported with its line"
assert_match "$out" "addons/a/README.md:1" "a ~~~ Mermaid fence (any case) in an addon README is reported"
assert_match "$out" "charts/c/README.md.gotmpl:1" "a \`\`\`{mermaid} fence in a chart README template is reported"
assert_match "$out" "packages/p/README.md:1" "an indented, longer fence in a package README is reported"
assert_match "$out" "^README.md:2" "a fence in the root README is reported"
n=$(grep -c . <<<"$out")
assert_eq "$n" 5 "exactly the five planted fences (vendored dep and hack/ ignored)"

# 2. the repo itself
out=$(mermaid_fences "$ROOT")
assert_eq "$out" "" "no Mermaid fences in docs/, README.md, addons/, charts/, packages/ (use docs/diagrams/src/build.py)"
html=$(grep -c '<img src="diagrams/architecture.svg"' "$ROOT/docs/architecture.md" || true)
assert_eq "$html" 1 "docs/architecture.md embeds the generated architecture.svg"

finish
