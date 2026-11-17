# openchoreo-platform

## Purpose

Renders platform-owned OpenChoreo resources on `mgmt`: the org namespace (`default`), `DeploymentPipeline/default`, upstream `ClusterComponentType`/`ClusterTrait`/`ClusterProjectType` defaults, stack build `ClusterWorkflow`s, the auto-build trigger (Argo `WorkflowTemplate`/`CronWorkflow` `auto-build` in `workflows-<org ns>`), and `production` promotion gates (Git-only admission, ABAC role, and `ClusterWorkflow/promotion-gate`).

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: default`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-platform` (`default: true`, opt-out with `"false"`).

## Key values

- `deploymentPipeline.{name,environments}`: `[development, staging, production]`.
- `promotion.{gatedEnvironments,restrictedGroups,gitOnly,freezeWindows}`: restricts `production` binding writes to Argo CD and enforces sync freeze windows.
- `promotionGate.{enabled,smoke,observe,statusContext}`: HTTP smoke + 15-minute Prometheus 5xx SLO gate posting `openchoreo/promotion-gate` on PRs.
- `buildWorkflows.{stacks,platforms,secrets}` and `helmChartWorkflow`: language stack build workflows (`go`, `nextjs`, `elixir`, `ruby`, `dockerfile`) and chart deploy workflow.
- `autoBuild.{pollSchedule,resyncSchedule,github}`: builds Components with `autoBuild: true` once per new commit; trigger per installation `openchoreo.workflowPlane.autoBuild` (`poll` | `webhook` | `none`).
- `autoBuild.previews.*` (with `installation.yaml` `previews.enabled`): the same pass builds PR heads, cuts the preview `ComponentRelease`, posts `openchoreo/preview` and expires previews ([preview environments](../../docs/preview-environments.md)).

## Day-2 notes

- Failed promotion gates or emergency overrides: [incidents](../../docs/runbooks/incidents.md#promotion-gate-failing-closed) and [break-glass](../../docs/runbooks/break-glass.md#emergency-production-promotion-or-freeze-window-override).

## Links

- [OpenChoreo](../../docs/openchoreo.md)
- [Promotion gates](../../docs/promotion.md)
- [Build plane](../../docs/build-plane.md)
