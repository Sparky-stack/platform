{{- /* Argo CD may apply an OpenChoreo object before its CRD exists (addon openchoreo-control-plane installs them):
add SkipDryRunOnMissingResource to an object loaded from files/. Call: include "platform.skipDryRun" $obj */ -}}
{{- define "platform.skipDryRun" -}}
{{- $_ := set .metadata "annotations" (merge (default dict .metadata.annotations) (dict "argocd.argoproj.io/sync-options" "SkipDryRunOnMissingResource=true")) -}}
{{- end }}
