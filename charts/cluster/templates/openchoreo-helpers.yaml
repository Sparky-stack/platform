{{- /* Shared helpers for openchoreo-*.yaml (openchoreo.name, fleetNamespace, labels, sync-wave annotations). */ -}}
{{- define "openchoreo.fleetNamespace" -}}fleet{{- end }}
{{- define "openchoreo.name" -}}
{{- required "name is required (cluster file)" .Values.name -}}
{{- end }}
{{- define "openchoreo.labels" -}}
platform.koorikla.io/name: {{ include "openchoreo.name" . }}
app.kubernetes.io/part-of: openchoreo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "openchoreo.crAnnotations" -}}
argocd.argoproj.io/sync-wave: "10"
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
{{- define "openchoreo.environmentAnnotations" -}}
argocd.argoproj.io/sync-wave: "9"
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
