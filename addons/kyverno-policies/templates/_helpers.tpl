{{- /* CEL list literal body from a string list: "a", "b" */ -}}
{{- define "kp.quoteList" -}}
{{- $out := list -}}
{{- range . }}{{ $out = append $out (. | toJson) }}{{ end -}}
{{- join ", " $out -}}
{{- end }}
