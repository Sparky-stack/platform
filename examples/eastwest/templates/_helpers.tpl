{{- define "eastwest.labels" -}}
app.kubernetes.io/part-of: eastwest-example
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* Pod Security restricted: non-root numeric UID, no privilege escalation, no capabilities, RuntimeDefault seccomp. */ -}}
{{- define "eastwest.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
