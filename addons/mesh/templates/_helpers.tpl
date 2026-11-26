{{- define "mesh.labels" -}}
app.kubernetes.io/part-of: istio-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
