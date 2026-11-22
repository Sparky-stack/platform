{{- /* "true" unless the preview is off for this PR: expired (TTL), waiting (per-tenant cap, #385) or a bot PR without
the opt-in label. Off renders nothing, so Argo CD prunes the preview (or never creates it). */ -}}
{{- define "preview.on" -}}
{{- if or (eq (toString .Values.expired) "true") (eq (toString .Values.waiting) "true") (eq (toString .Values.bot) "true") -}}
false
{{- else -}}
true
{{- end -}}
{{- end }}

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
