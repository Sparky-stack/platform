{{/*
Template names carry a hash of their spec: provider webhooks make machine templates immutable, and CAPI's way to change
a ClusterClass template is "new template + update the reference". A spec change in git therefore renders a new name,
the ClusterClass follows, the topology controller rolls the clusters, and Argo prunes the old template.
Usage: include "clusterclass.templateName" (list "<base>" (include "<spec define>" .))
*/}}
{{- define "clusterclass.templateName" -}}
{{- printf "%s-%s" (index . 0) (sha256sum (index . 1) | trunc 8) -}}
{{- end }}

{{/* Provider CRDs are installed by the operator after this app's first sync attempt. */}}
{{- define "clusterclass.annotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{/*
Private registry auth (/etc/rancher/k3s/registries.yaml) from Secret <cluster>-registries (capi-registries.yaml).
Bootstrap resolves contentFrom.secret once without watching it, so Clusters wait on wave -1 (test_bootstrap_file_sources.sh).
*/}}
{{- define "clusterclass.registriesFile" -}}
path: /etc/rancher/k3s/registries.yaml
owner: root:root
permissions: "0600"
contentFrom:
  secret:
    name: {{`"{{ .builtin.cluster.name }}-registries"`}}
    key: registries.yaml
{{- end }}

{{- define "clusterclass.registryAuthPatch" -}}
- name: registryAuth
  enabledIf: {{`"{{ .registryAuth }}"`}}
  definitions:
    - selector:
        apiVersion: controlplane.cluster.x-k8s.io/v1beta2
        kind: KThreesControlPlaneTemplate
        matchResources:
          controlPlane: true
      jsonPatches:
        - op: add
          path: /spec/template/spec/kthreesConfigSpec/files/-
          valueFrom:
            template: |
              {{- include "clusterclass.registriesFile" . | nindent 14 }}
    - selector:
        apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
        kind: KThreesConfigTemplate
        matchResources:
          machineDeploymentClass:
            names: [default-worker]
      jsonPatches:
        - op: add
          path: /spec/template/spec/files
          valueFrom:
            template: |
              - {{ include "clusterclass.registriesFile" . | indent 16 | trim }}
{{- end }}

{{- define "clusterclass.registryCAFile" -}}
path: /etc/rancher/k3s/registry-ca.crt
owner: root:root
permissions: "0644"
contentFrom:
  secret:
    name: {{`"{{ .builtin.cluster.name }}-registries"`}}
    key: registry-ca.crt
{{- end }}

{{/* Ordered after registryAuth so workers already have `files`; gated on both so registryCA alone is a no-op. */}}
{{- define "clusterclass.registryCAPatch" -}}
- name: registryCA
  enabledIf: {{`'{{ if and .registryAuth .registryCA }}true{{ end }}'`}}
  definitions:
    - selector:
        apiVersion: controlplane.cluster.x-k8s.io/v1beta2
        kind: KThreesControlPlaneTemplate
        matchResources:
          controlPlane: true
      jsonPatches:
        - op: add
          path: /spec/template/spec/kthreesConfigSpec/files/-
          valueFrom:
            template: |
              {{- include "clusterclass.registryCAFile" . | nindent 14 }}
    - selector:
        apiVersion: bootstrap.cluster.x-k8s.io/v1beta2
        kind: KThreesConfigTemplate
        matchResources:
          machineDeploymentClass:
            names: [default-worker]
      jsonPatches:
        - op: add
          path: /spec/template/spec/files/-
          valueFrom:
            template: |
              {{- include "clusterclass.registryCAFile" . | nindent 14 }}
{{- end }}

{{/* Variables shared by every class. */}}
{{- define "clusterclass.commonVariables" -}}
- name: registryAuth
  required: false
  schema:
    openAPIV3Schema:
      type: boolean
      default: false
      description: Write /etc/rancher/k3s/registries.yaml from Secret <cluster>-registries (charts/cluster).
- name: registryCA
  required: false
  schema:
    openAPIV3Schema:
      type: boolean
      default: false
      description: Write /etc/rancher/k3s/registry-ca.crt (registry CA public cert) from Secret <cluster>-registries; needs registryAuth.
- name: cni
  required: false
  schema:
    openAPIV3Schema:
      type: string
      enum: [cilium, flannel]
      default: cilium
      description: >-
        Pod network, fixed at birth (fleet file `cni`; switching = rebuild). cilium: k3s without flannel,
        kube-proxy and its network-policy controller; Cilium arrives as an Argo CD addon. flannel: k3s' bundled one.
{{- end }}

{{/*
CNI choice as a k3s config drop-in on the servers (/etc/rancher/k3s/config.yaml.d/ is merged over the config.yaml the
bootstrap provider writes; the KThreesServerConfig API has no field for these flags). Agents need nothing: they take
flannel-backend, disable-kube-proxy and disable-network-policy from the servers. The base templates carry the cilium
file as their only files entry; patch `cni-flannel` replaces the whole list (CAPI forbids array-element replace paths),
so it runs before every patch that appends files. Arg: k3s config for the flannel case.
*/}}
{{- define "clusterclass.cniConfigPath" -}}
/etc/rancher/k3s/config.yaml.d/10-cni.yaml
{{- end }}

{{- define "clusterclass.cniFile" -}}
- path: {{ include "clusterclass.cniConfigPath" . }}
  owner: root:root
  permissions: "0600"
  content: |
    # cni: cilium (ClusterClass variable cni)
    flannel-backend: none
    disable-network-policy: true
    disable-kube-proxy: true
{{- end }}

{{/* Patch for cni=flannel on the KThreesControlPlaneTemplate. Arg: the flannel k3s config (string). */}}
{{- define "clusterclass.cniFlannelPatch" -}}
- name: cni-flannel
  enabledIf: {{`'{{ if eq .cni "flannel" }}true{{ end }}'`}}
  definitions:
    - selector:
        apiVersion: controlplane.cluster.x-k8s.io/v1beta2
        kind: KThreesControlPlaneTemplate
        matchResources:
          controlPlane: true
      jsonPatches:
        # CAPI's ClusterClass webhook rejects array-element paths in replace ops, so the whole files list is replaced.
        # Patches apply in list order: every class lists this patch BEFORE the ones appending files (registryAuth,
        # registryCA), otherwise it drops them (tests pin the order).
        - op: replace
          path: /spec/template/spec/kthreesConfigSpec/files
          value:
            - path: {{ include "clusterclass.cniConfigPath" nil }}
              owner: root:root
              permissions: "0600"
              content: |
                # cni: flannel (ClusterClass variable cni)
                {{- . | nindent 16 }}
{{- end }}

{{/* Machine health checks for cloud worker pools (docker: none, a dead container is a dead test). */}}
{{- define "clusterclass.workerHealthCheck" -}}
healthCheck:
  checks:
    nodeStartupTimeoutSeconds: 900
    unhealthyNodeConditions:
      - type: Ready
        status: Unknown
        timeoutSeconds: 300
      - type: Ready
        status: "False"
        timeoutSeconds: 300
  remediation:
    triggerIf:
      unhealthyLessThanOrEqualTo: 40%
{{- end }}
