{{- define "tenant.project" -}}
{{- $p := required "project is required (tenant file)" .Values.project -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $p) -}}
{{- fail (printf "project %q must be a DNS-1123 label" $p) -}}
{{- end -}}
{{- if gt (len $p) 50 -}}{{- fail (printf "project %q is longer than 50 characters" $p) -}}{{- end -}}
{{- $p -}}
{{- end }}

{{- define "tenant.labels" -}}
platform.koorikla.io/tenant: {{ include "tenant.project" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* Validated app list with defaults applied, as YAML (consume with fromYamlArray). */ -}}
{{- define "tenant.apps" -}}
{{- $seen := dict -}}
{{- $out := list -}}
{{- range $i, $a := .Values.apps -}}
{{- $n := required (printf "apps[%d].name is required" $i) $a.name -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $n) -}}{{- fail (printf "apps[%d].name %q must be a DNS-1123 label" $i $n) -}}{{- end -}}
{{- if hasKey $seen $n -}}{{- fail (printf "apps: duplicate name %q" $n) -}}{{- end -}}
{{- $_ := set $seen $n true -}}
{{- $out = append $out (dict "name" $n "repoURL" (required (printf "apps[%d].repoURL is required" $i) $a.repoURL) "path" ($a.path | default $.Values.defaults.path) "revision" ($a.revision | default $.Values.defaults.revision)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}
