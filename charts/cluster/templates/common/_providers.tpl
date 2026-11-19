{{- /*
One namespace per provider (clusterctl layout). Sync waves: namespaces, then credentials (credentials.yaml), then
providers. The operator orders the installs itself (core first) and retries until configSecrets exist.
*/ -}}
{{- define "providers.namespace" -}}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ . }}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
{{- end }}

{{- define "providers.annotations" -}}
argocd.argoproj.io/sync-wave: "0"
# operator CRDs come from the capi-operator addon
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}

{{- /* spec.manager of one provider: (dict "p" <provider values> "le" .Values.leaderElection). featureGates if set;
leaderElection only for managers with the lease flags (p.leaseFlags), which the operator turns into
--leader-elect-{lease-duration,renew-deadline,retry-period} (component_customizer.go leaderElectionArgs). */ -}}
{{- define "providers.manager" -}}
{{- $p := .p -}}
{{- if or $p.featureGates $p.leaseFlags -}}
manager:
  {{- with $p.featureGates }}
  featureGates:
    {{- range $gate, $on := . }}
    {{ $gate }}: {{ $on }}
    {{- end }}
  {{- end }}
  {{- if $p.leaseFlags }}
  {{- $le := .le }}
  leaderElection:
    leaderElect: true
    leaseDuration: {{ $le.leaseDuration | quote }}
    renewDeadline: {{ $le.renewDeadline | quote }}
    retryPeriod: {{ $le.retryPeriod | quote }}
    resourceLock: leases
    resourceName: ""        # required by the CRD; empty = the manager's default Lease
    resourceNamespace: ""
  {{- end }}
{{- end }}
{{- end }}
