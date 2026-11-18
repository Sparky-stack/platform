{{- define "byo.secretKey" -}}byo-{{ .Values.name }}{{- end }}
{{- define "byo.store" -}}byo-{{ .Values.name }}{{- end }}
{{- define "byo.pushSecret" -}}
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: {{ .name }}
  namespace: fleet
  labels:
    platform.koorikla.io/name: {{ .root.Values.name | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: "20"
spec:
  refreshInterval: 10m
  updatePolicy: Replace
  deletionPolicy: Delete
  secretStoreRefs:
    - kind: ClusterSecretStore
      name: {{ include "byo.store" .root }}
  selector:
    secret:
      name: {{ .source }}
  data:
    - match:
        remoteRef:
          remoteKey: {{ .remoteName }}
      metadata:
        apiVersion: kubernetes.external-secrets.io/v1alpha1
        kind: PushSecretMetadata
        spec:
          remoteNamespace: {{ .namespace }}
          sourceMergePolicy: Replace
          targetMergePolicy: Replace
          labels:
            platform.koorikla.io/delivered-by: mgmt
            {{- with .labels }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
{{- end }}
