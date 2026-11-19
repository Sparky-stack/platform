#!/usr/bin/env bash
# Argo CD compare options (#184): every addon that renders Argo Workflows objects must set
# compareOptions [IncludeMutationWebhook=true] (charts/platform values.yaml), and no other addon may.
#
# Why: the argo-workflows CRDs (crds.full: false) declare `spec` as x-kubernetes-map-type: atomic +
# x-kubernetes-preserve-unknown-fields. The API server then records Argo's ownership as `f:spec: {}`, while Argo CD's
# GVK parser (built from /openapi/v2, where that spec has no type) treats spec as a granular map. Server-side diff's
# mutation-webhook filter (removeWebhookMutation) therefore classifies every field under spec as "not owned by
# argocd-controller" and reverts it to the live value: the app reports Synced at the new revision and never applies a
# changed ClusterWorkflowTemplate / WorkflowTemplate / CronWorkflow (argoproj/argo-cd#27625). IncludeMutationWebhook
# skips that filter; the diff is still computed server-side from the apiserver's dry-run apply.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

render_platform local "$TMP/platform.yaml"

# Kinds whose CRD spec is atomic + preserve-unknown on the platform (live check:
# kubectl get crd -o json | jq '... select(x-kubernetes-map-type == "atomic" and preserve-unknown)').
kinds='^kind: (ClusterWorkflowTemplate|WorkflowTemplate|CronWorkflow|Workflow)[[:space:]]*$'

# 0. self-check: the grep sees the known workflow templates (a moved file must not silently disable this test)
self=$(grep -cE "$kinds" "$ROOT/addons/openchoreo-workflow-plane/files/cluster-workflow-templates/koorikla-build.yaml" || true)
assert_eq "$self" "1" "kind pattern matches koorikla-build.yaml"

while IFS=$'\t' read -r appset path opts; do
  srcs=()
  for d in templates files; do [[ -d "$ROOT/$path/$d" ]] && srcs+=("$ROOT/$path/$d"); done
  renders=no
  if ((${#srcs[@]})) && grep -rqE "$kinds" "${srcs[@]}"; then renders=yes; fi
  has=no
  [[ ",$opts," == *",IncludeMutationWebhook=true,"* ]] && has=yes
  assert_eq "$has" "$renders" "$appset ($path): IncludeMutationWebhook=true iff it renders Argo Workflows objects"
done < <(yq -r 'select(.kind == "ApplicationSet" and (.metadata.name | test("^addon-"))) |
  [.metadata.name, .spec.template.spec.source.path,
   (.spec.template.metadata.annotations["argocd.argoproj.io/compare-options"] // "")] | @tsv' "$TMP/platform.yaml")

finish
