#!/usr/bin/env bash
# hack/gen-reference.py (task lint, prek hook reference-docs): docs/reference/ is generated from the XRDs
# (packages/postgresql, packages/mysql, packages/valkey, packages/bucket, packages/kafka-topic) and the OpenChoreo
# types (addons/openchoreo-platform + packages/*/openchoreo/). --check must fail when a source changes without
# regenerating, when a page is hand-edited, and when a page has no source. Fixture copy first, then the real repo.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"

fx="$TMP/repo"
mkdir -p "$fx/hack" "$fx/docs" "$fx/addons"
cp -R "$ROOT/packages" "$fx/packages"
cp -R "$ROOT/addons/openchoreo-platform" "$fx/addons/openchoreo-platform"
cp -R "$ROOT/docs/reference" "$fx/docs/reference"
cp "$ROOT/hack/gen-reference.py" "$fx/hack/"

check() { capture py "$fx/hack/gen-reference.py" --check "$fx"; }
regen() { py "$fx/hack/gen-reference.py" "$fx" >/dev/null; }

check
assert_eq "$RC" 0 "fresh copy of the committed reference passes"

# An XRD field description changes, docs not regenerated -> stale crossplane-apis.md; regenerating fixes it.
yq -i '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.database.description = "Changed XRD text."' \
  "$fx/packages/mysql/apis/mysql/definition.yaml"
check
assert_eq "$RC" 1 "changed XRD without regenerating fails"
assert_match "$OUT" "crossplane-apis.md" "stale XRD page is named"
regen
check
assert_eq "$RC" 0 "regenerated after the XRD change passes"
assert_match "$(cat "$fx/docs/reference/crossplane-apis.md")" "Changed XRD text." "XRD page carries the new description"

# A chart ClusterTrait (rendered through helm) gains a parameter -> stale openchoreo-traits.md.
yq -i '.spec.parameters.openAPIV3Schema.properties.newKnob = {"type": "string", "default": "x", "description": "New knob."}' \
  "$fx/addons/openchoreo-platform/files/platform/cluster-traits/keda-scaler.yaml"
check
assert_eq "$RC" 1 "changed chart ClusterTrait without regenerating fails"
assert_match "$OUT" "openchoreo-traits.md" "stale traits page is named"
regen
# shellcheck disable=SC2016 # backticks are literal Markdown code spans
assert_match "$(cat "$fx/docs/reference/openchoreo-traits.md")" '`newKnob` \| string \|  \| `x` \| New knob.' \
  "new trait parameter row: field, type, required, default, description"

# A not-yet-deployed package ClusterResourceType (outside the chart) is covered too.
yq -i '.spec.parameters.openAPIV3Schema.properties.extra = {"type": "boolean"}' \
  "$fx/packages/valkey/openchoreo/cluster-resource-type.yaml"
check
assert_eq "$RC" 1 "changed package ClusterResourceType without regenerating fails"
assert_match "$OUT" "openchoreo-resource-types.md" "stale resource-types page is named"
regen

# Hand edits and orphan pages are drift too.
printf 'hand edit\n' >> "$fx/docs/reference/openchoreo-workflows.md"
check
assert_eq "$RC" 1 "hand-edited generated page fails"
regen
printf '# Old\n' > "$fx/docs/reference/old-api.md"
check
assert_eq "$RC" 1 "page without a source fails"
assert_match "$OUT" "old-api.md [(]no source[)]" "orphan page is named"
regen
assert_eq "$(test -e "$fx/docs/reference/old-api.md" && echo yes || echo no)" no "regenerate removes the orphan page"

# The real repo: committed reference matches the sources; every workflow family is present.
capture py "$ROOT/hack/gen-reference.py" --check
assert_eq "$RC" 0 "docs/reference/ in sync with the repo sources ($OUT)"
for name in go promotion-gate helm-chart; do
  assert_match "$(cat "$ROOT/docs/reference/openchoreo-workflows.md")" "## $name" "ClusterWorkflow $name documented"
done
for kind in PostgreSQL MySQL Valkey Bucket KafkaTopic; do
  assert_match "$(cat "$ROOT/docs/reference/crossplane-apis.md")" "## $kind v1alpha1" "XRD $kind documented"
done

finish
