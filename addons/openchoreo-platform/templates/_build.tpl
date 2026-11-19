{{- /* Helpers shared by the build ClusterWorkflows (build-workflows.yaml, helm-chart-workflow.yaml) and auto-build.yaml. */ -}}

{{- /* Registry host (CA/credential scope) for builds: harbor -> registry.host, external -> first path element. */ -}}
{{- define "build.registryHost" -}}
{{- if eq (toString .Values.registry.type) "harbor" -}}
{{- required "registry.host is required for registry.type harbor" .Values.registry.host -}}
{{- else -}}
{{- index (splitList "/" (required "registry.external.repository is required" .Values.registry.external.repository)) 0 -}}
{{- end -}}
{{- end }}

{{- /*
Git repository allowlist: URL prefixes (https, ending in "/") builds may clone from and push to; default the
installation's githubOrg. build.gitPrefixes -> space-separated (the Argo parameter); build.repoUrlPattern -> the
schema pattern for repository.url (one path segment after a prefix, starting alphanumeric: no "..", no "/").
*/ -}}
{{- define "build.gitPrefixList" -}}
{{- $p := .Values.buildWorkflows.git.allowedRepositoryPrefixes | default list -}}
{{- if not $p -}}
{{- $org := required "installation.githubOrg (or buildWorkflows.git.allowedRepositoryPrefixes) is required" .Values.installation.githubOrg -}}
{{- $p = list (printf "%s/" (trimSuffix "/" $org)) -}}
{{- end -}}
{{- range $p -}}
{{- if not (regexMatch "^https://[A-Za-z0-9.-]+(:[0-9]+)?/([A-Za-z0-9][A-Za-z0-9._-]*/)+$" .) -}}
{{- fail (printf "buildWorkflows.git.allowedRepositoryPrefixes: %q must be https://<host>/<owner>/ (ending in /)" .) -}}
{{- end -}}
{{- end -}}
{{- toJson $p -}}
{{- end }}

{{- define "build.gitPrefixes" -}}
{{- include "build.gitPrefixList" . | fromJsonArray | join " " -}}
{{- end }}

{{- define "build.repoUrlPattern" -}}
{{- $q := list -}}
{{- range (include "build.gitPrefixList" . | fromJsonArray) -}}
{{- $q = append $q (regexQuoteMeta .) -}}
{{- end -}}
{{- printf "^(%s)[A-Za-z0-9][A-Za-z0-9._-]*$" (join "|" $q) -}}
{{- end }}

{{- /* Repository-relative path (appPath, docker.context, docker.filePath, chart.path): no "..", no absolute path. */ -}}
{{- define "build.relPathPattern" -}}
^(\.|(\./)?\.?[A-Za-z0-9_][A-Za-z0-9._-]*(/\.?[A-Za-z0-9_][A-Za-z0-9._-]*)*/?)$
{{- end }}

{{- /* Repository prefix builds push under (component/chart name appended by the caller). */ -}}
{{- define "build.repoPrefix" -}}
{{- if eq (toString .Values.registry.type) "harbor" -}}
{{- printf "%s/%s" .Values.registry.host .Values.registry.appsProject -}}
{{- else -}}
{{- .Values.registry.external.repository -}}
{{- end -}}
{{- end }}

{{- /*
Per-run resources of a ClusterWorkflow: OpenChoreo renders them into workflows-<org ns> for every WorkflowRun
(CEL ${...}), ESO materializes them ({{ }} escaped for Helm), the Argo pods mount the Secrets by name.
  <run>-git          GithubAccessToken         ESO generator: an installation token of the platform GitHub App for the
                                               run's one repository, `permissions` only
  <run>-git          kubernetes.io/basic-auth  that token (x-access-token): clone + GitOps commit, re-minted every
                                               buildWorkflows.github.tokenRefreshInterval
  <run>-registry     dockerconfigjson          push/pull the registry      (harbor robot builder | external credentials)
  <run>-registry-ca  ca.crt                    registry CA public cert     (harbor only, store mgmt-harbor)
  <run>-cosign       cosign.key/password       platform signing key        (key buildWorkflows.secrets.cosign)
Call: include "build.resources" (dict "root" $ "permissions" <map> ["gitopsAware" true]). gitopsAware: a run with
gitops.enabled false (e.g. PR previews) gets readPermissions instead (nothing to write).
*/ -}}
{{- define "build.resources" -}}
{{- $gitopsAware := .gitopsAware }}
{{- $perms := required "build.resources: permissions (buildWorkflows.github.permissions / readPermissions) are required" .permissions }}
{{- with .root }}
{{- $g := .Values.buildWorkflows.github }}
{{- $app := required "buildWorkflows.github.appSecret is required" $g.appSecret }}
{{- $s := .Values.buildWorkflows.secrets }}
{{- $host := include "build.registryHost" . }}
{{- $harbor := eq (toString .Values.registry.type) "harbor" }}
{{- /* CEL: the repository name of repository.url (last path segment, ".git" removed); build.repoUrlPattern guarantees
exactly one segment after an allowed prefix. */ -}}
{{- $repoName := "${parameters.repository.url.substring(parameters.repository.url.lastIndexOf('/') + 1, size(parameters.repository.url) - (parameters.repository.url.endsWith('.git') ? 4 : 0))}" }}
- id: git-token
  template:
    apiVersion: generators.external-secrets.io/v1alpha1
    kind: GithubAccessToken
    metadata:
      name: ${metadata.workflowRunName}-git
      namespace: ${metadata.namespace}
    spec:
      {{- with $g.apiURL }}
      url: {{ . | quote }}
      {{- end }}
      appIDRef: { name: {{ $app }}, key: app-id }
      installIDRef: { name: {{ $app }}, key: installation-id }
      repositories: [{{ $repoName | quote }}]
      permissions:
        {{- range $k, $v := $perms }}
        {{- if and $gitopsAware (hasKey $g.readPermissions $k) (ne (toString $v) (toString (get $g.readPermissions $k))) }}
        {{ $k }}: {{ printf "${parameters.gitops.enabled ? '%s' : '%s'}" $v (get $g.readPermissions $k) | quote }}
        {{- else }}
        {{ $k }}: {{ $v | quote }}
        {{- end }}
        {{- end }}
      auth:
        privateKey:
          secretRef: { name: {{ $app }}, key: private-key }
- id: git-secret
  template:
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: ${metadata.workflowRunName}-git
      namespace: ${metadata.namespace}
    spec:
      refreshInterval: {{ required "buildWorkflows.github.tokenRefreshInterval is required (tokens expire after 1h)" $g.tokenRefreshInterval }}
      target:
        name: ${metadata.workflowRunName}-git
        creationPolicy: Owner
        template:
          type: kubernetes.io/basic-auth
          engineVersion: v2
          data:
            username: x-access-token
            password: {{`"{{ .token }}"`}}
      dataFrom:
        - sourceRef:
            generatorRef:
              apiVersion: generators.external-secrets.io/v1alpha1
              kind: GithubAccessToken
              name: ${metadata.workflowRunName}-git
- id: registry-secret
  template:
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: ${metadata.workflowRunName}-registry
      namespace: ${metadata.namespace}
    spec:
      refreshInterval: 1h
      secretStoreRef: { kind: ClusterSecretStore, name: "${workflowplane.secretStore}" }
      target:
        name: ${metadata.workflowRunName}-registry
        creationPolicy: Owner
        template:
          engineVersion: v2
          type: kubernetes.io/dockerconfigjson
          data:
            {{- if $harbor }}
            {{- $u := $s.harbor.robot }}
            .dockerconfigjson: '{"auths":{ {{- $host | toJson -}} :{"username": {{- $u | toJson -}} ,"password":{{`{{ .password | toJson }}`}},"auth":{{`{{ printf "%s:%s" `}}{{ $u | quote }}{{` .password | b64enc | toJson }}`}}}}}'
            {{- else }}
            .dockerconfigjson: '{"auths":{ {{- $host | toJson -}} :{"username":{{`{{ .username | toJson }}`}},"password":{{`{{ .password | toJson }}`}},"auth":{{`{{ printf "%s:%s" .username .password | b64enc | toJson }}`}}}}}'
            {{- end }}
      data:
        {{- if $harbor }}
        - { secretKey: password, remoteRef: { key: {{ $s.harbor.key }}, property: {{ $s.harbor.property }} } }
        {{- else }}
        - { secretKey: username, remoteRef: { key: {{ .Values.registry.external.credentialsKey }}, property: username } }
        - { secretKey: password, remoteRef: { key: {{ .Values.registry.external.credentialsKey }}, property: token } }
        {{- end }}
{{- if $harbor }}
- id: registry-ca
  template:
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: ${metadata.workflowRunName}-registry-ca
      namespace: ${metadata.namespace}
    spec:
      refreshInterval: 1h
      secretStoreRef: { kind: ClusterSecretStore, name: {{ $s.harbor.caStore }} }
      target:
        name: ${metadata.workflowRunName}-registry-ca
        creationPolicy: Owner
      data:
        - { secretKey: ca.crt, remoteRef: { key: {{ $s.harbor.caSecret }}, property: ca.crt } }
{{- end }}
- id: cosign-secret
  template:
    apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    metadata:
      name: ${metadata.workflowRunName}-cosign
      namespace: ${metadata.namespace}
    spec:
      refreshInterval: 1h
      secretStoreRef: { kind: ClusterSecretStore, name: "${workflowplane.secretStore}" }
      target:
        name: ${metadata.workflowRunName}-cosign
        creationPolicy: Owner
      data:
        - { secretKey: cosign.key, remoteRef: { key: {{ $s.cosign }}, property: cosign.key } }
        - { secretKey: cosign.password, remoteRef: { key: {{ $s.cosign }}, property: cosign.password } }
{{- end }}
{{- end }}
