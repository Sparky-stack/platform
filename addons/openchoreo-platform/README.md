# openchoreo-platform

## Purpose

Renders platform-owned OpenChoreo resources on `mgmt`: the org namespace (`default`), `DeploymentPipeline/default`, upstream `ClusterComponentType`/`ClusterTrait`/`ClusterProjectType` defaults, the data-service types `ClusterTrait keda-scaler` and `ClusterResourceType postgresql` (docs/data-services.md), stack build `ClusterWorkflow`s, the auto-build trigger (Argo `WorkflowTemplate`/`CronWorkflow` `auto-build` in `workflows-<org ns>`), and `production` promotion gates (Git-only admission, ABAC role, and `ClusterWorkflow/promotion-gate`).

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: default`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-platform` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| autoBuild.github.key | string | `"promotion-gate-github"` |  |
| autoBuild.github.permissions.contents | string | `"read"` |  |
| autoBuild.github.tokenRefreshInterval | string | `"30m"` |  |
| autoBuild.image | string | `"docker.io/library/python:3.14.10-alpine3.24@sha256:5862d971d1f0ae26b258cefa4e893556b1d3aba81bd2ff30888704ad378bab67"` |  |
| autoBuild.maxRunsPerPass | int | `5` |  |
| autoBuild.minRateRemaining | int | `100` |  |
| autoBuild.pollSchedule | string | `"* * * * *"` | Builds Components with `autoBuild: true` once per new commit (`autoBuild.{pollSchedule,resyncSchedule,github}`); trigger per installation `openchoreo.workflowPlane.autoBuild` (`poll` | `webhook` | `none`). |
| autoBuild.previews.argocdNamespace | string | `"argocd"` |  |
| autoBuild.previews.github.permissions.pull_requests | string | `"write"` |  |
| autoBuild.previews.github.permissions.statuses | string | `"write"` |  |
| autoBuild.previews.optIn.annotation | string | `"platform.koorikla.io/preview-environments"` |  |
| autoBuild.previews.optIn.value | string | `"enabled"` |  |
| autoBuild.previews.schedule | string | `"*/2 * * * *"` |  |
| autoBuild.previews.statusContext | string | `"openchoreo/preview"` | With `installation.yaml` `previews.enabled`, builds PR heads, cuts the preview `ComponentRelease`, posts `openchoreo/preview` and expires previews ([preview environments](../../docs/preview-environments.md)). |
| autoBuild.registry.key | string | `"harbor"` |  |
| autoBuild.registry.property | string | `"nodes-secret"` |  |
| autoBuild.registry.robot | string | `"robot$nodes"` |  |
| autoBuild.resources.limits.memory | string | `"96Mi"` |  |
| autoBuild.resources.requests.cpu | string | `"10m"` |  |
| autoBuild.resources.requests.memory | string | `"32Mi"` |  |
| autoBuild.resyncSchedule | string | `"*/30 * * * *"` |  |
| autoBuild.secretStore | string | `"workflows"` |  |
| autoBuild.staleRunSeconds | int | `7200` |  |
| autoBuild.stateConfigMap | string | `"auto-build-state"` |  |
| autoBuild.workflowTemplate | string | `"auto-build"` |  |
| buildWorkflows.enabled | bool | `true` | Language stack build workflows (`buildWorkflows.{stacks,platforms,secrets}`: `go`, `nextjs`, `elixir`, `ruby`, `dockerfile`) and chart deploy workflow (`helmChartWorkflow`). |
| buildWorkflows.git.allowedRepositoryPrefixes | list | `[]` |  |
| buildWorkflows.github.agent.namespace | string | `"openchoreo-workflow-plane"` |  |
| buildWorkflows.github.agent.serviceAccount | string | `"cluster-agent-workflowplane"` |  |
| buildWorkflows.github.apiURL | string | `""` |  |
| buildWorkflows.github.appSecret | string | `"build-github-app"` |  |
| buildWorkflows.github.key | string | `"promotion-gate-github"` | Per-run GitHub App installation tokens (`buildWorkflows.github`) for the run's one repository (ESO `GithubAccessToken` generator; `contents: write` for builds, `read` for charts), no PAT. |
| buildWorkflows.github.permissions.contents | string | `"write"` |  |
| buildWorkflows.github.readPermissions.contents | string | `"read"` |  |
| buildWorkflows.github.secretStore | string | `"workflows"` |  |
| buildWorkflows.github.tokenRefreshInterval | string | `"30m"` |  |
| buildWorkflows.platforms | string | `"linux/amd64,linux/arm64"` |  |
| buildWorkflows.secrets.cosign | string | `"cosign-platform"` |  |
| buildWorkflows.secrets.harbor.caSecret | string | `"harbor-ca-bundle"` |  |
| buildWorkflows.secrets.harbor.caStore | string | `"mgmt-harbor"` |  |
| buildWorkflows.secrets.harbor.key | string | `"harbor"` |  |
| buildWorkflows.secrets.harbor.property | string | `"builder-secret"` |  |
| buildWorkflows.secrets.harbor.robot | string | `"robot$builder"` |  |
| buildWorkflows.signing | object | `{"transparencyLog":false}` | insecure-ignore-tlog=true`. true: also upload to public Rekor (needs egress to Sigstore). Per installation in installations/<inst>/addons/openchoreo-platform/values.yaml. docs/build-plane.md "Signing". |
| buildWorkflows.stacks[0].checkEnv.RUN_LINT | string | `"true"` |  |
| buildWorkflows.stacks[0].checkEnv.RUN_VULNCHECK | string | `"true"` |  |
| buildWorkflows.stacks[0].checkImage | string | `"docker.io/library/golang:1.27.4-trixie@sha256:b54b2639de8c1bfe538ec5ffc45f29b1932235ac5f6d63c059853646677112d9"` |  |
| buildWorkflows.stacks[0].checkSetup | string | `""` |  |
| buildWorkflows.stacks[0].description | string | `"Go module - go vet, golangci-lint (if present), go test -race, govulncheck, multi-arch image"` |  |
| buildWorkflows.stacks[0].displayName | string | `"Go"` |  |
| buildWorkflows.stacks[0].name | string | `"go"` |  |
| buildWorkflows.stacks[0].stack | string | `"go"` |  |
| buildWorkflows.stacks[1].checkEnv.AUDIT_LEVEL | string | `"critical"` |  |
| buildWorkflows.stacks[1].checkEnv.RUN_AUDIT | string | `"true"` |  |
| buildWorkflows.stacks[1].checkEnv.RUN_BUILD | string | `"true"` |  |
| buildWorkflows.stacks[1].checkEnv.RUN_LINT | string | `"true"` |  |
| buildWorkflows.stacks[1].checkEnv.RUN_TEST | string | `"true"` |  |
| buildWorkflows.stacks[1].checkEnv.RUN_TYPECHECK | string | `"true"` |  |
| buildWorkflows.stacks[1].checkImage | string | `"docker.io/library/node:24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0"` |  |
| buildWorkflows.stacks[1].checkSetup | string | `""` |  |
| buildWorkflows.stacks[1].description | string | `"Next.js app - install, lint, typecheck, test, next build, dependency audit, multi-arch image"` |  |
| buildWorkflows.stacks[1].displayName | string | `"Next.js"` |  |
| buildWorkflows.stacks[1].name | string | `"nextjs"` |  |
| buildWorkflows.stacks[1].stack | string | `"nextjs"` |  |
| buildWorkflows.stacks[2].checkEnv.MIX_ENV | string | `"test"` |  |
| buildWorkflows.stacks[2].checkEnv.RUN_AUDIT | string | `"true"` |  |
| buildWorkflows.stacks[2].checkEnv.RUN_CREDO | string | `"true"` |  |
| buildWorkflows.stacks[2].checkEnv.RUN_FORMAT | string | `"true"` |  |
| buildWorkflows.stacks[2].checkEnv.RUN_SOBELOW | string | `"true"` |  |
| buildWorkflows.stacks[2].checkEnv.RUN_TEST | string | `"true"` |  |
| buildWorkflows.stacks[2].checkImage | string | `"docker.io/library/elixir:1.19.7-otp-28@sha256:7e27df3e4a684163e4a18e618eede53badb70e97e0c92a1845ab22e2e1d96da2"` |  |
| buildWorkflows.stacks[2].checkSetup | string | `"mix local.hex --force && mix local.rebar --force"` |  |
| buildWorkflows.stacks[2].description | string | `"mix project - compile --warnings-as-errors, format, credo, test (+ PostgreSQL), sobelow, audits, image"` |  |
| buildWorkflows.stacks[2].displayName | string | `"Elixir / Phoenix"` |  |
| buildWorkflows.stacks[2].name | string | `"elixir"` |  |
| buildWorkflows.stacks[2].postgres | bool | `true` |  |
| buildWorkflows.stacks[2].stack | string | `"elixir"` |  |
| buildWorkflows.stacks[3].checkEnv.RUN_AUDIT | string | `"true"` |  |
| buildWorkflows.stacks[3].checkEnv.RUN_BRAKEMAN | string | `"auto"` |  |
| buildWorkflows.stacks[3].checkEnv.RUN_RUBOCOP | string | `"true"` |  |
| buildWorkflows.stacks[3].checkEnv.TEST_COMMAND | string | `"auto"` |  |
| buildWorkflows.stacks[3].checkImage | string | `"docker.io/library/ruby:3.4.12-trixie@sha256:5803b69dd8a875a9afc7e3bbc10d0ba683e12aad2640dbbd44295b4890cc8927"` |  |
| buildWorkflows.stacks[3].checkSetup | string | `"bundle install --jobs 4"` |  |
| buildWorkflows.stacks[3].description | string | `"Bundler app - rubocop, rspec / rails test (+ PostgreSQL), brakeman, bundler-audit, image"` |  |
| buildWorkflows.stacks[3].displayName | string | `"Ruby / Rails"` |  |
| buildWorkflows.stacks[3].name | string | `"ruby"` |  |
| buildWorkflows.stacks[3].postgres | bool | `true` |  |
| buildWorkflows.stacks[3].stack | string | `"ruby"` |  |
| buildWorkflows.stacks[4].checkEnv | object | `{}` |  |
| buildWorkflows.stacks[4].checkImage | string | `""` |  |
| buildWorkflows.stacks[4].checkSetup | string | `""` |  |
| buildWorkflows.stacks[4].description | string | `"Any Dockerfile - dependency scan, multi-arch image, scan, SBOM, signature (no language checks)"` |  |
| buildWorkflows.stacks[4].displayName | string | `"Dockerfile"` |  |
| buildWorkflows.stacks[4].name | string | `"dockerfile"` |  |
| buildWorkflows.stacks[4].stack | string | `"none"` |  |
| buildWorkflows.ttlAfterCompletion | string | `"1d"` |  |
| buildWorkflows.workflowPlane | string | `"default"` |  |
| buildWorkflows.workflowTemplate | string | `"koorikla-build"` |  |
| dataServices.enabled | bool | `true` | Platform types for the data-service addons (`files/platform/`); usable only where the data plane announces the addon (`platform.koorikla.io/requires-addons`). |
| deploymentPipeline.environments | list | `["development","staging","production"]` | `[development, staging, production]`. |
| deploymentPipeline.name | string | `"default"` |  |
| helmChartWorkflow.enabled | bool | `true` |  |
| helmChartWorkflow.name | string | `"helm-chart"` |  |
| helmChartWorkflow.workflowTemplate | string | `"koorikla-helm-chart"` |  |
| installation.githubOrg | string | `"https://github.com/koorikla"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` |  |
| openchoreo.observability.enabled | bool | `true` |  |
| openchoreo.observability.httpPort | int | `11080` |  |
| openchoreo.orgNamespace | string | `"default"` |  |
| openchoreo.workflowPlane.autoBuild | string | `"poll"` |  |
| openchoreo.workflowPlane.enabled | bool | `true` |  |
| previews.enabled | bool | `false` |  |
| promotion.freezeWindows[0].end | string | `"Mon 08:00"` |  |
| promotion.freezeWindows[0].environments[0] | string | `"production"` |  |
| promotion.freezeWindows[0].name | string | `"weekend"` |  |
| promotion.freezeWindows[0].start | string | `"Fri 16:00"` |  |
| promotion.freezeWindows[0].timeZone | string | `"Europe/Tallinn"` |  |
| promotion.gatedEnvironments | list | `["production"]` | Restricts `production` binding writes to Argo CD (`promotion.{gatedEnvironments,restrictedGroups,gitOnly,freezeWindows}`) and enforces sync freeze windows. |
| promotion.gitOnly.breakGlassGroups | list | `[]` |  |
| promotion.gitOnly.deleters[0] | string | `"system:serviceaccount:kube-system:generic-garbage-collector"` |  |
| promotion.gitOnly.deleters[1] | string | `"system:serviceaccount:kube-system:namespace-controller"` |  |
| promotion.gitOnly.enabled | bool | `true` |  |
| promotion.gitOnly.metadataWriters[0] | string | `"system:serviceaccount:openchoreo-control-plane:controller-manager"` |  |
| promotion.gitOnly.writers[0] | string | `"system:serviceaccount:argocd:argocd-application-controller"` |  |
| promotion.restrictedGroups[0] | string | `"developers"` |  |
| promotionGate.apiURL | string | `""` |  |
| promotionGate.autoTrigger.sourceEnvironments[0] | string | `"staging"` |  |
| promotionGate.baseBranch | string | `"main"` |  |
| promotionGate.bindingPath | string | `"deploy/openchoreo/release-bindings/{environment}.yaml"` |  |
| promotionGate.clientID | string | `"openchoreo-promotion-gate"` |  |
| promotionGate.clientSecret.key | string | `"promotion-gate"` |  |
| promotionGate.clientSecret.property | string | `"client-secret"` |  |
| promotionGate.controlPlanePort | int | `8080` |  |
| promotionGate.enabled | bool | `true` | HTTP `smoke` + 15-minute Prometheus 5xx SLO gate (`observe`) posting `statusContext` (`openchoreo/promotion-gate`) on PRs. |
| promotionGate.github.key | string | `"promotion-gate-github"` |  |
| promotionGate.image | string | `"docker.io/library/python:3.14.10-alpine3.24@sha256:5862d971d1f0ae26b258cefa4e893556b1d3aba81bd2ff30888704ad378bab67"` |  |
| promotionGate.observe.enabled | bool | `true` |  |
| promotionGate.observe.maxErrorRate | float | `0.05` |  |
| promotionGate.observe.windowMinutes | int | `15` |  |
| promotionGate.observerURL | string | `""` |  |
| promotionGate.podLabels."platform.koorikla.io/egress" | string | `"openchoreo"` |  |
| promotionGate.prometheusURL | string | `"http://openchoreo-observability-prometheus.openchoreo-observability-plane:9091"` |  |
| promotionGate.resources.limits.memory | string | `"128Mi"` |  |
| promotionGate.resources.requests.cpu | string | `"20m"` |  |
| promotionGate.resources.requests.memory | string | `"48Mi"` |  |
| promotionGate.smoke.http | bool | `true` |  |
| promotionGate.smoke.path | string | `"/"` |  |
| promotionGate.statusContext | string | `"openchoreo/promotion-gate"` |  |
| promotionGate.tokenURL | string | `""` |  |
| promotionGate.ttlAfterCompletion | string | `"1h"` |  |
| promotionGate.workflowPlane | string | `"default"` |  |
| registry.appsProject | string | `"apps"` |  |
| registry.external.credentialsKey | string | `"platform-ghcr"` |  |
| registry.external.repository | string | `"ghcr.io/koorikla"` |  |
| registry.host | string | `"harbor.openchoreo.localhost:9443"` |  |
| registry.type | string | `"harbor"` |  |
| secrets.tenantStores.enabled | bool | `false` |  |
| tenantStoreName | string | `"openbao-tenant"` |  |
| upstreamDefaults.enabled | bool | `true` |  |

## Day-2 notes

- Failed promotion gates or emergency overrides: [incidents](../../docs/runbooks/incidents.md#promotion-gate-failing-closed) and [break-glass](../../docs/runbooks/break-glass.md#emergency-production-promotion-or-freeze-window-override).

## Links

- [OpenChoreo](../../docs/openchoreo.md)
- [Promotion gates](../../docs/promotion.md)
- [Build plane](../../docs/build-plane.md)