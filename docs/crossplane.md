# Crossplane: platform APIs as Configuration packages

Crossplane v2 runs on each workload cluster that opts in (`addons: { crossplane: true }`, addon
[`addons/crossplane`](../addons/crossplane/README.md)); the XR lives next to the app, uses that cluster's workload
identity and needs no cross-cluster Secret delivery (owner decision in #91). Platform APIs (XRD + Composition) ship as
signed **Configuration packages** built from `packages/<name>/`; per-cluster facts reach them through an
**EnvironmentConfig**. PostgreSQL (`packages/postgresql`, [data-services.md](data-services.md#postgresql-as-a-service))
is the first; APIs that are not data services follow the same pattern.

| Piece | Where | Owns |
|---|---|---|
| Crossplane core, RBAC manager, namespace (PSS `restricted`), PodMonitor | `addons/crossplane` (upstream chart) | the control loop |
| Functions + Providers, pinned `tag@sha256`, `DeploymentRuntimeConfig`s | `addons/crossplane/templates/packages.yaml` | everything that runs as a package pod |
| `Configuration` per API, pinned `tag@sha256`, `skipDependencyResolution: true` | `addons/crossplane/templates/configuration.yaml` | which API version a cluster runs |
| `EnvironmentConfig` per API (cluster facts) | `addons/crossplane/templates/environment-config.yaml` | backend, region, network ids, backup target |
| XRD + Composition(s), examples, render tests | `packages/<name>/` (Crossplane Project) | the API itself, versioned on its own (`<name>-vX.Y.Z`) |
| `ManagedResourceActivationPolicy`, `ClusterProviderConfig`, Kyverno policies | `addons/crossplane` | CRD footprint, workload identity, admission |

## Cluster facts: EnvironmentConfig

A package is one immutable artifact for every cluster, so nothing cluster-specific lives in it. The addon renders
`EnvironmentConfig platform-<api>` from values (`installations/<inst>/addons/crossplane/{values,cluster-<name>}.yaml`);
a missing required fact fails the Helm render, not the cluster. The Composition's first step,
`function-environment-configs`, loads it by name (required) into the pipeline context; `function-go-templating` reads
it as `$facts` (`index .context "apiextensions.crossplane.io/environment"`). Developers never see or set facts.

PostgreSQL facts (`postgresql.*` values -> `EnvironmentConfig platform-postgresql`): `backend` (from
`postgresql.backendByProvider[cluster.provider]` or `postgresql.backend`), `cluster`, `environment`, and per backend
`postgresql.aws` (`vpcId`, two or more private `subnetIds`, `nodeSecurityGroupId`), `postgresql.gcp` (`project`,
`privateNetwork` with private services access, optional `allocatedIpRange`), `postgresql.azure` (`tenantID`,
`resourceGroupName`, `delegatedSubnetId`, `privateDnsZoneId`), `postgresql.cnpg` (image catalog, PodMonitor, backup
object store). Example: `installations/aws-example/addons/crossplane/values.yaml`. Identity values
(`postgresql.<cloud>.identity`) configure the provider ServiceAccounts, not the EnvironmentConfig.

## One dispatching Composition per API

The XRD's `defaultCompositionRef` names one Composition, the same on every cluster. When an API has several backends
(PostgreSQL: cnpg, aws-rds, gcp-cloudsql, azure-flexible) the go-template holds one `{{ define }}` per backend and
dispatches on `$facts.backend`; an unknown or missing backend is a fatal result with a clear message. Only that
backend's resources are rendered, so the cluster only needs that backend's providers.

## Dependencies stay pinned by the addon

The Configuration is installed with `skipDependencyResolution: true`. The resolver would install Functions and
Providers by semver tag with Crossplane's default runtime, which lacks the seccomp profile and capability drop that
PSS `restricted` requires in `crossplane-system`, and floating tags break digest pinning. So the addon declares each
Function and each Provider family member itself, pinned by multi-arch index digest, under DeploymentRuntimeConfig
`restricted` / `provider-<cloud>` (seccomp `RuntimeDefault`, drop `ALL`, non-root, read-only root filesystem). The
package's `crossplane-project.yaml` lists the same dependencies (schemas for validation, version floors); keep the
floors and the addon pins in step. VERIFY: whether a Crossplane 2.4 `ImageConfig` can attach a runtime config to
resolver-installed packages (then resolution could be turned on; follow-up issue, not done).

A `ManagedResourceActivationPolicy` activates only the managed resources the Composition composes
(`provider.defaultActivations` is empty), so each provider installs a handful of CRDs. Footprint (requests): core 50m /
128Mi, RBAC manager 10m / 64Mi, each Function 10m / 64Mi, each provider 50m / 256Mi.

## Build, sign, verify, promote

- `packages/<name>/` is a Crossplane Project. `.github/workflows/package-<name>.yaml` calls
  `app-crossplane-configuration.yaml` with `package_root: packages/<name>`: PRs run `crossplane resource validate`
  and `crossplane composition render` of every example against `tests/render/expected/`; `main` and `<name>-v*`
  tags run `crossplane project build` + `crossplane project push` to `ghcr.io/koorikla/platform/<name>` (tags: short
  SHA, `main`, `vX.Y.Z` from the component tag), then cosign keyless signing and SLSA provenance. release-please
  versions each package as its own component (`release-please-config.json`).
- Signature verification: `ImageConfig platform-packages` (cosign keyless, issuer GitHub Actions, subject = the
  reusable workflow `app-crossplane-configuration.yaml` at `refs/heads/main` or a `postgresql-v*` tag) for every
  package under `ghcr.io/koorikla/platform/`. Alpha in Crossplane 2.4: core runs with
  `--enable-signature-verification` (`crossplane.args`). Values: `packages.signatureVerification` (`enabled: false`
  turns it off). The subject alone does not pin the calling repository (any repo can call a public reusable
  workflow); the push target `ghcr.io/koorikla/platform/*` is writable only by this repo, which closes that gap.
- Promotion: bump `packages.configuration` (`tag@sha256`) in `addons/crossplane/values.yaml`; per-environment pins in
  `installations/<inst>/addons/crossplane/env-<env>.yaml` gate dev -> prod (the Argo CD gate is #57). Renovate proposes
  digest bumps (`renovate.json`, ghcr.io/koorikla/platform packages).

## Developer loop (Crossplane CLI 2.4 Project tooling, beta)

The CLI is pinned in `mise.toml` (`mise exec -- crossplane ...`). `_output/`, `schemas/`, `.cache/` are gitignored.

```bash
crossplane project init <name> --directory packages/<name>         # scaffold: crossplane-project.yaml, apis/, examples/, ...
cd packages/<name>
crossplane dependency add 'xpkg.crossplane.io/crossplane-contrib/function-go-templating:>=v0.13.2'  # + schemas
crossplane composition render examples/<xr>.yaml apis/<api>/composition.yaml tests/render/functions.yaml \
  --xrd apis/<api>/definition.yaml --extra-resources tests/render/environment/<backend>.yaml
crossplane project build                                            # _output/<name>.xpkg
crossplane project run                                              # local KIND dev control plane (project stop)
PACKAGE_ROOT=packages/<name> bash ../../ci/scripts/crossplane/validate-render.sh   # what CI runs; UPDATE_EXPECTED=true
```

`project run` resolves dependencies and has no EnvironmentConfig: apply `tests/render/environment/<backend>.yaml`
before an example (VERIFY: not exercised in CI).

## Adding a new API

1. `crossplane project init` under `packages/<name>/`, write `apis/<api>/definition.yaml` (namespaced XRD,
   `apiextensions.crossplane.io/v2`, no claims) and one Composition, add the Functions / Providers with
   `crossplane dependency add`, examples and `tests/render/` (functions pinned like the addon, an EnvironmentConfig per
   backend under `extra-resources/<example>`, `observed/`, `expected/`).
2. Copy `.github/workflows/package-postgresql.yaml`, add the release-please component, merge; record the pushed
   digest (`crane digest ghcr.io/koorikla/platform/<name>:<sha>`).
3. In `addons/crossplane`: the Configuration and EnvironmentConfig (facts with `required`), the new Functions /
   Providers pinned by digest, MRAP entries, aggregated RBAC for composed plain kinds, Kyverno rules that keep tenants on
   the XR. Tests: `hack/tests/test_crossplane_render.sh`, `addons/crossplane/tests`.
4. A developer-facing page for the API (like [data-services.md](data-services.md#postgresql-as-a-service)) and, for
   OpenChoreo, a `ClusterResourceType`.

## Tests (offline)

`hack/tests/test_crossplane_render.sh`: the ApplicationSet render for dev1 has no XRD / Composition, one Configuration
pinned by digest with `skipDependencyResolution`, `EnvironmentConfig platform-postgresql` with backend `cnpg` and the
three Functions; every backend's addon render passes kubeconform and pins every package; a missing fact fails the
render. `crossplane render` (needs a Linux Docker engine, skipped otherwise) of `packages/postgresql`'s Composition with
each backend's EnvironmentConfig checks composed resources (kubeconform), HA / backup / deletion / Aurora mapping, the
identical Secret shape, no password in composed objects, and that an unknown backend is fatal. Renders share one Docker
network and one container per Function per run; at most `XP_RENDER_JOBS` (default 4) at once. Chart:
`addons/crossplane/tests`; admission: `hack/tests/test_kyverno_policies.sh`.

## Upgrading from the Helm-templated API

Before the package, the XRD and the Composition `postgresql-<backend>` were addon templates. The XRD name, group,
version and schema are unchanged; the Composition is now `postgresql`. In one Argo CD sync the chart stops rendering
the XRD and old Composition and installs the Configuration (wave 1), whose package manager takes over the XRD (VERIFY:
adoption of an identical existing XRD). Existing XRs keep `spec.crossplane.compositionRef.name: postgresql-<backend>`;
repoint each once (nothing is in production yet, #107):

```bash
kubectl get postgresql.platform.koorikla.io -A -o name | while read -r xr; do
  kubectl patch "$xr" --type merge -p '{"spec":{"crossplane":{"compositionRef":{"name":"postgresql"}}}}'; done
```

If Crossplane refuses to adopt the XRD, delete only the Helm-owned XRD object with `--cascade=orphan` so no XR or
composed resource is deleted. Never delete the XRD with cascade on a cluster that has XRs.
