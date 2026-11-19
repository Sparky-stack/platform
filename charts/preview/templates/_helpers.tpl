{{- /* Validated identity of the preview (fails the render on anything malformed: values come from GitHub). */ -}}
{{- define "preview.validate" -}}
{{- $c := required "component is required" .Values.component -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $c) -}}{{- fail (printf "component %q must be a DNS-1123 label" $c) -}}{{- end -}}
{{- $p := required "project is required" .Values.project -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $p) -}}{{- fail (printf "project %q must be a DNS-1123 label" $p) -}}{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]{0,6}$" (toString .Values.pullRequest)) -}}{{- fail (printf "pullRequest %q must be a pull request number" (toString .Values.pullRequest)) -}}{{- end -}}
{{- if not (regexMatch "^[0-9a-f]{40}$" (toString .Values.commit)) -}}{{- fail (printf "commit %q must be a 40-hex commit SHA" (toString .Values.commit)) -}}{{- end -}}
{{- /* The external route host is <environment>-<org namespace>.<gateway host> (upstream ClusterComponentType): one DNS label. */ -}}
{{- $host := printf "%s-%s" (include "preview.environment" .) .Values.openchoreo.orgNamespace -}}
{{- if gt (len $host) 63 -}}{{- fail (printf "preview host label %q is longer than 63 characters (shorten the component name)" $host) -}}{{- end -}}
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
