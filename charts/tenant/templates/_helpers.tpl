{{- define "tenant.project" -}}
{{- required "project is required (tenant file)" .Values.project -}}
{{- end }}

{{- define "tenant.labels" -}}
platform.koorikla.io/tenant: {{ include "tenant.project" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* App list with defaults applied, as YAML (consume with fromYamlArray). Shape: values.schema.json; uniqueness and
reserved names: templates/validate.yaml. */ -}}
{{- define "tenant.apps" -}}
{{- $out := list -}}
{{- range $a := .Values.apps -}}
{{- $out = append $out (dict "name" $a.name "repoURL" $a.repoURL "path" ($a.path | default $.Values.defaults.path) "revision" ($a.revision | default $.Values.defaults.revision) "promotionGates" (ne (toString (dig "promotionGates" true $a)) "false")) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{- /* Gated environments that apply to an app: [] when the app opts out (promotionGates: false). */ -}}
{{- define "tenant.gatedEnvs" -}}
{{- $app := index . 0 -}}{{- $root := index . 1 -}}
{{- if not $app.promotionGates -}}[]{{- else -}}{{- $root.Values.promotion.gatedEnvironments | default list | toYaml -}}{{- end -}}
{{- end }}

{{- /*
Weekly freeze window {start: "Fri 16:00", end: "Mon 08:00"} -> Argo CD sync window cron + duration. Windows wrap
around the end of the week. Cron day of week: Sun=0 .. Sat=6.
*/ -}}
{{- define "tenant.minuteOfWeek" -}}
{{- $parts := regexSplit "[ :]" . -1 -}}
{{- $day := index (dict "Mon" 0 "Tue" 1 "Wed" 2 "Thu" 3 "Fri" 4 "Sat" 5 "Sun" 6) (index $parts 0) -}}
{{- add (mul $day 1440) (mul (atoi (index $parts 1)) 60) (atoi (index $parts 2)) -}}
{{- end }}

{{- define "tenant.syncWindowTiming" -}}
{{- $start := include "tenant.minuteOfWeek" .start | atoi -}}
{{- $end := include "tenant.minuteOfWeek" .end | atoi -}}
{{- $dur := mod (add (sub $end $start) 10080) 10080 -}}
{{- $parts := regexSplit "[ :]" .start -1 -}}
{{- $cronDay := mod (add (div $start 1440) 1) 7 -}}
schedule: {{ printf "%d %d * * %d" (atoi (index $parts 2)) (atoi (index $parts 1)) $cronDay | quote }}
duration: {{ if eq (mod $dur 60) 0 }}{{ printf "%dh" (div $dur 60) }}{{ else }}{{ printf "%dh%dm" (div $dur 60) (mod $dur 60) }}{{ end }}
{{- end }}

{{- /*
Cell namespace OpenChoreo creates for this project on an environment's data plane (ProjectReleaseBinding controller:
GenerateK8sNameWithLengthLimit(63, "dp", <org ns>, <project>, <env>), internal/dataplane/kubernetes/name.go in
openchoreo/openchoreo v1.3.3): each part truncated to its share of the 63 characters (51 for the parts: 13, 13, 13,
12), joined with "-", plus "-" and the first 8 hex digits of sha256("dp-<org>-<project>-<env>") of the untruncated
parts. Inputs are DNS labels already, so OpenChoreo's sanitising is the identity. Pinned against live names in
tests/secrets_test.yaml (dp-default-demo-development-ad621210). Context: dict org project env.
*/ -}}
{{- define "tenant.cellNamespace" -}}
{{- $names := list "dp" .org .project .env -}}
{{- $limit := 63 -}}{{- $hashLen := 8 -}}
{{- $maxBase := sub (sub $limit $hashLen) (len $names) -}}
{{- $per := div $maxBase (len $names) -}}{{- $extra := mod $maxBase (len $names) -}}
{{- $parts := list -}}
{{- range $i, $n := $names -}}
{{- $parts = append $parts (trunc (int (ternary (add $per 1) $per (lt $i $extra))) $n) -}}
{{- end -}}
{{- printf "%s-%s" (join "-" $parts) (join "-" $names | sha256sum | trunc $hashLen) -}}
{{- end }}

{{- /* Groups with developer rights in this project only (templates/developer-authz.yaml); default <project>-developers. */ -}}
{{- define "tenant.developerGroups" -}}
{{- $groups := .Values.developerGroups | default (list (printf "%s-developers" (include "tenant.project" .))) }}
{{- toYaml (uniq $groups) }}
{{- end }}
