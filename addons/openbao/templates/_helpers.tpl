{{- /* Mesh groups of the installation (installation.yaml mesh.groups; DNS labels, unique: values.schema.json). */ -}}
{{- define "openbao-addon.groups" -}}
{{- toJson (.Values.mesh.groups | default list) -}}
{{- end }}

{{- /* Address members dial (installation.yaml mesh.ca): host = SNI of the TLS passthrough listener + a SAN of the
listener cert; port = Gateway listener port = k3d published port (bootstrap/k3d-mgmt.yaml, contract test).
Both required and format-checked by values.schema.json. */ -}}
{{- define "openbao-addon.host" -}}
{{- .Values.mesh.ca.host -}}
{{- end }}
{{- define "openbao-addon.port" -}}
{{- .Values.mesh.ca.port -}}
{{- end }}

{{- define "openbao-addon.labels" -}}
app.kubernetes.io/part-of: openbao
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* ServiceAccount with no automounted token, shared by reconcilers and readers. Context: dict root name. */ -}}
{{- define "openbao-addon.serviceAccount" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "openbao-addon.labels" .root | nindent 4 }}
automountServiceAccountToken: false
{{- end }}

{{- /* Base env prefix shared by the three reconcilers (preserves exact order for checksum/config). */ -}}
{{- define "openbao-addon.reconcileBaseEnv" -}}
{{- toJson (list
  (dict "name" "BAO_ADDR" "value" (printf "https://%s-active.%s.svc:8200" .root.Release.Name .root.Release.Namespace))
  (dict "name" "BAO_CACERT" "value" "/openbao/tls/ca.crt")
  (dict "name" "HOME" "value" "/tmp")
  (dict "name" .dirName "value" .dirValue)
  (dict "name" "TOKEN_FILE" "value" "/var/run/secrets/openbao/token")
  (dict "name" "LOGIN_ROLE" "value" .loginRole)
) -}}
{{- end }}

{{- /* Final-wave CronJob wrapper shared by mesh-, policy- and tenant-reconcile. */ -}}
{{- define "openbao-addon.reconcileCronJob" }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "openbao-addon.labels" .root | nindent 4 }}
  annotations:
    argocd.argoproj.io/sync-wave: "2"    # final wave: a failing run never fails the sync
spec:
  schedule: {{ .schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 240
      ttlSecondsAfterFinished: 3600
      template:
        metadata:
          labels: { app.kubernetes.io/name: {{ .name }} }
          {{- with .checksum }}
          annotations:
            checksum/config: {{ . }}
          {{- end }}
        spec:
          {{- include "openbao-addon.reconcilePod" (dict "root" .root "sa" .sa "env" .env "script" .name "inputs" .inputs) | nindent 10 }}
{{- end }}

{{- /* Pod spec shared by the three reconcilers (mesh-, tenant-, policy-reconcile): POSIX sh + bao CLI from the OpenBao
image, no Kubernetes API access, a 10-minute projected token as the only credential. Context: dict root sa env script
inputs; script = ConfigMap name and files/<script>.sh, inputs = list of {name, secret, path} (may be empty). */ -}}
{{- define "openbao-addon.reconcilePod" }}
{{- $v := .root.Values }}
{{- $img := $v.openbao.server.image }}
serviceAccountName: {{ .sa }}
automountServiceAccountToken: false
restartPolicy: Never
securityContext:
  runAsNonRoot: true
  runAsUser: 100
  runAsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: reconcile
    image: {{ printf "%s/%s:%s" $img.registry $img.repository $img.tag | quote }}
    command: [/bin/sh, {{ printf "/scripts/%s.sh" .script }}]
    env:
      {{- toYaml .env | nindent 6 }}
    resources:
      {{- toYaml $v.reconcile.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: scripts, mountPath: /scripts, readOnly: true }
      {{- range $i := .inputs }}
      - { name: {{ $i.name }}, mountPath: {{ $i.path }}, readOnly: true }
      {{- end }}
      - { name: token, mountPath: /var/run/secrets/openbao, readOnly: true }
      - { name: tls-ca, mountPath: /openbao/tls, readOnly: true }
      - { name: tmp, mountPath: /tmp }
volumes:
  - name: scripts
    configMap: { name: {{ .script }} }
  {{- range $i := .inputs }}
  - name: {{ $i.name }}
    secret: { secretName: {{ $i.secret }}, optional: true }    # no members / tenants yet: nothing to enrol
  {{- end }}
  - name: token
    projected:
      sources:
        - serviceAccountToken: { audience: {{ $v.reconcile.audience | quote }}, expirationSeconds: 600, path: token }
  - name: tls-ca
    secret:
      secretName: {{ $v.tls.secretName }}
      items: [{ key: ca.crt, path: ca.crt }]    # the CA certificate only; never the listener key
  - name: tmp
    emptyDir: { sizeLimit: 16Mi }
{{- end }}
