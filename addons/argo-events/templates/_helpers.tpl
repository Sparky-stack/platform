{{- /*
"true" when the Argo Workflows CRDs exist on this cluster (the OpenChoreo workflow plane, addon
openchoreo-workflow-plane): workflowPlane auto asks Capabilities (Argo CD passes the destination cluster's API
versions, kinds included, to helm template) unless installation.yaml turns the plane off
(openchoreo.workflowPlane.enabled: false); "true" / "false" force it. Without them the WorkflowTemplate would fail
to apply (SkipDryRunOnMissingResource only skips the dry run) and the Sensors would create Workflows nobody runs.
*/ -}}
{{- define "ae.workflowPlane" -}}
{{- $m := toString .Values.workflowPlane -}}
{{- if eq $m "auto" -}}
{{- $wp := dig "workflowPlane" "enabled" true (.Values.openchoreo | default dict) -}}
{{- and $wp (.Capabilities.APIVersions.Has "argoproj.io/v1alpha1/WorkflowTemplate") -}}
{{- else if has $m (list "true" "false") -}}
{{- $m -}}
{{- else -}}
{{- fail (printf "workflowPlane: %q is not auto, true or false" $m) -}}
{{- end -}}
{{- end }}
