{{- /* AppProject spec.sourceIntegrity (Argo CD 3.5+; docs/supply-chain.md). Empty when disabled. */ -}}
{{- define "platform.sourceIntegrity" -}}
{{- with .Values.sourceIntegrity }}{{ if .enabled }}
  sourceIntegrity:
    git:
      policies:
        - repos:
            {{- range .repos }}
            - url: {{ tpl . $ | quote }}
            {{- end }}
          gpg:
            mode: {{ .mode }}
            keys: {{ required "sourceIntegrity.keys must list GnuPG key IDs" .keys | toJson }}
{{- end }}{{ end -}}
{{- end }}
