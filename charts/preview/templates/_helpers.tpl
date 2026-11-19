{{- /* Environment pr-<n>-<component>: unique per org namespace (Component names are). */ -}}
{{- define "preview.environment" -}}
pr-{{ .Values.pullRequest }}-{{ .Values.component }}
{{- end }}

{{- define "preview.labels" -}}
platform.koorikla.io/preview: "true"
platform.koorikla.io/tenant: {{ .Values.project }}
platform.koorikla.io/component: {{ .Values.component }}
platform.koorikla.io/pull-request: {{ .Values.pullRequest | toString | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "preview.annotations" -}}
platform.koorikla.io/commit: {{ .Values.commit | toString | quote }}
{{- with .Values.repository }}
platform.koorikla.io/repository: {{ . | quote }}
{{- end }}
{{- with .Values.branch }}
platform.koorikla.io/branch: {{ . | quote }}
{{- end }}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
