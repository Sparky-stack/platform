{{- /*
koorikla-lib.agentServerCA (root context; values agentServerCA.{enabled,store,sourceSecret,configMapName}).
Users: addons/openchoreo-observability-plane, addons/openchoreo-workflow-plane (templates/agent-server-ca.yaml).
ConfigMap cluster-gateway-ca for a plane's cluster-agent (clusterAgent.tls.serverCAConfigMap): the control plane's
gateway CA PUBLIC certificate. Only key ca.crt of openchoreo-control-plane/cluster-gateway-ca is read, through the
read-only ClusterSecretStore `mgmt-openchoreo`; the CA key never leaves that namespace. ESO generic target (ConfigMap):
needs external-secrets with genericTargets.enabled (--unsafe-allow-generic-targets) on mgmt. The agent reads the CA at
start: restart it after a CA rotation (10y).
*/ -}}
{{- define "koorikla-lib.agentServerCA" }}
{{- if .Values.agentServerCA.enabled }}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Values.agentServerCA.configMapName }}
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/part-of: openchoreo
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.agentServerCA.store }}
  target:
    name: {{ .Values.agentServerCA.configMapName }}
    creationPolicy: Owner
    manifest:
      apiVersion: v1
      kind: ConfigMap
  data:
    - secretKey: ca.crt
      remoteRef:
        key: {{ .Values.agentServerCA.sourceSecret }}
        property: ca.crt
{{- end }}
{{- end }}
