{{- /*
objectSelector of the OpenChoreo cell namespaces a namespace policy acts on: ambientEnrollment.cellNamespaceSelector
plus one extra expression on istio.io/dataplane-mode (ambient-enrollment.yaml: not yet set; cell-mesh.yaml: not none).
Call with (dict "sel" <selector> "mode" <matchExpression flow map>), indent 4.
*/ -}}
{{- define "kp.cellObjectSelector" -}}
objectSelector:
  {{- with .sel.matchLabels }}
  matchLabels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  matchExpressions:
    {{- with .sel.matchExpressions }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    - {{ .mode }}
{{- end }}
