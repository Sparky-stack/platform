{{- /*
ESO kubernetes-provider stores that read Secrets of this cluster through a dedicated ServiceAccount.
Users: addons/harbor (ca-store.yaml, pki.yaml), addons/openbao (ca-store.yaml, pki.yaml, tenant-secrets.yaml),
addons/secret-stores (_helpers.tpl, kubernetes backend).

koorikla-lib.esoSecretReader: ServiceAccount + Role + RoleBinding `eso-<name>` in <namespace> that may GET Secret
<secret> only. Why that is enough: ESO's kubernetes provider reads a remoteRef with one GET and validates the store with
a SelfSubjectRulesReview, which accepts a name-scoped get rule, so no list/watch and no other Secret is reachable.
Args (dict): name, secret, namespace; optional labels (rendered label lines) and automountServiceAccountToken.
*/ -}}
{{- define "koorikla-lib.esoSecretReader" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-{{ .name }}
  namespace: {{ .namespace }}
  {{- with .labels }}
  labels:
    {{- . | nindent 4 }}
  {{- end }}
{{- if hasKey . "automountServiceAccountToken" }}
automountServiceAccountToken: {{ .automountServiceAccountToken }}
{{- end }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-{{ .name }}
  namespace: {{ .namespace }}
  {{- with .labels }}
  labels:
    {{- . | nindent 4 }}
  {{- end }}
rules:
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [{{ .secret }}]
    verbs: [get]
  - apiGroups: [authorization.k8s.io]
    resources: [selfsubjectrulesreviews]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-{{ .name }}
  namespace: {{ .namespace }}
  {{- with .labels }}
  labels:
    {{- . | nindent 4 }}
  {{- end }}
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: eso-{{ .name }} }
subjects:
  - { kind: ServiceAccount, name: eso-{{ .name }}, namespace: {{ .namespace }} }
{{- end }}

{{- /*
koorikla-lib.esoKubernetesProvider: the `kubernetes:` block under a store's spec.provider (in-cluster API server,
trusted via ConfigMap kube-root-ca.crt). Args (dict): remoteNamespace (where the Secrets live), serviceAccount;
clusterStore (bool): a ClusterSecretStore has no namespace of its own, so the CA ConfigMap and the ServiceAccount
are looked up in `namespace` (the store's home namespace); a namespaced SecretStore uses its own namespace.
*/ -}}
{{- define "koorikla-lib.esoKubernetesProvider" -}}
kubernetes:
  remoteNamespace: {{ .remoteNamespace | quote }}
  server:
    url: https://kubernetes.default.svc
    caProvider:
      type: ConfigMap
      name: kube-root-ca.crt
      key: ca.crt
      {{- if .clusterStore }}
      namespace: {{ .namespace }}
      {{- end }}
  auth:
    serviceAccount:
      name: {{ .serviceAccount }}
      {{- if .clusterStore }}
      namespace: {{ .namespace }}
      {{- end }}
{{- end }}
