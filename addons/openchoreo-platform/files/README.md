# Upstream OpenChoreo 1.3.3 platform defaults

Copied from `openchoreo/openchoreo@v1.3.3:samples/getting-started/` (the resources `all.yaml` applies), one object per
file, rendered verbatim by `templates/upstream-defaults.yaml` (no Helm templating inside these files).

| Here | Upstream | Change |
|---|---|---|
| `cluster-component-types/{scheduled-task,service,webapp,worker}.yaml` | `component-types/*.yaml` | see below |
| `cluster-traits/{health-probes,hpa,pvc}.yaml` | `component-traits/{health-probes,hpa,pvc}-trait.yaml` | none |
| `cluster-project-types/default.yaml` | `cluster-project-types/default.yaml` | none |

Component types: `spec.allowedWorkflows` removed (no workflow plane in v1, so no ClusterWorkflows exist) and
`observability-alert-rule` / `vertical-pod-autoscaler` removed from `spec.allowedTraits` (need the observability plane /
the VPA CRDs on data planes; those traits are not installed). Reproduce:

```bash
T='del(.spec.allowedWorkflows) | (select(.spec.allowedTraits) | .spec.allowedTraits) |=
   map(select(.name != "observability-alert-rule" and .name != "vertical-pod-autoscaler"))'
yq "$T" samples/getting-started/component-types/service.yaml > files/cluster-component-types/service.yaml
```

Not taken: `ClusterResourceType`s (postgres/valkey/nats; need operators on data planes), `ClusterWorkflow`s and
workflow templates (workflow plane), `observability-alert-rule` (observability plane), the sample `Project default` and
its `ProjectReleaseBinding`s (projects come from tenants), `Environment`s (charts/cluster renders them per cluster),
`DeploymentPipeline` (templates/deployment-pipeline.yaml, from values).
