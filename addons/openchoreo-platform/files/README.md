# Upstream OpenChoreo 1.3.3 platform defaults

Copied from `openchoreo/openchoreo@v1.3.3:samples/getting-started/` (the resources `all.yaml` applies), one object per
file, rendered verbatim by `templates/upstream-defaults.yaml` (no Helm templating inside these files).

| Here | Upstream | Change |
|---|---|---|
| `cluster-component-types/{scheduled-task,service,webapp,worker}.yaml` | `component-types/*.yaml` | see below |
| `cluster-traits/{health-probes,hpa,observability-alert-rule,pvc}.yaml` | `component-traits/{health-probes,hpa,alert-rule,pvc}-trait.yaml` | none |
| `cluster-project-types/default.yaml` | `cluster-project-types/default.yaml` | none |

Component types: upstream's `spec.allowedWorkflows` removed from the files (they name upstream's podman/buildpacks
ClusterWorkflows, which are not installed); `templates/upstream-defaults.yaml` sets it at render time to the platform's
build ClusterWorkflows (`buildWorkflows.stacks`, docs/build-plane.md). `vertical-pod-autoscaler` removed from
`spec.allowedTraits` (that trait is not installed; the VPA trait needs the VPA CRDs on data planes). Reproduce:

```bash
T='del(.spec.allowedWorkflows) | (select(.spec.allowedTraits) | .spec.allowedTraits) |=
   map(select(.name != "vertical-pod-autoscaler"))'
yq "$T" samples/getting-started/component-types/service.yaml > files/cluster-component-types/service.yaml
```

Not taken: `ClusterResourceType`s (postgres/valkey/nats; need operators on data planes), upstream `ClusterWorkflow`s and
workflow templates (replaced by templates/build-workflows.yaml + addon openchoreo-workflow-plane: rootless BuildKit,
koorikla/ci scripts, GitOps hand-off instead of writing Workloads through the API), `vertical-pod-autoscaler` (not installed), the sample `Project default` and
its `ProjectReleaseBinding`s (projects come from tenants), `Environment`s (charts/cluster renders them per cluster),
`DeploymentPipeline` (templates/deployment-pipeline.yaml, from values).
