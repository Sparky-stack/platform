#!/usr/bin/env bash
# docs/diagrams: the committed SVGs are exactly what docs/diagrams/src/build.py generates (deterministic, up to date),
# every diagram passes the layout checks (no text outside its box, by the generator's own layout data; <= 12 boxes;
# numbered steps == docs/diagrams/README.md), and the checker catches planted defects.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

echo "== test_diagrams =="
B="$ROOT/docs/diagrams/src/build.py"

# 1. committed SVGs are up to date and clean
out=$(py "$B" --check 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 0 "build.py --check: committed SVGs up to date, 0 issues ($out)"
n=$(grep -c 'issues: 0' <<<"$out" || true)
assert_eq "$n" 9 "nine diagrams, each with 0 issues"

# 2. deterministic: two runs, byte-identical output
py "$B" --out "$TMP/a" >/dev/null
py "$B" --out "$TMP/b" >/dev/null
for f in "$TMP"/a/*.svg; do
  if cmp -s "$f" "$TMP/b/$(basename "$f")"; then same=yes; else same=no; fi
  assert_eq "$same" yes "deterministic: $(basename "$f")"
done

# 3. independent of check(): every box text fits inside its box (8 px padding), from the generator's layout data
out=$(py - "$ROOT/docs/diagrams/src" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import build
bad = []
for name, fn in build.DIAGRAMS.items():
    d = fn()
    d.check()
    for s, (x, y, w, h), c, *_ in d.r_text:
        if c and not (x >= c[0] + 8 and x + w <= c[0] + c[2] - 8 and y >= c[1] + 3 and y + h <= c[1] + c[3] - 3):
            bad.append(f"{name}: {s!r}")
    if len(d.r_boxes) > 12:
        bad.append(f"{name}: {len(d.r_boxes)} boxes")
print("\n".join(bad) or "OK")
EOF
)
assert_eq "$out" OK "no text overflows its box, <= 12 boxes"

# 4. negative cases: the checker reports planted defects
out=$(py - "$ROOT/docs/diagrams/src" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from svglib import Diagram
d = Diagram("t", "lede")
d.box(40, 120, 120, 60, "mgmt", "a title much too long for this box")
for i in range(12):
    d.box(40 + (i % 6) * 150, 220 + (i // 6) * 100, 120, 60, "workload", f"b{i}")
a = d.box(40, 440, 120, 60, "mgmt", "src")
b = d.box(400, 440, 120, 60, "mgmt", "dst")
d.arrow([(160, 470), (400, 470)], step=1, badge=False)
d.badge(300, 600, 2)
d.key("one", "two", "three")
d.text(40, 700, "tiny", 10)
for i in d.check():
    print(i)
EOF
)
assert_match "$out" "text overflows its box" "overflowing text is reported"
assert_match "$out" "15 boxes > 12" "more than 12 boxes is reported"
assert_match "$out" "flow arrow a0 has no badge" "numbered arrow without its badge is reported"
assert_match "$out" "key step 3 has no badge" "key entry without a badge is reported"
assert_match "$out" "text below 13 px" "type floor is enforced"

# stale SVG and README steps drift are reported by --check
mkdir -p "$TMP/stale"
cp "$ROOT"/docs/diagrams/*.svg "$TMP/stale/"
printf '<!-- hand edit -->\n' >> "$TMP/stale/network.svg"
out=$(py "$B" --check --out "$TMP/stale" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 1 "a hand-edited SVG fails --check"
assert_match "$out" "network.svg is not up to date" "stale SVG is named"
sed 's/^1\. Argo CD syncs git/1. Argo CD reads git/' "$ROOT/docs/diagrams/README.md" > "$TMP/README.md"
out=$(py "$B" --check --readme "$TMP/README.md" architecture 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 1 "README step drift fails --check"
assert_match "$out" "steps differ from docs/diagrams/README.md" "step drift is named"

finish
