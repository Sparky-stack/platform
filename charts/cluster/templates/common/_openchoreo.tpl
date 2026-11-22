{{- /* Shared labels of openchoreo-*.yaml. */ -}}
{{- define "openchoreo.labels" -}}
platform.koorikla.io/name: {{ .Values.name }}
app.kubernetes.io/part-of: openchoreo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
