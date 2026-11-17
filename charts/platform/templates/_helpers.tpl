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

{{- /* ApplicationSet goTemplate targetRevision: cluster secret annotation addons-revision, else installation.revision. */ -}}
{{- define "platform.addonsTargetRevision" -}}
{{- $defaultRev := .Values.installation.revision | default "HEAD" -}}
'{{ "{{" }} $r := index .metadata.annotations "platform.koorikla.io/addons-revision" {{ "}}" }}{{ "{{" }} if and $r (ne $r "HEAD") {{ "}}" }}{{ "{{" }} $r {{ "}}" }}{{ "{{" }} else {{ "}}" }}{{ $defaultRev }}{{ "{{" }} end {{ "}}" }}'
{{- end }}
