{{- /* This member's mesh group (catalog clusterLabelParameters). The catalog selects the addon only on clusters whose
fleet file sets mesh.group (charts/cluster derives addons.platform.koorikla.io/istio-csr from it and rejects a
contradicting override), so "" means a standalone render: the Issuer is then left out (templates/issuer.yaml). */ -}}
{{- define "istio-csr-addon.group" -}}
{{- $g := (.Values.mesh | default dict).group | default "" -}}
{{- if and $g (not (regexMatch "^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$" $g)) -}}
{{- fail (printf "istio-csr: mesh.group %q must be a DNS label (set by the catalog from mesh.platform.koorikla.io/group)" $g) -}}
{{- end -}}
{{- $g -}}
{{- end }}

{{- define "istio-csr-addon.cluster" -}}
{{- $c := required "cluster.name is required" .Values.cluster.name -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$" $c) -}}
{{- fail (printf "istio-csr: cluster.name %q must be a DNS label" $c) -}}
{{- end -}}
{{- $c -}}
{{- end }}

{{- define "istio-csr-addon.labels" -}}
app.kubernetes.io/part-of: istio-mesh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
