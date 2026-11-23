{{/* The PostgreSQL backend of this cluster: postgresql.backend, else postgresql.backendByProvider[cluster.provider].
Values are enums (values.schema.json); a provider without a backend fails in templates/validate.yaml. */}}
{{- define "crossplane.pgBackend" -}}
{{- $p := .Values.postgresql -}}
{{- $p.backend | default (get ($p.backendByProvider | default dict) (.Values.cluster.provider | default "")) -}}
{{- end }}

{{/* Cloud of a backend (provider family prefix): aws | gcp | azure, empty for cnpg. */}}
{{- define "crossplane.pgCloud" -}}
{{- $b := include "crossplane.pgBackend" . -}}
{{- if hasPrefix "aws-" $b }}aws{{ else if hasPrefix "gcp-" $b }}gcp{{ else if hasPrefix "azure-" $b }}azure{{ end -}}
{{- end }}

{{/* Annotations of every Crossplane object here: CRDs appear only once Crossplane runs (or a provider is installed). */}}
{{- define "crossplane.syncAnnotations" -}}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
argocd.argoproj.io/sync-wave: {{ . | default "1" | quote }}
{{- end }}

{{/* Per-cluster facts handed to the Composition's go-template (JSON, read with fromYaml). Required facts: templates/validate.yaml. */}}
{{- define "crossplane.pgFacts" -}}
{{- $v := .Values -}}
{{- $p := $v.postgresql -}}
{{- $b := include "crossplane.pgBackend" . -}}
{{- $f := dict "backend" $b "cluster" $v.cluster.name "environment" $v.cluster.environment -}}
{{- if eq $b "cnpg" -}}
{{- $_ := set $f "imageCatalog" $p.cnpg.imageCatalog -}}
{{- $_ := set $f "podMonitor" $p.cnpg.podMonitor -}}
{{- $_ := set $f "backup" $p.cnpg.backup -}}
{{- else if eq $b "aws-rds" -}}
{{- $a := $p.aws -}}
{{- $_ := set $f "region" ($a.region | default $v.cluster.region) -}}
{{- $_ := set $f "vpcId" $a.vpcId -}}
{{- $_ := set $f "subnetIds" $a.subnetIds -}}
{{- $_ := set $f "nodeSecurityGroupId" $a.nodeSecurityGroupId -}}
{{- else if eq $b "gcp-cloudsql" -}}
{{- $g := $p.gcp -}}
{{- $_ := set $f "region" ($g.region | default $v.cluster.region) -}}
{{- $_ := set $f "project" $g.project -}}
{{- $_ := set $f "privateNetwork" $g.privateNetwork -}}
{{- $_ := set $f "allocatedIpRange" ($g.allocatedIpRange | default "") -}}
{{- else if eq $b "azure-flexible" -}}
{{- $z := $p.azure -}}
{{- $_ := set $f "location" ($z.location | default $v.cluster.region) -}}
{{- $_ := set $f "tenantID" $z.tenantID -}}
{{- $_ := set $f "resourceGroupName" $z.resourceGroupName -}}
{{- $_ := set $f "delegatedSubnetId" $z.delegatedSubnetId -}}
{{- $_ := set $f "privateDnsZoneId" $z.privateDnsZoneId -}}
{{- end -}}
{{- toJson $f -}}
{{- end }}

{{/* DeploymentRuntimeConfig spec meeting Pod Security restricted (Crossplane's default package runtime sets neither
seccomp nor a capability drop). Input: dict "resources" [, "serviceAccount", "podLabels"]. */}}
{{- define "crossplane.runtimeSpec" -}}
deploymentTemplate:
  spec:
    selector: {}
    template:
      {{- with .podLabels }}
      metadata:
        labels:
          {{- toYaml . | nindent 10 }}
      {{- end }}
      spec:
        securityContext:
          runAsNonRoot: true
          runAsUser: 2000
          runAsGroup: 2000
          seccompProfile: { type: RuntimeDefault }
        containers:
          - name: package-runtime
            securityContext:
              runAsNonRoot: true
              allowPrivilegeEscalation: false
              privileged: false
              readOnlyRootFilesystem: true
              capabilities: { drop: [ALL] }
              seccompProfile: { type: RuntimeDefault }
            resources:
              {{- toYaml .resources | nindent 14 }}
{{- with .serviceAccount }}
serviceAccountTemplate:
  metadata:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end }}
