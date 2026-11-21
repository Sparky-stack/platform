#!/usr/bin/env bash
# hack/check-docs.py (task lint): Markdown links, anchors, "doc.md "Section"" references, repo paths in code spans and
# task commands must resolve (make commands are rejected). Negative cases on a fixture first, then the real repo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

fx="$TMP/repo"
mkdir -p "$fx/docs" "$fx/hack" "$fx/addons/a/charts/dep"
cat > "$fx/addons/a/README.md" <<'EOF'
# a
## Purpose
## Where it runs
## Key values
## Day-2 notes
## Links
EOF
printf 'tasks:\n  up:\n    cmds: []\n  images:audit:\n    cmds: []\n' > "$fx/Taskfile.yml"
touch "$fx/hack/real.sh"
cat > "$fx/docs/target.md" <<'EOF'
# Target
## Some Section
### Node pulls: mirrors with fallback
EOF
cat > "$fx/README.md" <<'EOF'
# Readme
[ok](docs/target.md#some-section) [ok2](docs/target.md#node-pulls-mirrors-with-fallback) [web](https://example.com)
[self](#readme) `hack/real.sh` `addons/<addon>/values.yaml` `task up` `task images:audit`
docs/target.md "Some Section" and `target.md` "Node pulls"
```bash
task up
```
EOF
cp -R "$fx" "$TMP/good"
capture py "$ROOT/hack/check-docs.py" "$TMP/good"
assert_eq "$RC" 0 "clean fixture passes"
assert_match "$OUT" "docs check OK" "clean fixture reports OK"

cat >> "$fx/README.md" <<'EOF'
[missing](docs/nope.md) [anchor](docs/target.md#nope) <img src="docs/img.png">
`hack/gone.sh` docs/target.md "No Such Section" docs/absent.md
`task nope` `make up`
```
task missing-in-block
```
EOF
echo '[vendored](nope.md)' > "$fx/addons/a/charts/dep/README.md"
mkdir -p "$fx/templates/t/skeleton"
cat > "$fx/templates/t/skeleton/README.md" <<'EOF'
`hack/in-the-new-repo.sh` [rel](docs/in-the-new-repo.md)
EOF
capture py "$ROOT/hack/check-docs.py" "$fx"
assert_eq "$RC" 1 "broken fixture fails"
assert_matches "$OUT" <<'CASES'
missing link target | link target docs/nope.md does not exist
missing anchor | no heading #nope
missing <img src> | link target docs/img.png does not exist
missing repo path in a code span | path hack/gone.sh does not exist
missing section reference | has no section "No Such Section"
missing bare docs/ reference | docs/absent.md does not exist
unknown task | task nope. is not a Taskfile task
make target rejected with task hint | make up. is not supported \(use .task.\)
unknown task in a code block | task missing-in-block. is not a Taskfile task
CASES
assert_eq "$(grep -c 'charts/dep' <<<"$OUT" || true)" 0 "vendored chart docs are skipped"
assert_eq "$(grep -c 'templates/t/skeleton' <<<"$OUT" || true)" 0 "project-template skeleton docs are skipped"
assert_eq "$(grep -c 'FAIL' <<<"$OUT")" 9 "exactly the planted problems"

cp -R "$TMP/good" "$TMP/ops"
mkdir -p "$TMP/ops/docs/runbooks"
printf '# Operations\n[ok](runbooks/ok.md)\n' > "$TMP/ops/docs/operations.md"
cat > "$TMP/ops/docs/runbooks/ok.md" <<'EOF'
# Ok
## When to use
## Symptoms
## Steps
```bash
kubectl --context k3d-platform-mgmt get nodes
```
## Verify
## Rollback
## Related links
- [Operations](../operations.md)
EOF
capture py "$ROOT/hack/check-docs.py" "$TMP/ops"
assert_eq "$RC" 0 "clean runbook fixture passes ($OUT)"

cat > "$TMP/ops/docs/runbooks/orphan.md" <<'EOF'
# Orphan
## When to use
## Symptoms
## Steps
```bash
kubectl get pods
kubectl --context koorikla get nodes
```
## Verify
## Related links
EOF
capture py "$ROOT/hack/check-docs.py" "$TMP/ops"
assert_eq "$RC" 1 "broken runbook fixture fails"
assert_matches "$OUT" <<'CASES'
missing runbook section | runbook missing section "rollback"
bare kubectl in runbook | must pass --context or --kubeconfig
homelab context rejected | forbidden kube context .koorikla.
unindexed runbook rejected | runbook docs/runbooks/orphan.md is not linked
CASES

cp -R "$TMP/good" "$TMP/readmes"
mkdir -p "$TMP/readmes/charts/no-readme" "$TMP/readmes/addons/incomplete" "$TMP/readmes/addons/toolong" "$TMP/readmes/addons/stale"
printf 'apiVersion: v2\nname: no-readme\nversion: 0.1.0\n' > "$TMP/readmes/charts/no-readme/Chart.yaml"
mkdir -p "$TMP/readmes/addons/deleted/charts" # leftover of a deleted addon (CI chart cache): not a chart
cat > "$TMP/readmes/addons/incomplete/README.md" <<'EOF'
# incomplete
## Purpose
## Where it runs
## Key values
## Links
EOF
{
  printf '# toolong\n## Purpose\n## Where it runs\n## Key values\n| Key | Type | Default | Description |\n|---|---|---|---|\n'
  printf '| k | string | v | row |\n%.0s' {1..30}
  printf '## Day-2 notes\n## Links\n'
  printf 'line\n%.0s' {1..36}
} > "$TMP/readmes/addons/toolong/README.md"
cat > "$TMP/readmes/addons/stale/README.md" <<'EOF'
# stale
## Purpose
## Where it runs
## Key values
## Day-2 notes
## Links
EOF
printf '# -- Documented knob missing from README.md.
knob: true
' > "$TMP/readmes/addons/stale/values.yaml"
capture py "$ROOT/hack/check-docs.py" "$TMP/readmes"
assert_eq "$RC" 1 "missing, malformed or stale chart/addon READMEs fail"
assert_match "$OUT" "charts/no-readme/README.md: missing README.md" "missing chart README rejected"
assert_eq "$(grep -c addons/deleted <<<"$OUT")" 0 "dir without Chart.yaml (cached charts/ of a deleted addon) ignored"
assert_matches "$OUT" <<'CASES'
missing addon README section rejected | README missing section "day-2 notes"
overlong addon README rejected (table lines ignored) | README is 42 lines \(max 40\)
stale chart README rejected | addons/stale/README.md: stale README.md
CASES

# Mermaid (#355): the rule is in check-docs (always run by scoped PR CI), so a fence alone fails a docs-only change.
# Fence variants and vendored-dep skipping: hack/tests/test_no_mermaid.sh.
cp -R "$TMP/good" "$TMP/mermaid"
# shellcheck disable=SC2016  # literal Markdown backticks
printf '# M\n```mermaid\ngraph LR\n```\n' > "$TMP/mermaid/docs/m.md"
capture py "$ROOT/hack/check-docs.py" "$TMP/mermaid"
assert_eq "$RC" 1 "a Mermaid fence in a doc fails check-docs"
assert_match "$OUT" "docs/m.md:2: Mermaid fence; draw it in docs/diagrams/src/build.py" "Mermaid fence reported with line and fix"
assert_eq "$(grep -c 'FAIL' <<<"$OUT")" 1 "only the Mermaid fence fails"

capture py "$ROOT/hack/check-docs.py"
assert_eq "$RC" 0 "repo docs resolve ($OUT)"

finish
