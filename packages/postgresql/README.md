# postgresql: Crossplane Configuration package

The platform's PostgreSQL API (`platform.koorikla.io/v1alpha1 PostgreSQL`, namespaced XR) as one versioned, signed
OCI package: the XRD and one Composition `postgresql`. Every cluster installs the same package; the cluster's facts
(which backend, region, network ids) come from the EnvironmentConfig `platform-postgresql` that `addons/crossplane`
renders. Developer contract (schema, `<name>-app` Secret, status) and operator view: `docs/data-services.md`.

## Layout

| Path | What |
|---|---|
| `crossplane.yaml` | `meta.pkg.crossplane.io/v1 Configuration`, Crossplane `>=v2.4.0`, `dependsOn` Functions + Providers (schemas for validation; the cluster skips resolution, see below) |
| `apis/postgresql/definition.yaml` | the XRD; `defaultCompositionRef: postgresql` |
| `apis/postgresql/composition.yaml` | pipeline: `function-environment-configs` (loads `platform-postgresql`) → `function-go-templating` (one `{{ define }}` per backend: `cnpg`, `aws-rds`, `gcp-cloudsql`, `azure-flexible`, dispatched on `$facts.backend`; unknown backend = fatal result) → `function-auto-ready` |
| `examples/` | sample XRs, bundled into the package |
| `tests/render/` | `functions.yaml` (pinned like the addon), `environment/<backend>.yaml` (sample EnvironmentConfigs), `extra-resources/<example>` (the EnvironmentConfig each example renders with), `observed/`, `expected/` |

## Why the cluster does not resolve dependencies

`addons/crossplane` installs the Configuration with `skipDependencyResolution: true` and declares every Function and
Provider itself, pinned by multi-arch digest, with the PSS-restricted `DeploymentRuntimeConfig`s that
`crossplane-system` needs. The resolver would install them by semver tag and without those runtime configs. Keep the
`dependsOn` floors in step with `addons/crossplane/values.yaml`.

## Release

- PRs touching this directory: `crossplane resource validate` + `crossplane composition render` of each example
  against `tests/render/expected/` (`.github/workflows/package-postgresql.yaml` →
  `app-crossplane-configuration.yaml`).
- `main` and `postgresql-v*` tags: `crossplane xpkg build`, push to `ghcr.io/koorikla/platform/postgresql`, cosign
  keyless signature + SLSA provenance. release-please versions the package as its own component (`postgresql`).
- Promotion: bump `packages.configuration` (tag@digest) in `addons/crossplane/values.yaml` (or a per-environment
  pin under `installations/<inst>/addons/crossplane/`). Renovate proposes the bump.

## Render locally

```bash
cd packages/postgresql
crossplane composition render examples/xr-minimal.yaml apis/postgresql/composition.yaml tests/render/functions.yaml \
  --xrd apis/postgresql/definition.yaml --extra-resources tests/render/environment/cnpg.yaml
# CI check, from the repo root (UPDATE_EXPECTED=true accepts new output into tests/render/expected/):
PACKAGE_ROOT=packages/postgresql bash ci/scripts/crossplane/validate-render.sh
```

`hack/tests/test_crossplane_render.sh` renders all four backends with the EnvironmentConfigs `addons/crossplane`
produces and checks the contract (HA, backup, deletion, Aurora, Secret shape).
