{{- /* This member's mesh group (catalog clusterLabelParameters). The catalog selects the addon only on clusters whose
fleet file sets mesh.group (values/mesh-member.yaml turns mesh.csr.enabled on there), so "" means a standalone render: the Issuer is then left out (templates/csr-issuer.yaml). */ -}}
{{- define "mesh.group" -}}
{{- $g := (.Values.mesh | default dict).group | default "" -}}
{{- if and $g (not (regexMatch "^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$" $g)) -}}
{{- fail (printf "mesh: mesh.group %q must be a DNS label (set by the catalog from mesh.platform.koorikla.io/group)" $g) -}}
{{- end -}}
{{- $g -}}
{{- end }}

{{- define "mesh.cluster" -}}
{{- $c := required "cluster.name is required" .Values.cluster.name -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$" $c) -}}
{{- fail (printf "mesh: cluster.name %q must be a DNS label" $c) -}}
{{- end -}}
{{- $c -}}
{{- end }}

{{- define "mesh.labels" -}}
app.kubernetes.io/part-of: istio-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
