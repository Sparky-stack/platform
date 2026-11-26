{{- /*
objectSelector of the OpenChoreo cell namespaces a namespace policy acts on: ambientEnrollment.cellNamespaceSelector
plus one extra expression on istio.io/dataplane-mode (ambient-enrollment.yaml: not yet set; cell-mesh.yaml: not none).
Call with (dict "sel" <selector> "mode" <matchExpression flow map>), indent 4.
*/ -}}
{{- define "kp.cellObjectSelector" -}}
objectSelector:
  {{- with .sel.matchLabels }}
  matchLabels:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  matchExpressions:
    {{- with .sel.matchExpressions }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    - {{ .mode }}
{{- end }}

{{- /* Shared spec preamble of the cell-mesh GeneratingPolicies (templates/cell-mesh.yaml). */ -}}
{{- define "kp.cellMeshSpec" -}}
evaluation:
  synchronize:
    enabled: true
  generateExisting:
    enabled: true
matchConstraints:
  resourceRules:
    - apiGroups: [""]
      apiVersions: [v1]
      operations: [CREATE, UPDATE]
      resources: [namespaces]
  {{- include "kp.cellObjectSelector" .cells | nindent 2 }}
matchConditions:
  - name: never-platform-namespaces
    expression: '!(object.metadata.name in {{ .root.Values.platformNamespaces | toJson }})'
{{- end }}

{{- /* Kubelet probe ingress rule after istio-cni SNAT (embedded inside NetworkPolicy value scalars). */ -}}
{{- define "kp.probeIngress" -}}
- from:
{{- range .Values.mesh.probeSourceCIDRs }}
    - ipBlock: { cidr: {{ if contains ":" . }}{{ . | quote }}{{ else }}{{ . }}{{ end }} }
{{- end }}
{{- end }}
