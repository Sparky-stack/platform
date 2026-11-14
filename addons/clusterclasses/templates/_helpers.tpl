{{/*
Template names carry a hash of their spec: provider webhooks make machine templates immutable, and CAPI's way to change
a ClusterClass template is "new template + update the reference". A spec change in git therefore renders a new name,
the ClusterClass follows, the topology controller rolls the clusters, and Argo prunes the old template.
Usage: include "clusterclasses.templateName" (list "<base>" (include "<spec define>" .))
*/}}
{{- define "clusterclasses.templateName" -}}
{{- printf "%s-%s" (index . 0) (sha256sum (index . 1) | trunc 8) -}}
{{- end }}

{{/* Provider CRDs are installed by the operator after this app's first sync attempt. */}}
{{- define "clusterclasses.annotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{/*
k3s private registry auth: /etc/rancher/k3s/registries.yaml (k3s' default --private-registry path) from Secret
<cluster>-registries (key registries.yaml, ns fleet), rendered by charts/cluster (capi-registries.yaml). The k3s
bootstrap provider resolves files[].contentFrom.secret in the KThreesConfig's namespace at bootstrap time and retries
until the Secret exists. The CAPI template (`{{ .builtin.cluster.name }}`) is evaluated by the topology controller.
*/}}
{{- define "clusterclasses.registriesFile" -}}
path: /etc/rancher/k3s/registries.yaml
owner: root:root
permissions: "0600"
contentFrom:
  secret:
    name: {{`"{{ .builtin.cluster.name }}-registries"`}}
    key: registries.yaml
{{- end }}

{{/*
jsonPatch adding the registries file. Args: (list "<path to files>" <base template already has files: bool>)
*/}}
{{- define "clusterclasses.registriesPatch" -}}
{{- $path := index . 0 -}}
{{- $append := index . 1 -}}
- op: add
  path: {{ $path }}{{ if $append }}/-{{ end }}
  valueFrom:
    template: |
      {{- if $append }}
      {{- include "clusterclasses.registriesFile" . | nindent 6 }}
      {{- else }}
      - {{ include "clusterclasses.registriesFile" . | indent 8 | trim }}
      {{- end }}
{{- end }}

{{/*
Registry CA: /etc/rancher/k3s/registry-ca.crt (the registries.yaml `tls.ca_file` of the installation's Harbor) from
key registry-ca.crt of the same Secret <cluster>-registries. Public certificate only (charts/cluster).
*/}}
{{- define "clusterclasses.registryCAFile" -}}
path: /etc/rancher/k3s/registry-ca.crt
owner: root:root
permissions: "0644"
contentFrom:
  secret:
    name: {{`"{{ .builtin.cluster.name }}-registries"`}}
    key: registry-ca.crt
{{- end }}

{{/*
Patch appending the CA file. Ordered after registryAuth, so the files list exists on both template kinds. The worker
template has a files list only when registryAuth created it, so the patch is gated on both variables here too (not
only by charts/cluster setting them together): registryCA alone renders nothing instead of a failing JSON patch.
Arg: list of (path-to-files) per template kind is implied by the selector order: control plane, workers.
*/}}
{{- define "clusterclasses.registryCAPatch" -}}
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
              {{- include "clusterclasses.registryCAFile" . | nindent 14 }}
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
              {{- include "clusterclasses.registryCAFile" . | nindent 14 }}
{{- end }}

{{/* Variables shared by every class. */}}
{{- define "clusterclasses.commonVariables" -}}
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
{{- define "clusterclasses.cniConfigPath" -}}
/etc/rancher/k3s/config.yaml.d/10-cni.yaml
{{- end }}

{{- define "clusterclasses.cniFile" -}}
- path: {{ include "clusterclasses.cniConfigPath" . }}
  owner: root:root
  permissions: "0600"
  content: |
    # cni: cilium (ClusterClass variable cni)
    flannel-backend: none
    disable-network-policy: true
    disable-kube-proxy: true
{{- end }}

{{/* Patch for cni=flannel on the KThreesControlPlaneTemplate. Arg: the flannel k3s config (string). */}}
{{- define "clusterclasses.cniFlannelPatch" -}}
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
            - path: {{ include "clusterclasses.cniConfigPath" nil }}
              owner: root:root
              permissions: "0600"
              content: |
                # cni: flannel (ClusterClass variable cni)
                {{- . | nindent 16 }}
{{- end }}

{{/* Machine health checks for cloud worker pools (docker: none, a dead container is a dead test). */}}
{{- define "clusterclasses.workerHealthCheck" -}}
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
