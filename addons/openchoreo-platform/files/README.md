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

Not taken: `ClusterResourceType`s (postgres/valkey/nats: plain StatefulSets; the platform's `postgresql` type below
renders the Crossplane XR instead), upstream `ClusterWorkflow`s and
workflow templates (replaced by templates/build-workflows.yaml + addon openchoreo-workflow-plane: rootless BuildKit,
ci/scripts, GitOps hand-off instead of writing Workloads through the API), `vertical-pod-autoscaler` (not installed), the sample `Project default` and
its `ProjectReleaseBinding`s (projects come from tenants), `Environment`s (charts/cluster renders them per cluster),
`DeploymentPipeline` (templates/deployment-pipeline.yaml, from values).

## Platform types (`platform/`)

Not upstream: `platform/cluster-traits/keda-scaler.yaml` and `platform/cluster-resource-types/postgresql.yaml`, the
OpenChoreo types of the data-service addons (#70, docs/data-services.md "Consuming them from OpenChoreo"), rendered by
`templates/platform-types.yaml` (`dataServices.enabled`). `templates/upstream-defaults.yaml` adds `keda-scaler` to the
`allowedTraits` of the Deployment-based component types. Their annotation `platform.koorikla.io/requires-addons` names
the addons a data plane must announce (ClusterDataPlane annotations from the fleet file); checked by
hack/tests/test_openchoreo_types.sh.

Not upstream either: `platform/cluster-traits/resilience.yaml` (#251, docs/openchoreo.md "Resilience defaults"),
rendered by `templates/platform-types.yaml` (`resilience.enabled`). `templates/upstream-defaults.yaml` embeds it in
the Deployment-based component types (`spec.traits`, instance `resilience`) and adds the `resilience` object to their
`environmentConfigs`, so developers never attach it. It also annotates their `deployment` resource
`secret.reloader.stakater.com/auto: "true"` (#268): addon reloader rolls the pods when a Secret they reference rotates
(docs/runbooks/certificates-and-secrets.md section 7).

Not upstream either: `platform/cluster-traits/metrics.yaml` (#252, docs/openchoreo.md "Application metrics"), rendered
by `templates/platform-types.yaml` (`appMetrics.enabled`). Opt-in: `templates/upstream-defaults.yaml` adds it to the
`allowedTraits` of the Deployment-based component types. Its PodMonitor comes from default-on addon telemetry
(`platform.koorikla.io/uses-addons`): skipped where a data plane opts out, waited for by the agent's capability gate.
