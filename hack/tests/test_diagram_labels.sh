#!/usr/bin/env bash
# hack/check-diagram-labels.py: every box label of every generated diagram (docs/diagrams/src/build.py) is named in the
# doc(s) owning its topic (docs/diagrams/README.md "Owning doc" column), via ALIASES / DIAGRAM_ONLY where the doc uses
# an identifier instead. Negative cases on fixtures first, then the real repo.
# Owning docs (listed so hack/changed-units.sh runs this test when one changes; case 4 keeps the list in sync):
OWNING_DOCS="docs/architecture.md docs/devops-guide.md docs/networking.md docs/observability.md docs/promotion.md
docs/providers.md docs/runbooks/backup-restore.md docs/runbooks/certificates-and-secrets.md docs/runbooks/upgrades.md
docs/supply-chain.md"
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

C="$ROOT/hack/check-diagram-labels.py"
fx="$TMP/fx"
mkdir -p "$fx"
readme() { printf '| Diagram | One idea | Owning doc |\n|---|---|---|\n| [architecture.svg](architecture.svg) | x | [doc](%s) |\n' "$1" > "$fx/README.md"; }

# 1. a box the owning doc does not name fails (drift): architecture.md without "Cluster API"
sed 's/Cluster API//g' "$ROOT/docs/architecture.md" > "$fx/arch.md"
readme arch.md
capture py "$C" --readme "$fx/README.md" architecture
assert_eq "$RC" 1 "a box missing from its owning doc fails"
assert_match "$OUT" 'architecture: box "Cluster API" not in .*arch.md' "the missing box and the doc are named"
assert_eq "$(grep -c 'FAIL' <<<"$OUT")" 1 "only the dropped label fails"

# 2. an alias whose doc term is gone fails; an alias whose title the doc now names is stale
sed 's/[Oo]pen[Bb][Aa][Oo]//g' "$ROOT/docs/architecture.md" > "$fx/arch.md"
capture py "$C" --readme "$fx/README.md" architecture
assert_eq "$RC" 1 "an alias term missing from the doc fails"
assert_match "$OUT" 'box "Shared services" \(doc term "OpenBao"\) not in' "missing alias term reported"
{ cat "$ROOT/docs/architecture.md"; echo "Shared services: registry, sign-in, OpenBao."; } > "$fx/arch.md"
capture py "$C" --readme "$fx/README.md" architecture
assert_eq "$RC" 1 "a no longer needed alias fails"
assert_match "$OUT" '"Shared services" is now named in .*drop its stale entry' "stale alias reported"

# 3. a diagram without an owning doc fails; matching ignores case, backticks and plurals
capture py "$C" --readme "$fx/README.md" backup
assert_eq "$RC" 1 "a diagram without an owning doc fails"
assert_match "$OUT" "backup: no owning doc" "missing owner reported"
{ sed 's/Cluster API//g' "$ROOT/docs/architecture.md"; printf '%s\n' "The \`cluster apis\` build clusters."; } > "$fx/arch.md"
capture py "$C" --readme "$fx/README.md" architecture
assert_eq "$RC" 0 "case, backticks and plural are ignored ($OUT)"

# 4. the real repo; the owning-doc list above matches docs/diagrams/README.md
capture py "$C"
assert_eq "$RC" 0 "every diagram box is named in its owning doc ($OUT)"
want=$(py - "$ROOT" <<'EOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("c", os.path.join(sys.argv[1], "hack", "check-diagram-labels.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
own = m.owners(os.path.join(m.ROOT, "docs", "diagrams", "README.md"))
print(" ".join(sorted({os.path.relpath(p, m.ROOT).replace(os.sep, "/") for v in own.values() for p in v})))
EOF
)
assert_eq "$(tr -s ' \n' '  ' <<<"$OWNING_DOCS" | sed 's/ $//')" "$(tr -d '\r' <<<"$want")" "OWNING_DOCS lists every owning doc"

finish
