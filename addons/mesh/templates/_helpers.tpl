{{- /* This member's mesh group (catalog clusterLabelParameters). The catalog selects the addon only on clusters whose
fleet file sets mesh.group (values/mesh-member.yaml turns mesh.csr.enabled on there), so "" means a standalone render: the Issuer is then left out (templates/csr-issuer.yaml). Format: values.schema.json. */ -}}
{{- define "mesh.group" -}}
{{- .Values.mesh.group | default "" -}}
{{- end }}

{{- /* This cluster's name (DNS label, required: values.schema.json). */ -}}
{{- define "mesh.cluster" -}}
{{- .Values.cluster.name -}}
{{- end }}

{{- define "mesh.labels" -}}
app.kubernetes.io/part-of: istio-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
