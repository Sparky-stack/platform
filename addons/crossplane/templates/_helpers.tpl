{{/* The PostgreSQL backend of this cluster: postgresql.backend, else postgresql.backendByProvider[cluster.provider]. */}}
{{- define "crossplane.pgBackend" -}}
{{- $p := .Values.postgresql -}}
{{- $b := $p.backend | default (get ($p.backendByProvider | default dict) (.Values.cluster.provider | default "")) -}}
{{- if not $b -}}
{{- fail (printf "postgresql: no backend for provider %q - add it to postgresql.backendByProvider or set postgresql.backend" .Values.cluster.provider) -}}
{{- end -}}
{{- if not (has $b (list "cnpg" "aws-rds" "gcp-cloudsql" "azure-flexible")) -}}
{{- fail (printf "postgresql: unknown backend %q (cnpg | aws-rds | gcp-cloudsql | azure-flexible)" $b) -}}
{{- end -}}
{{- $b -}}
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

{{/* Per-cluster facts handed to the Composition's go-template (JSON, read with fromYaml). Required facts fail here. */}}
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
{{- if lt (len ($a.subnetIds | default list)) 2 }}{{ fail "postgresql.aws.subnetIds: at least two private subnets (two AZs) are required" }}{{ end -}}
{{- $_ := set $f "region" ($a.region | default $v.cluster.region) -}}
{{- $_ := set $f "vpcId" (required "postgresql.aws.vpcId is required for backend aws-rds" $a.vpcId) -}}
{{- $_ := set $f "subnetIds" $a.subnetIds -}}
{{- $_ := set $f "nodeSecurityGroupId" (required "postgresql.aws.nodeSecurityGroupId is required for backend aws-rds" $a.nodeSecurityGroupId) -}}
{{- else if eq $b "gcp-cloudsql" -}}
{{- $g := $p.gcp -}}
{{- $_ := set $f "region" ($g.region | default $v.cluster.region) -}}
{{- $_ := set $f "project" (required "postgresql.gcp.project is required for backend gcp-cloudsql" $g.project) -}}
{{- $_ := set $f "privateNetwork" (required "postgresql.gcp.privateNetwork is required for backend gcp-cloudsql" $g.privateNetwork) -}}
{{- $_ := set $f "allocatedIpRange" ($g.allocatedIpRange | default "") -}}
{{- else if eq $b "azure-flexible" -}}
{{- $z := $p.azure -}}
{{- $_ := set $f "location" ($z.location | default $v.cluster.region) -}}
{{- $_ := set $f "tenantID" (required "postgresql.azure.tenantID is required for backend azure-flexible" $z.tenantID) -}}
{{- $_ := set $f "resourceGroupName" (required "postgresql.azure.resourceGroupName is required for backend azure-flexible" $z.resourceGroupName) -}}
{{- $_ := set $f "delegatedSubnetId" (required "postgresql.azure.delegatedSubnetId is required for backend azure-flexible" $z.delegatedSubnetId) -}}
{{- $_ := set $f "privateDnsZoneId" (required "postgresql.azure.privateDnsZoneId is required for backend azure-flexible" $z.privateDnsZoneId) -}}
{{- end -}}
{{- toJson $f -}}
{{- end }}
