{{- /*
koorikla-lib.sourceIntegrity (root context; values sourceIntegrity.{enabled,mode,keys,repos}, repos go through tpl).
Users: charts/platform (AppProjects platform, fleet, tenants), charts/tenant (AppProject tenant-<project>).
AppProject spec.sourceIntegrity: Git commit signature policy (Argo CD 3.5+; replaces the deprecated signatureKeys),
see docs/supply-chain.md. Renders nothing when disabled; indented for direct use under `spec:`.
*/ -}}
{{- define "koorikla-lib.sourceIntegrity" -}}
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
