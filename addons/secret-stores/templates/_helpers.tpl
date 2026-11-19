{{- /*
secret-stores.store: one ClusterSecretStore and the identity it authenticates with. Dict arguments:
  root             the chart context (.)
  backend          kubernetes | aws | vault (validated once, at the top of stores.yaml)
  name             ClusterSecretStore name
  serviceAccount   ServiceAccount ESO authenticates as (in the release namespace)
  conditions       spec.conditions (list; omitted when empty: no namespace restriction)
  noTokenAutomount true: automountServiceAccountToken: false
  kubernetes: remoteNamespace (where the Secrets live; the Role is created there), resourceNames (key-scoped: GET on
              only these Secrets + SelfSubjectRulesReview create for ESO's store validation; default get, list, watch
              on every Secret of remoteNamespace)
  aws:        irsaRole (eks.amazonaws.com/role-arn annotation when set; default secrets.aws.role)
  vault:      vaultRole (kubernetes-auth role; default secrets.vault.auth.kubernetes.role), vaultPath (default
              secrets.vault.path, else platform)
*/ -}}
{{- define "secret-stores.store" -}}
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
{{- if .noTokenAutomount }}
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
