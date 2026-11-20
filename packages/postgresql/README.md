# postgresql: Crossplane Configuration package

The platform's PostgreSQL API (`platform.koorikla.io/v1alpha1 PostgreSQL`, namespaced XR) as one versioned, signed
OCI package, laid out as a Crossplane Project (`crossplane project init`): the XRD, one Composition `postgresql` and its embedded
function `compose-postgresql` (the templates, one file per composed object, like a Helm chart). Every cluster installs the same package; the cluster's facts
(which backend, region, network ids) come from the EnvironmentConfig `platform-postgresql` that `addons/crossplane`
renders. Developer contract (schema, `<name>-app` Secret, status) and operator view: [docs/data-services.md](../../docs/data-services.md#postgresql-as-a-service); packaging, facts,
pinning, signing and adding APIs: [docs/crossplane.md](../../docs/crossplane.md).

## Layout

| Path | What |
|---|---|
| `crossplane-project.yaml` | `dev.crossplane.io/v1alpha1 Project`: repository `ghcr.io/koorikla/platform/postgresql`, Crossplane `>=v2.4.0`, dependencies = 3 Functions + 5 Providers (the cluster skips resolution, see below) |
| `functions/compose-postgresql/` | the templates (embedded go-templating function, image `ghcr.io/koorikla/platform/postgresql_compose-postgresql`): `00-prelude.yaml.gotmpl` (facts, XR defaults, per-backend derived values, unknown backend = fatal), `90-xr-status.yaml.gotmpl`, and one `<backend>-<object>.yaml.gotmpl` per composed object, e.g. `cnpg-cluster`, `aws-rds-kms-key`, `gcp-cloudsql-connection-secret` |
| `operations/` | empty (project scaffold) |
| `apis/postgresql/definition.yaml` | the XRD; `defaultCompositionRef: postgresql` |
| `apis/postgresql/composition.yaml` | pipeline: `function-environment-configs` (loads `platform-postgresql`) → `compose-postgresql` (functionRef `koorikla-platform-postgresqlcompose-postgresql`; renders only `$facts.backend`'s directory: `cnpg`, `aws-rds`, `gcp-cloudsql`, `azure-flexible`) → `function-auto-ready` |
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
- `main` and `postgresql-v*` tags: `crossplane project build` + `project push` of the Configuration
  `ghcr.io/koorikla/platform/postgresql` and the function `ghcr.io/koorikla/platform/postgresql_compose-postgresql`
  (amd64 + arm64), cosign keyless signature + SLSA provenance of both. release-please versions the package as its own component (`postgresql`).
- Promotion: bump `packages.configuration` and the compose-postgresql Function (`vX.Y.Z@sha256`, the same release tag) in `addons/crossplane/values.yaml` (or a per-environment
  pin under `installations/<inst>/addons/crossplane/`). Renovate proposes the bump.

## Developer loop (Crossplane CLI 2.4 Project tooling, beta; CLI pinned in `mise.toml`)

```bash
cd packages/postgresql
crossplane dependency add 'xpkg.crossplane.io/crossplane-contrib/<pkg>:>=vX.Y.Z'  # schemas into schemas/ (gitignored)
crossplane project build            # _output/postgresql.xpkg (gitignored)
crossplane project run              # local KIND dev control plane with the package installed; project stop removes it
# CI check, from the repo root (UPDATE_EXPECTED=true accepts new output into tests/render/expected/):
PACKAGE_ROOT=packages/postgresql bash ci/scripts/crossplane/validate-render.sh
XP_RENDER_OUT=/tmp/after bash hack/tests/test_crossplane_render.sh   # all backends; diff -r against a run before your change
```

Add a composed object: add `functions/compose-postgresql/<backend>-<object>.yaml.gotmpl` (copy a sibling: backend
guard `{{- if eq $backend "<backend>" }}`, `composition-resource-name` annotation), then run the render tests.
Every file in that directory is a template (no README there).

`project run` installs the package with dependency resolution and without the EnvironmentConfig: create
`tests/render/environment/<backend>.yaml` in it before applying an example (VERIFY: not exercised in CI).

`hack/tests/test_crossplane_render.sh` renders all four backends with the EnvironmentConfigs `addons/crossplane`
produces and checks the contract (HA, backup, deletion, Aurora, Secret shape).
