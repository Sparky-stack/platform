{{- /*
CAPI topology Cluster in namespace fleet (class k3s-<provider>, or gke-managed for gcp-gke; skipped for byo).
Shared helpers (checks: templates/validate.yaml): capi.gke, capi.byo, capi.labels, capi.registry.harbor.
*/ -}}
{{- define "capi.gke" -}}{{ eq (toString .Values.provider) "gcp-gke" | toString }}{{- end }}
{{- define "capi.byo" -}}{{ eq (toString .Values.provider) "byo" | toString }}{{- end }}

{{- define "capi.labels" -}}
platform.koorikla.io/name: {{ .Values.name | quote }}
platform.koorikla.io/role: workload
platform.koorikla.io/provider: {{ .Values.provider | quote }}
platform.koorikla.io/region: {{ .Values.region | quote }}
platform.koorikla.io/environment: {{ .Values.environment | quote }}
platform.koorikla.io/installation: {{ .Values.installation.name | quote }}
platform.koorikla.io/cni: {{ .Values.cni | quote }}
{{- with .Values.mesh.group }}
mesh.platform.koorikla.io/group: {{ . | quote }}
mesh.platform.koorikla.io/network: {{ $.Values.name | quote }}
{{- end }}
{{- $cilium := and (eq .Values.cni "cilium") (ne (include "capi.byo" .) "true") }}
{{- range $addon, $on := merge (dict "cilium" $cilium) .Values.addons }}
addons.platform.koorikla.io/{{ $addon }}: {{ $on | toString | quote }}
{{- end }}
{{- end }}

{{- define "capi.registry.harbor" -}}
{{- and (eq (toString .Values.registry.type) "harbor") (ne (toString .Values.registry.host) "") | toString -}}
{{- end }}

{{- define "capi.annotations" -}}
platform.koorikla.io/addons-revision: {{ .Values.addonsRevision | default "HEAD" | quote }}
{{- end }}

{{- define "capi.variables" -}}
{{- $gke := eq (include "capi.gke" .) "true" -}}
{{- $harbor := and (not $gke) (eq (include "capi.registry.harbor" .) "true") -}}
{{- $vars := dict -}}
{{- if not $gke -}}
{{- $vars = dict "registryAuth" (or (.Values.secrets.nodeRegistryAuth.enabled | default false) $harbor) "cni" .Values.cni -}}
{{- if $harbor -}}
{{- $_ := set $vars "registryCA" true -}}
{{- if and (eq .Values.provider "docker") .Values.registry.nodeHostAlias -}}
{{- $_ := set $vars "registryHostAlias" (regexReplaceAll ":[0-9]+$" .Values.registry.host "") -}}
{{- $_ := set $vars "registryHostAliasTarget" .Values.registry.nodeHostAlias -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if ne .Values.provider "docker" -}}
{{- $_ := set $vars "region" .Values.region -}}
{{- with (.Values.controlPlane | default dict).machineType -}}
{{- $_ := set $vars "controlPlaneMachineType" . -}}
{{- end -}}
{{- end -}}
{{- $_ := mergeOverwrite $vars .Values.providerSpec -}}
{{- range $k := keys $vars | sortAlpha }}
- name: {{ $k }}
  value: {{ index $vars $k | toJson }}
{{- end }}
{{- end }}

{{- define "capi.topology.gke" -}}
workers:
  machinePools:
    {{- range .Values.workers }}
    - class: default-worker
      name: {{ .name }}
      replicas: {{ hasKey . "replicas" | ternary .replicas 1 }}
      {{- if or .machineType .failureDomain }}
      variables:
        overrides:
          {{- with .machineType }}
          - name: workerMachineType
            value: {{ . | quote }}
          {{- end }}
          {{- with .failureDomain }}
          - name: workerNodeLocations
            value: [{{ . | quote }}]
          {{- end }}
      {{- end }}
    {{- end }}
{{- end }}

{{- define "capi.topology.k3s" -}}
controlPlane:
  replicas: {{ (.Values.controlPlane | default dict).replicas | default 1 }}
{{- if .Values.workers }}
workers:
  machineDeployments:
    {{- range .Values.workers }}
    - class: default-worker
      name: {{ .name }}
      replicas: {{ hasKey . "replicas" | ternary .replicas 1 }}
      {{- with .failureDomain }}
      failureDomain: {{ . | quote }}
      {{- end }}
      {{- if and .machineType (ne $.Values.provider "docker") }}
      variables:
        overrides:
          - name: workerMachineType
            value: {{ .machineType | quote }}
      {{- end }}
    {{- end }}
{{- end }}
{{- end }}
