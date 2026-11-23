{{- /* registry.host without its :port (Gateway listener hostname, serving cert, route hosts). */ -}}
{{- define "harbor-addon.hostname" -}}
{{- regexReplaceAll ":[0-9]+$" .Values.registry.host "" -}}
{{- end }}
