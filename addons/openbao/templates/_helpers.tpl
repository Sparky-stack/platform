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
