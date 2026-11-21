---
title: Crossplane Project CLI - Paths Under apis/ and Derived Function Names
created: 2026-11-21
updated: 2026-11-21
type: gotcha
tags: [data, ci, devex]
confidence: high
---

# Crossplane Project CLI - Paths Under apis/ and Derived Function Names

## Symptom
Following the CLI 2.4.1 Project inner loop (docs/crossplane.md "Inner loop", #240): `crossplane function generate
compose-x apis/x/composition.yaml` fails with `pipeline path ... does not exist`, or a built package installs but its
Composition reports an unknown Function.

## Cause
- `xrd generate --path` and `composition generate --path` are relative to `apis/`; without `--path` the Composition
  lands in `apis/<plural>/`, not next to an XRD written with `--path x/definition.yaml`.
- The embedded function's name is derived from `spec.repository` (host dropped, `/` -> `-`) + the function directory:
  `ghcr.io/koorikla/platform/mysql` + `compose-mysql` = `koorikla-platform-mysqlcompose-mysql`. Building or pushing with
  another `--repository` renames it, while the Composition's `functionRef` keeps the old name.
- `composition generate` adds `function-auto-ready` with `>=v0.0.0`; `crossplane dependency add '<pkg>:>=vX'` sets a
  real floor.
- `mise -C <dir> exec -- crossplane project init` runs in `<dir>`: scaffold in a scratch dir with
  `mise exec crossplane@<v> -- crossplane ...` instead.

## Fix
- Pass both `--path <api>/definition.yaml` and `--path <api>/composition.yaml`; keep the repository identical in
  `crossplane-project.yaml`, CI (`ghcr.io/<owner>/<name>`, owner lowercased) and the Composition
  (`hack/tests/test_crossplane_packages.sh`, `hack/tests/test_crossplane_api_template.sh` assert it).
