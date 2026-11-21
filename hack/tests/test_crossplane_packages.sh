#!/usr/bin/env bash
# Contract: every platform API package is a Crossplane Project (CLI 2.4 Project tooling, docs/crossplane.md
# "Inner loop") wired to the same CI - packages/postgresql, packages/mysql, packages/valkey, packages/bucket,
# packages/kafka-topic:
#   - crossplane-project.yaml (no classic crossplane.yaml), repository ghcr.io/koorikla/platform/<p>, apis/<p>/ with one
#     XRD + Composition whose pipeline calls the embedded function functions/compose-<p>/, generated dirs gitignored;
#   - .github/workflows/package-<p>.yaml calls app-crossplane-configuration.yaml for packages/<p>, release-please
#     component <p>;
#   - XP_PACKAGE_BUILD=1 (default when the crossplane CLI is on PATH; needs network for dependencies): `crossplane
#     project build` of a copy of each package yields the Configuration (XRD + Composition == source, the embedded
#     function pinned by digest) and the function image for amd64 + arm64.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

PACKAGES="postgresql mysql valkey bucket kafka-topic"
assert_eq "$(find packages -mindepth 1 -maxdepth 1 -type d | sed 's|^packages/||' | sort | tr '\n' ' ')" \
  "$(tr ' ' '\n' <<<"$PACKAGES" | sort | tr '\n' ' ')" "packages/* == the API packages this test knows"

for p in $PACKAGES; do
  d=packages/$p; pf=$d/crossplane-project.yaml; fn=koorikla-platform-${p}compose-$p
  assert_eq "$(yq -r '.apiVersion + " " + .kind + " " + .metadata.name' "$pf" 2>/dev/null)" "dev.crossplane.io/v1alpha1 Project $p" "$p: crossplane-project.yaml is Project $p"
  assert_eq "$([[ -e $d/crossplane.yaml ]] && echo classic || echo project)" project "$p: no classic crossplane.yaml next to the project file"
  assert_eq "$(yq -r '.spec.repository' "$pf")" "ghcr.io/koorikla/platform/$p" "$p: repository (names the embedded function)"
  assert_eq "$(yq -r '.spec.source' "$pf")" "github.com/koorikla/platform/tree/main/packages/$p" "$p: package source"
  assert_nonempty "$(yq -r '.spec.crossplane.version' "$pf")" "$p: crossplane version constraint"
  for sub in apis examples functions operations tests/render; do
    assert_eq "$([[ -d $d/$sub ]] && echo yes)" yes "$p: has $sub/ (crossplane project init layout)"
  done
  assert_eq "$(find "$d/apis" -name '*.yaml' | sort | tr '\n' ' ')" "$d/apis/$p/composition.yaml $d/apis/$p/definition.yaml " "$p: apis/$p/ holds one XRD and one Composition"
  assert_eq "$(yq -r '[.spec.pipeline[].functionRef.name] | join(" ")' "$d/apis/$p/composition.yaml")" \
    "function-environment-configs $fn function-auto-ready" "$p: pipeline environment -> embedded compose-$p -> auto-ready"
  assert_nonempty "$(find "$d/functions/compose-$p" -name '*.gotmpl' 2>/dev/null | head -n1)" "$p: embedded function functions/compose-$p/ (crossplane function generate)"
  assert_eq "$(grep -cxE '_output/|schemas/|\.cache/' "$d/.gitignore" 2>/dev/null)" 3 "$p: _output/, schemas/, .cache/ gitignored"
  wf=.github/workflows/package-$p.yaml
  assert_eq "$(yq -r '.jobs.package.uses + " " + .jobs.package.with.package_root + " " + .jobs.package.with.registry' "$wf" 2>/dev/null)" \
    "./.github/workflows/app-crossplane-configuration.yaml packages/$p ghcr.io/koorikla/platform" "$p: $wf calls the reusable configuration workflow"
  assert_eq "$(yq -r '[.on.pull_request.paths[]] | join(" ")' "$wf")" "packages/$p/** $wf" "$p: PRs touching packages/$p run its workflow"
  assert_eq "$(k=$d yq -p=json -oy -r '.packages[strenv(k)].component // ""' release-please-config.json)" "$p" "$p: release-please component"
done

# --- crossplane project build --------------------------------------------------------------------------------------
# xpkg_package_yaml <xpkg> <repo>: package.yaml of the Configuration image (<repo>:configuration) in a project .xpkg
xpkg_package_yaml() {
  local layer
  for layer in $(tar -xOf "$1" manifest.json | yq -p=json -oy -r ".[] | select(.RepoTags[0] == \"$2:configuration\") | .Layers[]"); do
    tar -xOf "$1" "$layer" | tar -xzO package.yaml 2>/dev/null && return 0
  done
  return 1
}
if [[ "${XP_PACKAGE_BUILD:-1}" == 1 ]] && command -v crossplane >/dev/null 2>&1; then
  pids=()
  for p in $PACKAGES; do   # copies: the build writes schemas/ into the project; one cache per build (no shared writes)
    mkdir -p "$TMP/src"; cp -R "packages/$p" "$TMP/src/$p"
    (cd "$TMP/src/$p" && crossplane project build --repository "ghcr.io/koorikla/platform/$p" -o "$TMP/out/$p" \
      --cache-dir "$TMP/cache/$p" > "$TMP/build-$p.log" 2>&1) &
    pids+=("$!")
  done
  i=0
  for p in $PACKAGES; do
    repo=ghcr.io/koorikla/platform/$p; x=$TMP/out/$p/$p.xpkg; fn=koorikla-platform-${p}compose-$p
    if wait "${pids[$i]}" && [[ -s "$x" ]]; then ok=yes; else ok=no; tail -n 5 "$TMP/build-$p.log" >&2; fi
    i=$((i + 1))
    assert_eq "$ok" yes "$p: crossplane project build"
    [[ "$ok" == yes ]] || continue
    assert_eq "$(tar -xOf "$x" manifest.json | yq -p=json -oy -r '[.[].RepoTags[0]] | sort | join(" ")')" \
      "${repo}:configuration ${repo}_compose-$p:amd64 ${repo}_compose-$p:arm64" "$p: xpkg = Configuration + embedded function (amd64, arm64)"
    xpkg_package_yaml "$x" "$repo" > "$TMP/$p-package.yaml" || true
    for k in CompositeResourceDefinition:definition Composition:composition; do
      want=$(yq -o=json -I=0 '{"name": .metadata.name, "spec": .spec} | sort_keys(..)' "packages/$p/apis/$p/${k#*:}.yaml")
      got=$(yq -o=json -I=0 "select(.kind == \"${k%%:*}\") | {\"name\": .metadata.name, \"spec\": .spec} | sort_keys(..)" "$TMP/$p-package.yaml")
      assert_eq "$([[ -n "$got" && "$got" == "$want" ]] && echo same || echo differs)" same "$p: packaged ${k%%:*} (name + spec) == apis/$p/${k#*:}.yaml"
    done
    assert_match "$(yq -r "select(.kind == \"Configuration\") | .spec.dependsOn[] | select(.package == \"${repo}_compose-$p\") | .version" "$TMP/$p-package.yaml")" \
      '^sha256:[0-9a-f]{64}$' "$p: Configuration depends on the embedded function by digest ($fn)"
  done
else
  echo "  SKIP crossplane project build (XP_PACKAGE_BUILD=1 and the crossplane CLI: mise.toml)"
fi

finish
