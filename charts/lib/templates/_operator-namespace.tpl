{{- /*
koorikla-lib.operatorNamespace (root context; values namespace.{podSecurity,ambient}).
Users: addons/cloudnative-pg, addons/keda, addons/strimzi (templates/namespace.yaml).
Labels the operator's own namespace: Pod Security admission level (enforce/audit/warn, "" = no labels) and Istio ambient
enrolment (the operator reaches pods in cell namespaces, which enforce STRICT mTLS; #53). Argo CD creates the namespace
(CreateNamespace=true); this object only adds the labels, so nothing renders when both are off.
*/ -}}
{{- define "koorikla-lib.operatorNamespace" }}
{{- if or .Values.namespace.podSecurity .Values.namespace.ambient }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Release.Namespace }}
  labels:
    {{- with .Values.namespace.podSecurity }}
    pod-security.kubernetes.io/enforce: {{ . | quote }}
    pod-security.kubernetes.io/audit: {{ . | quote }}
    pod-security.kubernetes.io/warn: {{ . | quote }}
    {{- end }}
    {{- if .Values.namespace.ambient }}
    istio.io/dataplane-mode: ambient
    {{- end }}
{{- end }}
{{- end }}
