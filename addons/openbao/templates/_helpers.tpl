{{- /* Mesh groups of the installation (installation.yaml mesh.groups), validated: DNS labels, no duplicates. */ -}}
{{- define "openbao-addon.groups" -}}
{{- $groups := (.Values.mesh | default dict).groups | default list -}}
{{- range $g := $groups -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$" (toString $g)) -}}
{{- fail (printf "openbao: mesh.groups entry %q must be a DNS label (lower-case alphanumerics and '-', max 32 chars)" (toString $g)) -}}
{{- end -}}
{{- end -}}
{{- if ne (len $groups) (len (uniq $groups)) -}}{{- fail "openbao: mesh.groups has duplicates" -}}{{- end -}}
{{- toJson $groups -}}
{{- end }}

{{- /* Address members dial (installation.yaml mesh.ca): host = SNI of the TLS passthrough listener + a SAN of the
listener cert; port = Gateway listener port = k3d published port (bootstrap/k3d-mgmt.yaml, contract test). */ -}}
{{- define "openbao-addon.host" -}}
{{- required "mesh.ca.host is required (installation.yaml)" ((.Values.mesh | default dict).ca | default dict).host -}}
{{- end }}
{{- define "openbao-addon.port" -}}
{{- $p := required "mesh.ca.port is required (installation.yaml)" ((.Values.mesh | default dict).ca | default dict).port -}}
{{- if not (regexMatch "^[0-9]+$" (toString $p)) }}{{ fail (printf "openbao: mesh.ca.port %v must be a port number" $p) }}{{ end -}}
{{- $p -}}
{{- end }}

{{- define "openbao-addon.labels" -}}
app.kubernetes.io/part-of: openbao
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- /* Pod spec of the mesh reconcile Job/CronJob (templates/reconcile.yaml); context: dict r env img meshClients tlsSecret. */ -}}
{{- define "openbao-addon.reconcilePod" }}
serviceAccountName: {{ .r.serviceAccount }}
automountServiceAccountToken: false
restartPolicy: Never
securityContext:
  runAsNonRoot: true
  runAsUser: 100
  runAsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: reconcile
    image: {{ printf "%s/%s:%s" .img.registry .img.repository .img.tag | quote }}
    command: [/bin/sh, /scripts/mesh-reconcile.sh]
    env:
      {{- toYaml .env | nindent 6 }}
    resources:
      {{- toYaml .r.resources | nindent 6 }}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: scripts, mountPath: /scripts, readOnly: true }
      - { name: inputs, mountPath: /inputs, readOnly: true }
      - { name: token, mountPath: /var/run/secrets/openbao, readOnly: true }
      - { name: tls-ca, mountPath: /openbao/tls, readOnly: true }
      - { name: tmp, mountPath: /tmp }
volumes:
  - name: scripts
    configMap: { name: mesh-reconcile }
  - name: inputs
    secret: { secretName: {{ .meshClients }}, optional: true }    # no members yet: groups only
  - name: token
    projected:
      sources:
        - serviceAccountToken: { audience: {{ .r.audience | quote }}, expirationSeconds: 600, path: token }
  - name: tls-ca
    secret:
      secretName: {{ .tlsSecret }}
      items: [{ key: ca.crt, path: ca.crt }]    # the CA certificate only; never the listener key
  - name: tmp
    emptyDir: { sizeLimit: 16Mi }
{{- end }}
