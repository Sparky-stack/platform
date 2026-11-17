{{- /*
secret-stores.store: one ClusterSecretStore and the identity it authenticates with. Dict arguments:
  root             the chart context (.)
  backend          kubernetes | aws | vault (anything else renders nothing)
  name             ClusterSecretStore name
  serviceAccount   ServiceAccount ESO authenticates as (in the release namespace)
  conditions       spec.conditions (list; omitted when empty: no namespace restriction)
  kubernetes: remoteNamespace (where the Secrets live; the Role is created there), resourceNames (key-scoped: GET on
              only these Secrets + SelfSubjectRulesReview create for ESO's store validation; default get, list, watch
              on every Secret of remoteNamespace), automountToken (false: automountServiceAccountToken: false)
  aws:        irsaRole (eks.amazonaws.com/role-arn annotation when set; default secrets.aws.role)
  vault:      vaultRole (kubernetes-auth role; default secrets.vault.auth.kubernetes.role), vaultPath (default
              secrets.vault.path, else platform)
*/ -}}
{{- define "secret-stores.store" -}}
{{- if has .backend (list "kubernetes" "aws" "vault") -}}
{{- $v := .root.Values.secrets -}}
{{- $ns := .root.Release.Namespace -}}
{{- $irsaRole := ternary .irsaRole ($v.aws).role (hasKey . "irsaRole") -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .serviceAccount }}
  namespace: {{ $ns }}
  {{- if and (eq .backend "aws") $irsaRole }}
  annotations:
    eks.amazonaws.com/role-arn: {{ $irsaRole | quote }}
  {{- end }}
{{- if eq (toString .automountToken) "false" }}
automountServiceAccountToken: false
{{- end }}
{{- if eq .backend "kubernetes" }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ .serviceAccount }}
  namespace: {{ .remoteNamespace | quote }}
rules:
  {{- with .resourceNames }}
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames:
      {{- toYaml . | nindent 6 }}
    verbs: ["get"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectrulesreviews"]
    verbs: ["create"]
  {{- else }}
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch"]
  {{- end }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .serviceAccount }}
  namespace: {{ .remoteNamespace | quote }}
subjects:
  - kind: ServiceAccount
    name: {{ .serviceAccount }}
    namespace: {{ $ns }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ .serviceAccount }}
{{- end }}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: {{ .name }}
spec:
  {{- with .conditions }}
  conditions:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  provider:
    {{- if eq .backend "kubernetes" }}
    kubernetes:
      remoteNamespace: {{ .remoteNamespace | quote }}
      server:
        url: https://kubernetes.default.svc
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
          namespace: {{ $ns }}
      auth:
        serviceAccount:
          name: {{ .serviceAccount }}
          namespace: {{ $ns }}
    {{- else if eq .backend "aws" }}
    aws:
      service: SecretsManager
      region: {{ $v.aws.region | quote }}
      {{- if $v.aws.prefix }}
      prefix: {{ $v.aws.prefix | quote }}
      {{- end }}
      auth:
        jwt:
          serviceAccountRef:
            name: {{ .serviceAccount }}
            namespace: {{ $ns }}
    {{- else if eq .backend "vault" }}
    vault:
      server: {{ $v.vault.server | quote }}
      path: {{ .vaultPath | default $v.vault.path | default "platform" | quote }}
      version: {{ $v.vault.version | default "v2" | quote }}
      auth:
        kubernetes:
          mountPath: {{ $v.vault.auth.kubernetes.mountPath | default "kubernetes" | quote }}
          role: {{ .vaultRole | default $v.vault.auth.kubernetes.role | quote }}
          serviceAccountRef:
            name: {{ .serviceAccount }}
            namespace: {{ $ns }}
    {{- end }}
{{- end -}}
{{- end -}}

{{- /*
Store `platform` holds every platform credential (GitHub read + write Apps, GHCR, cloud, OpenChoreo): only the mgmt
namespaces in platformStore.namespaces may reference it, never a workflows-* run namespace.
hack/tests/test_secret_store_scope.sh checks that every rendered ExternalSecret using it is in that list.
*/ -}}
{{- define "secret-stores.platformConditions" -}}
{{- $ns := .Values.platformStore.namespaces | default list -}}
{{- if not $ns }}{{ fail "platformStore.namespaces must list the namespaces allowed to read ClusterSecretStore platform" }}{{ end -}}
{{- range $ns -}}
{{- if hasPrefix "workflows-" (toString .) }}{{ fail (printf "platformStore.namespaces must not include workflow run namespace %q: use ClusterSecretStore workflows (key-scoped)" .) }}{{ end -}}
{{- end -}}
- namespaces:
    {{- toYaml $ns | nindent 4 }}
{{- end -}}

{{- /* Store `workflows` admits only workflow run namespaces (workflowStore.namespaceRegexes, each ^workflows-...). */ -}}
{{- define "secret-stores.workflowConditions" -}}
{{- $re := (.Values.workflowStore).namespaceRegexes | default list -}}
{{- if not $re }}{{ fail "workflowStore.namespaceRegexes must restrict ClusterSecretStore workflows to workflow run namespaces" }}{{ end -}}
{{- range $re -}}
{{- if not (hasPrefix "^workflows-" (toString .)) }}{{ fail (printf "workflowStore.namespaceRegexes entry %q must start with ^workflows-" .) }}{{ end -}}
{{- end -}}
- namespaceRegexes:
    {{- toYaml $re | nindent 4 }}
{{- end -}}
