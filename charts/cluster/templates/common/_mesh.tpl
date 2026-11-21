{{- /* Shared helpers for mesh-*.yaml (mesh.group, mesh.rootKey, mesh.readerUser, mesh.labels); renders no resources. */ -}}
{{- define "mesh.group" -}}
{{- .Values.mesh.group -}}
{{- end }}
{{- define "mesh.rootKey" -}}mesh-root-{{ include "mesh.group" . }}.pem{{- end }}
{{- define "mesh.readerUser" -}}platform:istio-reader{{- end }}
{{- define "mesh.labels" -}}
platform.koorikla.io/name: {{ .Values.name }}
mesh.platform.koorikla.io/group: {{ include "mesh.group" . }}
app.kubernetes.io/part-of: istio-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
