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

## One Composition per API, templates laid out like a Helm chart

The XRD's `defaultCompositionRef` names one Composition, the same on every cluster: `environment`
(function-environment-configs) -> `compose-<api>` -> `ready` (function-auto-ready). `compose-<api>` is the Project's
embedded function (`crossplane function generate compose-<api> --language go-templating`): function-go-templating with
the templates of `functions/compose-<api>/` baked into its image. One file per composed object, file names say what
they render (the same convention in every package):

```text
packages/postgresql/functions/compose-postgresql/
  00-prelude.yaml.gotmpl            # facts, backend check (unknown = fatal result), XR spec defaults, derived values
  1x-<object>.yaml.gotmpl           # objects every backend composes (none in postgresql; e.g. mysql's connection Secret)
  90-xr-status.yaml.gotmpl          # the XR status (an object with the XR's apiVersion/kind)
  <backend>-<object>.yaml.gotmpl    # cnpg-cluster, aws-rds-kms-key, gcp-cloudsql-connection-secret, ...
```

The files render in name order as ONE template, so the prelude's variables reach every file; it runs on every
backend, so it never `fail`s outside the backend check. An object file starts with its guard
(`{{- if eq $backend "cnpg" }}`) and sets `gotemplating.fn.crossplane.io/composition-resource-name`; only
`$facts.backend`'s files render, so a cluster needs only that backend's providers. Add an object: add
`<backend>-<object>.yaml.gotmpl`, then run the render tests (below). Every file in the directory is a template: no
README or other files there.

The Composition references the function as `koorikla-platform-postgresqlcompose-postgresql`, the name Crossplane derives
from its package `ghcr.io/koorikla/platform/postgresql_compose-postgresql` (`crossplane project build --repository`
decides it); addons/crossplane installs the Function under that name. Upstream Functions keep the names the addon
installs them under (`function-environment-configs`, `function-auto-ready`), not the resolver's
`crossplane-contrib-function-*`: the cluster skips dependency resolution. CLI 2.4.1 builds go-templating functions `FROM
function-go-templating:v0.12.0` (not configurable) for amd64 + arm64.

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
  SHA, `main`, `vX.Y.Z` from the component tag) plus its embedded function `<name>_compose-<name>` (same tags), then
  cosign keyless signing and SLSA provenance of both. release-please
  versions each package as its own component (`release-please-config.json`).
- Signature verification: OFF for now ([#247](https://github.com/koorikla/platform/issues/247)). Crossplane 2.4's
  alpha cosign verifier only finds legacy `.sig` tags; cosign v3 signs with Sigstore bundles attached as OCI
  referrers, so every package failed with "no signatures found". Packages are still keyless-signed with SLSA
  provenance in CI. The ready-made config stays: `packages.signatureVerification.enabled: true` renders `ImageConfig
  platform-packages` (cosign keyless, issuer GitHub Actions, subject = the reusable workflow
  `app-crossplane-configuration.yaml` at `refs/heads/main` or a `postgresql-v*` tag) for every package under
  `ghcr.io/koorikla/platform/`; it also needs `--enable-signature-verification` in `crossplane.args`. The subject alone does not pin the calling repository (any repo can call a public reusable
  workflow); the push target `ghcr.io/koorikla/platform/*` is writable only by this repo, which closes that gap.
- Promotion: bump `packages.configuration` and its embedded Function `packages.functions.koorikla-platform-postgresqlcompose-postgresql`
  (same tag, both `tag@sha256`; one Renovate group) in `addons/crossplane/values.yaml`; per-environment pins in
  `installations/<inst>/addons/crossplane/env-<env>.yaml` gate dev -> prod (the Argo CD gate is #57). Renovate proposes
  digest bumps (`renovate.json`, ghcr.io/koorikla/platform packages).

## Developer loop (Crossplane CLI 2.4 Project tooling, beta)

The CLI is pinned in `mise.toml` (`mise exec -- crossplane ...`). `_output/`, `schemas/`, `.cache/` are gitignored.

```bash
crossplane project init <name> --directory packages/<name>         # scaffold: crossplane-project.yaml, apis/, examples/, ...
cd packages/<name>
crossplane dependency add 'xpkg.crossplane.io/crossplane-contrib/function-go-templating:>=v0.13.2'  # + schemas
crossplane project build                                            # _output/<name>.xpkg
crossplane project run                                              # local KIND dev control plane (project stop)
PACKAGE_ROOT=packages/<name> bash ../../ci/scripts/crossplane/validate-render.sh   # what CI runs; UPDATE_EXPECTED=true
XP_RENDER_OUT=/tmp/r bash hack/tests/test_crossplane_render.sh     # from the repo root: every backend, renders kept in /tmp/r
```

Both render harnesses build the embedded function from the working tree (validate-render.sh: `crossplane project
build` + `docker load`; the hack test: the same `FROM` + `COPY . /src` with `docker build`). For a refactor of the
templates, render before and after with `XP_RENDER_OUT` and `diff -r` the two directories.

`project run` resolves dependencies and has no EnvironmentConfig: apply `tests/render/environment/<backend>.yaml`
before an example (VERIFY: not exercised in CI).

## APIs and their status

| API | Package | Local backend (operator) | Cloud backends | Status |
|---|---|---|---|---|
| PostgreSQL | [`packages/postgresql`](../packages/postgresql/README.md) | CloudNativePG | RDS / Aurora, Cloud SQL, Azure Flexible | tested locally |
| MySQL | [`packages/mysql`](../packages/mysql/README.md) | MOCO (Vitess evaluated: too heavy per app) | RDS, Cloud SQL, Azure Flexible | layout |
| Valkey | [`packages/valkey`](../packages/valkey/README.md) | valkey-io/valkey-operator | ElastiCache, Memorystore, Azure Cache for Redis | layout |
| Bucket | [`packages/bucket`](../packages/bucket/README.md) | RustFS operator | S3, GCS, Azure Blob | layout |
| KafkaTopic | [`packages/kafka-topic`](../packages/kafka-topic/README.md) | Strimzi | Event Hubs (MSK, Managed Kafka: no upjet kind yet) | layout |

*layout*: package, render tests and an OpenChoreo `ClusterResourceType` (kept in `packages/<api>/openchoreo/`, not
deployed) exist; no cluster installs it. Every package composes through a Crossplane Project **embedded function**
(`functions/compose-<api>/`, one go-template per composed object, `crossplane function generate`). **Object storage and COSI:** the Kubernetes Container Object Storage
Interface (SIG Storage, `BucketClaim` / `BucketAccess`) is the future standard for bucket provisioning but is still
alpha with few drivers (none for RustFS); Crossplane gives one API across RustFS and the three clouds today.

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
Functions (the embedded `koorikla-platform-postgresqlcompose-postgresql` included); every backend's addon render passes kubeconform and pins every package; a missing fact fails the
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
