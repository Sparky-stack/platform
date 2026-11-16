{{- define "harbor-addon.hostname" -}}
{{- regexReplaceAll ":[0-9]+$" (required "registry.host is required" .Values.registry.host) "" -}}
{{- end }}

{{- define "harbor-addon.port" -}}
{{- $m := regexFind ":[0-9]+$" .Values.registry.host -}}
{{- if $m }}{{ trimPrefix ":" $m }}{{ else }}443{{ end -}}
{{- end }}

{{- /* Project names: apps, apps-ghcr (replication targets) and every proxy-cache project, in that order. */ -}}
{{- define "harbor-addon.proxyProjects" -}}
{{- $out := list -}}
{{- range .Values.registry.proxyCache }}{{ $out = append $out .project }}{{ end -}}
{{- toJson $out -}}
{{- end }}

{{- /* Pod spec of the harbor-config Job and CronJob (templates/config.yaml). */ -}}
{{- define "harbor-addon.configPod" }}
restartPolicy: OnFailure
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: harbor-config
    image: {{ .Values.config.image }}
    command: [python3, /config/harbor-config.py, /config/state.json]
    env:
      - { name: HARBOR_URL, value: {{ .Values.config.coreURL | quote }} }
      - { name: PYTHONUNBUFFERED, value: "1" }
      - name: HARBOR_ADMIN_PASSWORD
        valueFrom: { secretKeyRef: { name: {{ .Values.secrets.secretName }}, key: HARBOR_ADMIN_PASSWORD } }
      - name: GHCR_USERNAME
        valueFrom: { secretKeyRef: { name: {{ .Values.secrets.secretName }}, key: ghcr-username, optional: true } }
      - name: GHCR_TOKEN
        valueFrom: { secretKeyRef: { name: {{ .Values.secrets.secretName }}, key: ghcr-token, optional: true } }
      {{- range .Values.config.robots }}
      - name: {{ printf "ROBOT_%s" (.name | upper | replace "-" "_") }}
        valueFrom: { secretKeyRef: { name: {{ $.Values.secrets.secretName }}, key: {{ printf "robot-%s" .name }} } }
      {{- end }}
    resources: {{- toYaml .Values.config.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: config, mountPath: /config, readOnly: true }
volumes:
  - name: config
    configMap: { name: harbor-config }
{{- end }}
