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
{{- $out = append $out (dict "name" $n "repoURL" (required (printf "apps[%d].repoURL is required" $i) $a.repoURL) "path" ($a.path | default $.Values.defaults.path) "revision" ($a.revision | default $.Values.defaults.revision) "promotionGates" (ne (toString (dig "promotionGates" true $a)) "false")) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{- /* Gated environments that apply to an app: [] when the app opts out (promotionGates: false). */ -}}
{{- define "tenant.gatedEnvs" -}}
{{- $app := index . 0 -}}{{- $root := index . 1 -}}
{{- if not $app.promotionGates -}}[]{{- else -}}{{- $root.Values.promotion.gatedEnvironments | default list | toYaml -}}{{- end -}}
{{- end }}

{{- /* Binding file of an environment, relative to the app path. */ -}}
{{- define "tenant.bindingFile" -}}
{{- $env := index . 0 -}}{{- $root := index . 1 -}}
{{- $root.Values.promotion.bindingFile | replace "{environment}" $env -}}
{{- end }}

{{- /*
Weekly freeze window {start: "Fri 16:00", end: "Mon 08:00"} -> Argo CD sync window cron + duration. Windows wrap
around the end of the week. Cron day of week: Sun=0 .. Sat=6.
*/ -}}
{{- define "tenant.minuteOfWeek" -}}
{{- $m := regexFind "^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ([01]?[0-9]|2[0-3]):([0-5][0-9])$" . -}}
{{- if not $m -}}{{- fail (printf "promotion.freezeWindows: bad bound %q (want e.g. \"Fri 16:00\")" .) -}}{{- end -}}
{{- $parts := regexSplit "[ :]" . -1 -}}
{{- $day := index (dict "Mon" 0 "Tue" 1 "Wed" 2 "Thu" 3 "Fri" 4 "Sat" 5 "Sun" 6) (index $parts 0) -}}
{{- add (mul $day 1440) (mul (atoi (index $parts 1)) 60) (atoi (index $parts 2)) -}}
{{- end }}

{{- define "tenant.syncWindowTiming" -}}
{{- $start := include "tenant.minuteOfWeek" .start | atoi -}}
{{- $end := include "tenant.minuteOfWeek" .end | atoi -}}
{{- $dur := mod (add (sub $end $start) 10080) 10080 -}}
{{- if eq $dur 0 -}}{{- fail (printf "promotion.freezeWindows %q: start == end" (.name | default .start)) -}}{{- end -}}
{{- $parts := regexSplit "[ :]" .start -1 -}}
{{- $cronDay := index (dict "Sun" 0 "Mon" 1 "Tue" 2 "Wed" 3 "Thu" 4 "Fri" 5 "Sat" 6) (index $parts 0) -}}
schedule: {{ printf "%d %d * * %d" (atoi (index $parts 2)) (atoi (index $parts 1)) $cronDay | quote }}
duration: {{ if eq (mod $dur 60) 0 }}{{ printf "%dh" (div $dur 60) }}{{ else }}{{ printf "%dh%dm" (div $dur 60) (mod $dur 60) }}{{ end }}
{{- end }}
