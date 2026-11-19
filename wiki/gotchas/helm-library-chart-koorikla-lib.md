---
title: Helm Library Chart koorikla-lib (file:// Dependency)
created: 2026-11-19
updated: 2026-11-19
type: gotcha
tags: [argocd, ci]
confidence: high
---

# Helm Library Chart koorikla-lib (file:// Dependency)

## Symptom
Blocks shared by several charts live once in [`charts/lib`](../../charts/lib/README.md) (#116). Wiring it in has four
non-obvious failure modes:
- After a dependency is added, every `.Values` dump gains the subchart's values scope (`koorikla-lib: {global: {}}`):
  `charts/platform` passed it to every addon as an installation value.
- Edits to the library did not reach consumers: `hack/deps.sh` (and CI's chart cache, keyed on `Chart.lock`) keep
  the vendored koorikla-lib-0.1.0.tgz, whose name does not change with its templates.
- `helm unittest charts/lib` cannot test anything: a library chart only loads `_*.tpl` partials (Helm drops its other
  templates), so a fixture template there renders nothing.
- `helm-docs` skips a chart without `values.yaml`.

## Cause
Helm merges each dependency's values under its name into the parent's `.Values`; tarball caches key on
`name-version.tgz`; Helm's engine treats library charts as partials only; helm-docs requires `values.yaml`.

## Fix
- `charts/platform/templates/appset-addons.yaml`: `omit .Values "addons" "koorikla-lib"`.
- `hack/deps.sh` re-packages every `file://` dependency on each run (offline, about a second).
- Unit tests live in the harness chart [`charts/lib-test`](../../charts/lib-test/README.md): an application chart that
  depends on the library, one fixture template per helper.
- `charts/lib/values.yaml` is `{}`.

Argo CD needs nothing special: its repo-server runs `helm dependency build` after the "missing in charts/ directory"
error, registers only https/oci repositories and leaves `file://` paths to Helm, which resolves them inside the cloned
repo (checked with the Argo CD v3.6.1 image and its Helm v4.3.1). Renovate's helmv3 manager skips local dependencies.

## Where enforced
- `charts/lib-test/tests/` (helpers) and each consumer's `tests/` (helm unittest, `task test`).
- `hack/deps.sh` + `hack/tests/test_chart_locks.sh`: consumers' `Chart.lock` in sync, library re-packaged per run.

## Links
- [Helm, Crossplane, and OpenChoreo building blocks](../decisions/building-blocks-helm-crossplane-openchoreo.md)
- [Merge capi-providers and clusterclasses into charts/cluster](../decisions/merge-clusterclasses-into-charts-cluster.md)
- [docs/conventions.md: layout](../../docs/conventions.md#layout-and-ownership)
