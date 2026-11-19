#!/usr/bin/env bash
# docs/diagrams: the committed SVGs are exactly what docs/diagrams/src/build.py generates (deterministic, up to date),
# every diagram passes the layout checks (no text outside its box, by the generator's own layout data; <= 12 boxes;
# numbered steps == docs/diagrams/README.md), and the checker catches planted defects.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

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
d.badge(340, 600, 2)
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
assert_match "$out" "step 2 has 2 badges" "a step number drawn twice is reported"

# 5. v3 reading rules: planted defects of the classes the visual review found
out=$(py - "$ROOT/docs/diagrams/src" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from svglib import Diagram
d = Diagram("t", "lede")
d.zone(16, 100, 400, 300, "cluster a", "workload")
d.box(40, 160, 140, 80, "workload", "Alpha", ["uses `dp-*` namespaces", "cluster <name>"])
d.box(500, 160, 140, 80, "mgmt", "Beta")
d.box(500, 300, 140, 80, "mgmt", "beta")
d.box(700, 160, 140, 80, "mgmt", "Gamma")
d.arrow([(500, 180), (180, 180)], step=1)
d.arrow([(180, 196), (500, 196)], step=2)
d.arrow([(180, 226), (300, 226), (300, 234), (500, 234)])
d.arrow([(30, 395), (300, 395)], loose=True)
d.text(300, 480, "note text")
d.badge(290, 476, 3)
d.text(40, 520, "dim note", 13, "#334155")
d.key("Beta dials out to Alpha", "Beta receives it from Alpha", "three")
for i in d.check():
    print(i)
EOF
)
assert_match "$out" "step 2 reads before step 1" "steps out of reading order are reported"
assert_match "$out" "box 'Gamma' is not on the numbered flow" "a box neither on the flow nor marked context is reported"
assert_match "$out" "duplicate component box: 'beta'" "duplicate component boxes are reported"
assert_match "$out" "box title not capitalised: 'beta'" "lower-case box titles are reported"
assert_match "$out" "step 1 dials out, but arrow" "a dial-out arrow that does not leave its cluster is reported"
assert_match "$out" "step 2: the text's actor is 'Beta' but the arrow starts at Alpha" "an arrow not starting at the step's actor is reported"
assert_match "$out" "jargon in a box detail line" "jargon in box detail lines is reported"
assert_match "$out" "placeholder or issue reference on the canvas" "placeholders on the canvas are reported"
assert_match "$out" "has a cramped bend" "cramped Z-bends are reported"
assert_match "$out" "runs along the border of zone" "arrows hugging a zone border are reported"
assert_match "$out" "badge 3 is closer than 6 px to text 'note text'" "badge clearance from text is enforced"
assert_match "$out" "text contrast .* 'dim note'" "low text contrast is reported"

# 6. stages: one step must not reach two gated stages at once, and stages are reached in order
out=$(py - "$ROOT/docs/diagrams/src" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from svglib import Diagram
d = Diagram("t", "lede")
d.box(40, 120, 140, 80, "mgmt", "Release")
d.box(300, 120, 140, 80, "workload", "Dev")
d.box(300, 260, 140, 80, "workload", "Staging")
d.box(600, 260, 140, 80, "workload", "Production")
d.box(600, 400, 140, 80, "workload", "Canary")
d.arrow([(180, 160), (300, 160)], step=1)
d.arrow([(110, 200), (110, 300), (300, 300)], step=2)
d.arrow([(110, 230), (520, 230), (520, 290), (600, 290)], step=2, badge=False)
d.junction(110, 230)
d.arrow([(110, 260), (110, 440), (600, 440)], step=3)
d.stages("Dev", "Staging", "Production")
d.stages("Canary", "Dev")
d.stages("Dev", "Nowhere")
d.key("Release deploys to dev", "Release deploys to staging and production", "Release deploys to canary")
for i in d.check():
    print(i)
EOF
)
assert_match "$out" "step 2 reaches stages 'Staging' and 'Production' at once" "a fork into two gated stages is reported"
assert_match "$out" "stage 'Dev' is reached in step 1, before stage 'Canary' is done" "stages reached out of order are reported"
assert_match "$out" "stage 'Nowhere' is not a box" "an unknown stage is reported"

# 7. reading order: consecutive steps of the same actor may radiate in any direction (check, then open a PR)
out=$(py - "$ROOT/docs/diagrams/src" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
from svglib import Diagram
d = Diagram("t", "lede")
d.box(40, 300, 140, 80, "mgmt", "Gate")
d.box(400, 120, 140, 80, "external", "Repo")
d.box(400, 300, 140, 80, "workload", "Env")
d.arrow([(180, 340), (400, 340)], step=1)
d.arrow([(110, 300), (110, 160), (400, 160)], step=2, badge=(110, 260))
d.arrow([(400, 130), (160, 130), (160, 300)], step=3, badge=(300, 130))
d.key("Gate checks env", "Gate opens a PR in the repo", "Repo notifies the gate")
for i in d.check():
    print(i)
EOF
)
n=$(grep -c "step 2 reads before step 1" <<<"$out" || true)
assert_eq "$n" 0 "the same actor's next step may sit anywhere around it"
n=$(grep -c "step 3 reads before step 2" <<<"$out" || true)
assert_eq "$n" 1 "another actor's step still has to read after it"

# 8. sdlc swimlanes: the legend explains the change-flow arrows and the MANUAL chip, and the workload legend names
#    the local profile (one workload cluster, a namespace per environment)
svg=$(cat "$ROOT/docs/diagrams/sdlc.svg")
assert_match "$svg" "the change moves along the arrow" "sdlc legend: arrows follow the change"
assert_match "$svg" ">MANUAL</text>.*a person merges a pull request" "sdlc legend explains the MANUAL chip"
assert_match "$svg" "local default: one, with a namespace per environment" "sdlc legend names the local profile"

# stale SVG and README steps drift are reported by --check
mkdir -p "$TMP/stale"
cp "$ROOT"/docs/diagrams/*.svg "$TMP/stale/"
printf '<!-- hand edit -->\n' >> "$TMP/stale/network.svg"
out=$(py "$B" --check --out "$TMP/stale" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 1 "a hand-edited SVG fails --check"
assert_match "$out" "network.svg is not up to date" "stale SVG is named"
sed 's/^1\. Argo CD reads Git/1. Argo CD pulls Git/' "$ROOT/docs/diagrams/README.md" > "$TMP/README.md"
out=$(py "$B" --check --readme "$TMP/README.md" architecture 2>&1) && rc=0 || rc=$?
assert_eq "$rc" 1 "README step drift fails --check"
assert_match "$out" "steps differ from docs/diagrams/README.md" "step drift is named"

finish
