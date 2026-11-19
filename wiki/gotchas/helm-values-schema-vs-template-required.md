---
title: Helm values.schema.json vs Template required/fail
created: 2026-11-19
updated: 2026-11-19
type: gotcha
tags: [ci]
confidence: high
---

# Helm values.schema.json vs Template required/fail

## Symptom
Moving a `required`/`fail` into `values.schema.json` (#116) broke `hack/lint.sh` for charts whose default is empty
(`cilium.k8sServiceHost: ""`, the preview identity, the tenant `project`), although every installation still rendered.
helm-unittest asserts with `errorMessage` on the old template message failed.

## Cause
- `helm lint <chart>` (hack/lint.sh lints with chart defaults) logs a template `fail` as INFO and passes, but a schema
  violation is an ERROR. A key required in the schema with an empty default therefore fails lint.
- Helm validates the coalesced values (subchart defaults included) before any template runs, with messages like
  `at '/llm/provider': value must be one of ...`. `--set key=null` deletes the key, so only `required: [key]` catches it.

## Fix
- Schema: formats, enums and keys that always have a value. For a key that only the installation or ApplicationSet
  fills, allow `""` in the schema pattern (`^(<label>)?$`) and keep the presence check in `templates/validate.yaml`.
- Cross-field rules ("X requires Y", "unless expired", uniqueness) go in `templates/validate.yaml` as well.
- helm-unittest: switch moved checks to `errorPattern` on the schema path; tests of validate.yaml need
  `template: templates/validate.yaml` and the file listed in the suite's `templates:`.

## Where enforced
- `hack/tests/test_values_schema.sh`: every deployable chart has a schema (allowlist with reasons until #116 lands)
  and `helm lint` passes with each installation's values.
- `hack/lint.sh` (chart defaults) and `hack/test.sh` (every installation x cluster render validates the schema).

## Links
- #116; [docs/conventions.md](../../docs/conventions.md) invariant 10.
