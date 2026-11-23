{{- /* "true" only for a PR the auto-build pass granted a slot of the tenant's cap (#385) that is neither expired (TTL)
nor a bot PR without the opt-in label. Default off: renders nothing, so no Environment exists before the grant and
Argo CD prunes a preview that loses it. */ -}}
{{- define "preview.on" -}}
{{- if and (eq (toString .Values.granted) "true") (ne (toString .Values.expired) "true") (ne (toString .Values.bot) "true") -}}
true
{{- else -}}
false
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
