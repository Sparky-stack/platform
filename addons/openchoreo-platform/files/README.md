# OpenChoreo 1.3.3 platform defaults

Rendered as they are by `templates/upstream-defaults.yaml`. These files contain no Helm templating. The template's only
edit is the one installation toggle: with `secrets.tenantStores.enabled`, component ExternalSecrets use the cell's
SecretStore `tenantStoreName` (only installations/local sets it). A guard fails the render when `allowedWorkflows`
stops matching `buildWorkflows.stacks`.

| Here | Derived from `openchoreo/openchoreo@v1.3.3:samples/getting-started/` | Owner |
|---|---|---|
| `cluster-component-types/{scheduled-task,service,webapp,worker}.yaml` | `component-types/*.yaml` | **platform** (changes below) |
| `cluster-traits/{health-probes,hpa,observability-alert-rule,pvc}.yaml` | `component-traits/{health-probes,hpa,alert-rule,pvc}-trait.yaml` | upstream copy, unchanged |
| `cluster-project-types/default.yaml` | `cluster-project-types/default.yaml` | upstream copy, unchanged |

## Component types: platform changes

OpenChoreo expects platform engineers to own their ClusterComponentTypes, and upstream's samples are where they start.
So the four files are platform-owned. The file in Git is the object applied. Each change is marked `# Platform:` in
the file:

| Change | Types | Why |
|---|---|---|
| `allowedWorkflows`: the platform's build ClusterWorkflows `go`, `nextjs`, `elixir`, `ruby`, `dockerfile` (== `buildWorkflows.stacks`, guarded) instead of upstream's buildpacks/podman ones | all | upstream's ClusterWorkflows are not installed ([build plane](../../../docs/build-plane.md)) |
| `vertical-pod-autoscaler` removed from `allowedTraits` | service, webapp, worker | that trait is not installed (it needs the VPA CRDs on data planes) |
| `allowedTraits` += `keda-scaler`, `metrics` | service, webapp, worker | platform traits below |
| `traits` += embedded `resilience`, `environmentConfigs` += `resilience.*` knobs | service, webapp, worker | developers attach nothing ([docs/openchoreo.md "Resilience defaults"](../../../docs/openchoreo.md#resilience-defaults)) |
| `deployment` resource annotated `secret.reloader.stakater.com/auto: "true"` | service, webapp, worker | addon reloader rolls the pods when a Secret they reference rotates (docs/runbooks/certificates-and-secrets.md section 7) |

Upgrading OpenChoreo: apply upstream's sample diff old -> new to each platform file (yq-normalised, the files' style).
Hunks that touch a `# Platform:` block are rejected: resolve them by hand.

```bash
old=v1.3.3 new=v1.4.0 f=service   # repeat for webapp, worker, scheduled-task
u=https://raw.githubusercontent.com/openchoreo/openchoreo p=samples/getting-started/component-types/$f.yaml
diff -u <(curl -sfL $u/$old/$p | yq .) <(curl -sfL $u/$new/$p | yq .) | patch files/cluster-component-types/$f.yaml
```

Then bump the version in the file headers and in this README, and run `helm unittest addons/openchoreo-platform` and
`task docs:reference`. The traits and the project type are plain copies: replace them with the new upstream file.

Not taken: `ClusterResourceType`s (postgres/valkey/nats: plain StatefulSets; the platform's `postgresql` type below
renders the Crossplane XR instead), upstream `ClusterWorkflow`s and
workflow templates (replaced by templates/build-workflows.yaml + addon openchoreo-workflow-plane: rootless BuildKit,
ci/scripts, GitOps hand-off instead of writing Workloads through the API), `vertical-pod-autoscaler` (not installed), the sample `Project default` and
its `ProjectReleaseBinding`s (projects come from tenants), `Environment`s (charts/cluster renders them per cluster),
`DeploymentPipeline` (templates/deployment-pipeline.yaml, from values).

## Platform types (`platform/`)

Not upstream. `templates/platform-types.yaml` renders them; every type except `resilience` has a values switch:

| File | Switch | What it is |
|---|---|---|
| `cluster-traits/keda-scaler.yaml` | `dataServices.enabled` | KEDA ScaledObject trait ([data services](../../../docs/data-services.md)) |
| `cluster-resource-types/{postgresql,mysql}.yaml` | `dataServices.enabled` | the Crossplane platform APIs as OpenChoreo Resources |
| `cluster-traits/resilience.yaml` | always (the component types embed it) | spread, PDB, graceful shutdown, priority ([docs/openchoreo.md "Resilience defaults"](../../../docs/openchoreo.md#resilience-defaults)) |
| `cluster-traits/metrics.yaml` | `appMetrics.enabled` | opt-in PodMonitor ([docs/openchoreo.md "Application metrics"](../../../docs/openchoreo.md#application-metrics)) |

The component types always allow `keda-scaler` and `metrics`. With a switch off, that entry names no ClusterTrait, so
no Component can attach it.

The data-service types carry `platform.koorikla.io/requires-addons`: the addons a data plane must announce
(ClusterDataPlane annotations from the fleet file; hack/tests/test_openchoreo_types.sh).
