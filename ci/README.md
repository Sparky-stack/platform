# ci/ - build scripts, toolbox image, app workflow templates

What lives here and who runs it:

| Path | What | Run by |
|---|---|---|
| [`scripts/<stack>/`](scripts), [`scripts/common/`](scripts/common) | build, test, scan, sign, attest scripts (env in, files out) | OpenChoreo ClusterWorkflows ([`addons/openchoreo-workflow-plane`](../addons/openchoreo-workflow-plane)) and the reusable workflows [`.github/workflows/app-*.yaml`](../.github/workflows/) |
| [`toolbox/`](toolbox) | `ghcr.io/koorikla/ci-toolbox` image: the scripts plus trivy, syft, cosign, ... | built by [`ci-toolbox.yaml`](../.github/workflows/ci-toolbox.yaml) |
| [`fixtures/`](fixtures), [`tests/`](tests) | one tiny project per stack, script unit tests | [`ci-selftest.yaml`](../.github/workflows/ci-selftest.yaml) |
| [`templates/`](templates) | caller workflows, Dependabot configs, Dockerfiles | copied into app repos |

Released on the `ci-vX.Y.Z` tag line ([CHANGELOG.md](CHANGELOG.md), [docs/releases.md](../docs/releases.md)).

Portable build, test, scan, sign and attest **scripts** plus a multi-arch **toolbox image**
for everything koorikla ships: Go, Python, Node.js (Express, Fastify, NestJS, Nuxt,
SvelteKit, Remix), Next.js, Rust, Java (Quarkus, Spring Boot), Elixir/Phoenix, Ruby/Rails,
Helm charts, Crossplane configuration packages and Crossplane providers.

- **Primary path: in-cluster.** OpenChoreo workflow-plane ClusterWorkflows run
  `scripts/<stack>/*.sh` and `scripts/common/*.sh` inside
  `ghcr.io/koorikla/ci-toolbox` (see [Running in-cluster](#running-in-cluster-openchoreo-workflow-plane)).
- **Optional path: GitHub Actions.** Thin reusable workflows that only wire inputs to the
  same scripts (plus GitHub-only extras: CodeQL, SARIF upload, GitHub attestations,
  keyless signing). Nothing stack-specific is inlined in YAML.

Both paths produce the same thing: a **multi-arch** (`linux/amd64` + `linux/arm64`) artifact,
Trivy-scanned per platform, with an SPDX SBOM, provenance, a cosign signature and a cosign
vulnerability attestation.

## Toolbox image

`ghcr.io/koorikla/ci-toolbox`, tagged `main`, `<short sha>` and `<full sha>`. Multi-arch, itself
scanned, SBOM'd, attested and cosign-signed by [`ci-toolbox.yaml`](../.github/workflows/ci-toolbox.yaml)
through `app-container.yaml`. Pin it by digest (`addons/openchoreo-workflow-plane/values.yaml`
`images.TOOLBOX_IMAGE`); the `:v1` in that pin is a leftover tag from the archived koorikla/ci repo,
only the digest counts.

Contents ([`toolbox/Dockerfile`](toolbox/Dockerfile), versions pinned, release checksums verified
where upstream publishes them): trivy, syft, cosign, crane, helm, yq, jq, git, crossplane CLI,
bash, curl, make (provider repos generate code with a make target). Scripts live in
`/opt/koorikla-ci/scripts` (`$CI_SCRIPTS`), `common/` is on `PATH`, user is uid 65532, workdir
`/workspace`. `toolbox-smoke` checks every tool.

It deliberately has **no image builder**: in-cluster image builds use BuildKit in their own
step, then hand the pushed digest to the toolbox steps.

## Adopt: one file in your repo

Copy the caller for your stack from [`templates/workflows/`](templates/workflows) to
`.github/workflows/ci.yaml`. It calls
`koorikla/platform/.github/workflows/app-<stack>.yaml@<commit sha> # ci-vX.Y.Z`; use the SHA the
platform trusts (`addons/kyverno-policies/values.yaml` `imageVerification.github.workflowRef`),
otherwise production admission rejects the image. Every workflow input is documented in the
`description:` of its `on.workflow_call.inputs` entry.

Dependabot configs are in [`templates/dependabot/`](templates/dependabot) and Dockerfiles in
[`templates/dockerfiles/`](templates/dockerfiles) (Go distroless cross-compiled, Python on
distroless Python, generic Node.js and Next.js standalone on distroless Node, Rust static musl
on distroless static, Quarkus JVM / Quarkus native / Spring Boot layered jar, Elixir release on
debian-slim, Rails/Ruby slim). The python, node, rust and java callers include the
[Workload bump](#workload-bump-gitops-hand-off) job.

**Permissions matter.** A reusable workflow's jobs can never get more than the calling job
grants; if a nested job asks for more, GitHub fails the whole run at startup
(`startup_failure`, "workflow file issue", no jobs). Grant exactly the set listed in the
header comment of each workflow:

| Workflow | Caller job permissions |
|---|---|
| go, python, node, nextjs, rust, java, ruby, crossplane-provider | `contents: read`, `actions: read`, `packages: write`, `id-token: write`, `attestations: write`, `security-events: write` |
| container, elixir | same without `actions: read` |
| helm-chart, crossplane-configuration | `contents: read`, `packages: write`, `id-token: write`, `attestations: write` |
| workload-bump | `contents: write` (only this job: it pushes the Workload commit) |

`push: true` (default) only pushes on non-`pull_request` events; PRs build (amd64), test
and scan but never push or sign. For a registry other than GHCR pass `registry:` plus the
`registry_username` / `registry_password` secrets (every workflow except workload-bump; optional,
GHCR uses `GITHUB_TOKEN`).

## What gets checked, per stack

| Stack | Lint / static analysis | Tests | Dependency vulns | SAST | Image |
|---|---|---|---|---|---|
| Go | `go vet`, golangci-lint | `go test -race` + coverage | govulncheck (call-graph aware) | CodeQL go | Trivy, SBOM, sign |
| Python | ruff check + `ruff format --check`, mypy (if locked), `uv lock --check` | pytest (+ pytest-cov coverage) | pip-audit on the exported runtime requirements (hashes), Trivy fs on uv.lock | CodeQL python | Trivy, SBOM, sign |
| Node.js | `lint` script, `typecheck` script / `tsc --noEmit` | `test` script, `build` script | `npm audit` / `pnpm audit` / `yarn npm audit` (prod deps, `audit_level`), Trivy fs on the lockfile | CodeQL javascript-typescript | Trivy, SBOM, sign |
| Rust | `cargo fmt --check`, clippy `-D warnings` | cargo-nextest (+ doctests) or `cargo test` | cargo-deny (advisories, bans, licenses with deny.toml, sources), cargo-audit, Trivy fs on Cargo.lock | CodeQL rust | Trivy, SBOM, sign |
| Java (Quarkus, Spring Boot) | compile (`verify` / `build`) | JUnit via Maven/Gradle + JaCoCo line coverage | CycloneDX SBOM of the resolved runtime deps scanned by Trivy (`trivy sbom`) and osv-scanner (CVSS gate) | CodeQL java-kotlin | Trivy, SBOM, sign |
| Next.js | `lint` script (eslint), `typecheck` script / `tsc --noEmit` | `test` script, `next build` | `npm audit` / `pnpm audit` / `yarn npm audit` (prod deps, `audit_level`), Trivy fs on the lockfile | CodeQL javascript-typescript | Trivy, SBOM, sign |
| Elixir | `compile --warnings-as-errors`, `format --check-formatted`, credo `--strict` (if a dependency) | `mix test` (+ Postgres service) | `mix hex.audit` (retired), `mix deps.audit` (mix_audit, if a dependency), Trivy fs on mix.lock | sobelow (if a dependency, i.e. Phoenix). **CodeQL has no Elixir support.** | Trivy, SBOM, sign |
| Ruby / Rails | rubocop (if bundled) | rspec / `bin/rails test` / `rake test` (+ Postgres) | bundler-audit, Trivy fs on Gemfile.lock | brakeman (Rails), CodeQL ruby | Trivy, SBOM, sign |
| Helm | `helm lint --strict` | helm-unittest (`<chart>/tests/`) | - | - | chart signed + provenance |
| Crossplane configuration | `crossplane resource validate` of XRDs/Compositions/function inputs against Crossplane + dependency schemas | `crossplane composition render` per example XR, composed resources validated, diff vs expected | - | - | xpkg signed + provenance |
| Crossplane provider | `generate_command` (default: the `generate` make target) must leave a clean tree, `go vet`, golangci-lint | `go test -race` | govulncheck | CodeQL go (opt-in: slow on upjet) | controller image: Trivy, SBOM, sign; xpkg signed |

Limits: images are scanned with Trivy for OS + language packages; `trivy_ignore_unfixed: true`
by default; the job fails on `trivy_severity` (default `CRITICAL`). The SBOM attached to a
multi-arch image is generated from the `linux/amd64` variant (Trivy scans every platform).
Images are pushed before they are scanned (multi-arch images cannot be loaded into the
runner's daemon); a failing scan leaves an **unsigned** image that admission control rejects.

### Accepting a risk

Pass `trivy_ignore_file: path/to/.trivyignore.yaml` (works for image and lockfile scans).
Use the YAML form with a `statement` and `expired_at` so exceptions expire, e.g.
[`fixtures/ruby/.trivyignore.yaml`](fixtures/ruby/.trivyignore.yaml).

## Multi-arch

`container.yaml` builds `platforms` (default `linux/amd64,linux/arm64`):

- `multiarch_strategy: native` (default): one job per platform on `ubuntu-24.04` and
  `ubuntu-24.04-arm`, each pushed by digest, then merged with `docker buildx imagetools create`
  into one OCI index carrying all tags. Fast and no emulation. arm64 hosted runners are free
  for public repos; for private repos check your plan, or use `qemu`.
- `multiarch_strategy: qemu`: one amd64 runner, buildx + QEMU.

The index **and** every platform manifest are cosign-signed (`--recursive`); attestations are
attached to the index digest (what pods reference). Dockerfiles for compiled languages should
cross-compile with `FROM --platform=$BUILDPLATFORM` (see the Go template); Node, Ruby and
Elixir images build on the target platform because native modules / ERTS are arch-specific.
Python and Rust build on the target platform too (arch-specific wheels; native musl build on each
runner, no cross toolchain). Java JVM images (Quarkus, Spring Boot) build the jar once on
`$BUILDPLATFORM` and copy it into each platform's distroless Java runtime; the Quarkus native
image (Mandrel cannot cross-compile) builds on each arch's native runner.

## Signing and attestation model

GitHub-built artifacts are signed **keyless** (Sigstore Fulcio + Rekor) with the job's OIDC
token. Because signing happens inside a *reusable* workflow, the certificate identity is the
reusable workflow, and the calling repository is recorded in certificate extensions. Every
stack workflow (go, python, node, rust, java, nextjs, elixir, ruby) signs through
`container.yaml`, so the identity is the same for all of them:

| Certificate field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject (SAN) | `https://github.com/koorikla/platform/.github/workflows/app-{container,helm-chart,crossplane-configuration,crossplane-provider}.yaml@<sha>` |
| `githubWorkflowRepository` (1.3.6.1.4.1.57264.1.5) | caller, e.g. `koorikla/hello-world` |
| `githubWorkflowRef` (1.3.6.1.4.1.57264.1.6) | caller ref, e.g. `refs/heads/main` |
| Build Config URI | caller workflow, e.g. `https://github.com/koorikla/hello-world/.github/workflows/ci.yaml@refs/heads/main` |

So the identity `https://github.com/koorikla/<repo>/.github/workflows/<file>@refs/heads/main`
is the *caller*; it is carried in the extensions, not the SAN. **Always pin the caller
repository/ref as well as the subject:** `koorikla/platform` is public, so any repository can call
its workflows and obtain a certificate with the same SAN.

```sh
cosign verify ghcr.io/koorikla/hello-world:<sha> \
  --certificate-identity https://github.com/koorikla/platform/.github/workflows/app-container.yaml@<sha> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository koorikla/hello-world \
  --certificate-github-workflow-ref refs/heads/main
# GitHub attestations (SLSA provenance + SPDX SBOM):
gh attestation verify oci://ghcr.io/koorikla/hello-world:<sha> --owner koorikla
```

Attached to every pushed image (index digest):

| Attestation | Producer | Predicate type |
|---|---|---|
| Signature | cosign (keyless) | - |
| SLSA build provenance | `actions/attest-build-provenance` (OCI referrer) | `https://slsa.dev/provenance/v1` |
| SBOM | `actions/attest` with `sbom-path` (OCI referrer) | `https://spdx.dev/Document/v2.3` |
| Vulnerability scan | `cosign attest --type vuln` (Trivy cosign-vuln) | `https://cosign.sigstore.dev/attestation/vuln/v1` |

In-cluster builds use the same scripts but sign with the platform key
(`COSIGN_KEY=k8s://<ns>/<secret>` or a KMS URI, see `scripts/common/sign-image.sh`); the
admission policy accepts **either** attestor.

The enforcing policy is the `ImageValidatingPolicy` rendered by
[`addons/kyverno-policies`](../addons/kyverno-policies): it pins the SAN to the trusted
`app-container.yaml@<sha>` (`imageVerification.github.workflowRef`) plus the caller
repository/ref, and accepts the platform key for in-cluster builds. cosign v3 stores
signatures/attestations in the Sigstore bundle format (OCI referrers).

## Workload bump (GitOps hand-off)

[`workload-bump.yaml`](../.github/workflows/app-workload-bump.yaml) points the app's OpenChoreo
Workload (`deploy/openchoreo/workload.yaml` by default) at the image the stack workflow just
pushed and commits it back (`chore(deploy): bump <name> image to <sha> [skip ci]`):

```yaml
  bump:
    needs: python
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    uses: koorikla/platform/.github/workflows/app-workload-bump.yaml@<sha> # ci-vX.Y.Z
    permissions:
      contents: write
    with:
      image: ${{ needs.python.outputs.image }}     # <repo>:<short sha>
      digest: ${{ needs.python.outputs.digest }}   # index digest; '' (PRs) skips the bump
```

- `spec.container.image` becomes `<repo>:<short sha>@sha256:<index digest>` (production admission
  only accepts digest references; the tag keeps it readable), `spec.source.commit` the built commit.
  The edit is line-based (`scripts/common/workload-bump.sh`, bash + awk): comments survive.
- It is a separate reusable workflow so only that job holds `contents: write`; the stack
  workflows keep their read-only permission set (a nested job asking for more than the caller
  grants fails the whole run at startup).
- Push-triggered callers should `paths-ignore: ['deploy/**']`; branch protection must let the
  job token push. `validate_command` runs a schema check before committing; `push: false` is a
  dry run (used by the selftest).
- In-cluster builds use the same two scripts (`workload-bump.sh`, `git-push-change.sh`).

## Registry: GHCR now, Harbor later

Everything pushes to `ghcr.io/<owner>` by default. Harbor on the management cluster currently
**proxy-caches ghcr.io**, so clusters pull through Harbor while signatures/attestations stay
verifiable (same digests). To push to Harbor later set `registry: harbor.<domain>/<project>`
and pass a robot account as `registry_username` / `registry_password`.

GHCR packages are private when first created: make them public (package settings) or give the
pulling clusters credentials.

## Running in-cluster (OpenChoreo workflow plane)

Each step is "run a script in the toolbox with these env vars, read files from
`$CI_OUT_DIR`". Typical pipeline for a service image:

| Step | Image | Command | Key env in | Files out (`$CI_OUT_DIR`) |
|---|---|---|---|---|
| checks | toolbox (+ language toolchain image, see below) | `$CI_SCRIPTS/<stack>/check.sh` | `WORKDIR`, stack flags | coverage etc. |
| deps scan | toolbox | `scan-fs.sh` | `SCAN_PATH`, `FAIL_SEVERITIES`, `IGNORE_FILE` | `trivy-fs.json`, `trivy-fs.sarif` |
| coordinates | toolbox | `image-meta.sh` | `OWNER`, `REPO_NAME`, `SHA`, `REGISTRY`, `IMAGE_NAME` | `repo`, `image`, `short_sha`, … |
| build + push | BuildKit | `buildctl build … --opt platform=linux/amd64,linux/arm64 --output type=image,name=<repo>:<tag>,push=true` | | image index digest |
| scan | toolbox | `scan-image.sh` | `IMAGE_REF=<repo>@sha256:…`, `IMAGE_SRC=remote`, `PLATFORMS` | `trivy-*.json`, `trivy.sarif`, `trivy-vuln.json` |
| SBOM | toolbox | `sbom.sh` | `IMAGE_REF`, `SOURCE=registry` | `sbom.spdx.json` |
| sign + attest | toolbox | `sign-image.sh` | `IMAGE_DIGEST_REF`, `VULN_PREDICATE`, `COSIGN_KEY=k8s://<ns>/<secret>` | `signed_ref` |

Add `cosign attest --key "$COSIGN_KEY" --type spdxjson --predicate sbom.spdx.json` (and a
SLSA predicate from the workflow engine, if it emits one) for SBOM/provenance attestations;
GitHub's `attest-*` actions have no in-cluster equivalent.

Stack checks need a language toolchain the toolbox does not carry: run `check.sh` in the
official toolchain image (`golang`, `ghcr.io/astral-sh/uv:python3.13-trixie`, `node`, `rust`,
`eclipse-temurin:25-jdk`, `elixir`, `ruby`, `alpine/helm`) with the scripts
mounted or copied from the toolbox (`/opt/koorikla-ci/scripts`), exactly like a developer runs
them on a laptop. Crossplane steps (`crossplane/*.sh`) run in the toolbox itself;
`validate-render.sh` needs a Docker-compatible runtime for `crossplane composition render`
(functions run as containers) — provide a DinD sidecar or run render tests only on GitHub.


The real templates are rendered by
[`addons/openchoreo-workflow-plane`](../addons/openchoreo-workflow-plane/files/cluster-workflow-templates)
(`koorikla-build.yaml`, `koorikla-helm-chart.yaml`) and wired to OpenChoreo by
[`addons/openchoreo-platform`](../addons/openchoreo-platform/templates).

## Script contract (both runners)

Workflows are thin: each step calls `scripts/<stack>/*.sh` or `scripts/common/*.sh`, fetched from
`koorikla/platform` (`ci/scripts`) at **the same commit as the running reusable workflow** (`job.workflow_sha`).

- **Env in, files out.** Inputs are environment variables documented in each script header.
  File outputs go to `$CI_OUT_DIR` (default `./.ci-out`); every scalar output is also written to
  `$CI_OUT_DIR/<key>` and, under GitHub Actions, to `$GITHUB_OUTPUT`.
- **Portable:** bash 3.2 (macOS `/bin/bash`) and BSD/GNU userland; shellcheck-clean
  (`.shellcheckrc`, enforced by the selftest). No `sed -i`, `readlink -f`, `mapfile`,
  associative arrays or `${var,,}`.
- **Tools:** whatever the script `require_cmd`s; all of them ship in the toolbox.

| Script | Purpose |
|---|---|
| `common/image-meta.sh` | image coordinates (repo, short sha, push decision) |
| `common/build-matrix.sh` | per-arch runner matrix |
| `common/merge-manifest.sh` | per-arch digests → tagged OCI index |
| `common/scan-image.sh` | Trivy per platform → JSON, SARIF, cosign-vuln predicate, gate |
| `common/scan-fs.sh` | Trivy fs on lockfiles → JSON, SARIF, gate |
| `common/sbom.sh` | syft SPDX JSON |
| `common/sign-image.sh` | cosign sign (+ vuln attest), keyless or `COSIGN_KEY` |
| `common/scan-fs.sh` with `SBOM_FILE` | `trivy sbom` on a build-generated CycloneDX SBOM (Java) |
| `common/osv-scan.sh` | osv-scanner (pinned, checksum-verified install) on lockfiles / SBOM, CVSS gate |
| `common/workload-bump.sh` | OpenChoreo Workload image `<repo>:<tag>@sha256:…` + source commit |
| `common/git-push-change.sh` | commit paths if changed, push with rebase/retry |
| `common/generate-check.sh` | code generation must leave a clean tree |
| `go/check.sh`, `python/check.sh`, `node/{detect,setup-pm,check}.sh`, `nextjs/{detect,check}.sh`, `rust/check.sh`, `java/{detect,check}.sh`, `elixir/check.sh`, `ruby/check.sh`, `helm/{check,package-push,registry-meta}.sh` | stack checks |
| `crossplane/{install-cli,package-name,validate-render,xpkg-build,xpkg-push,provider-xpkg}.sh` | Crossplane CLI, validation/render tests, packaging |


## Versioning

`ci/` and the `app-*` workflows are released by release-please on the `ci-vX.Y.Z` tag line
([docs/releases.md](../docs/releases.md)). Callers pin the **commit SHA** with the tag as a comment
(`@<sha> # ci-vX.Y.Z`); Renovate moves the app repos and the Kyverno `workflowRef` together.
Changing the trusted SHA is a pin move: see the `app-container.yaml` signer identity above.

Reusable workflows call siblings with `uses: $/.github/workflows/…` and fetch `ci/scripts` at
`job.workflow_sha`, so a caller pinned to a SHA gets one consistent set of workflows and scripts.
Actions in the workflows are pinned by commit SHA with the release as a comment.

## Self-tests

[`ci-selftest.yaml`](../.github/workflows/ci-selftest.yaml) runs every workflow against
[`fixtures/`](fixtures) on PRs, `workflow_dispatch`, and pushes to `main` touching
`app-*.yaml`, `ci-selftest.yaml`, `ci/fixtures/**`, `ci/scripts/**` or `ci/tests/**`: actionlint + shellcheck, a bash 3.2
syntax check of every script plus script unit tests ([`tests/scripts/`](tests/scripts)), Go
module, uv project (WSGI on waitress), pnpm Fastify/TypeScript API, dependency-free Rust HTTP
service (cargo-deny with deny.toml), Quarkus REST service (Maven; JVM and native images), Spring
Boot service (Gradle, Kotlin DSL), Next.js app, mix project (credo + mix_audit, no Phoenix so
sobelow skips), Rack app (rspec, rubocop, bundler-audit), a Workload bump dry run, Helm chart (helm-unittest), Crossplane configuration (XRD + Composition with
function-go-templating + example XR + expected render), and a tiny native provider skeleton
(generator, controller image, per-arch xpkg). Pushed artifacts:

| Package | Kind |
|---|---|
| `ghcr.io/koorikla/ci-selftest-go` | image |
| `ghcr.io/koorikla/ci-selftest-python` | image |
| `ghcr.io/koorikla/ci-selftest-node` | image |
| `ghcr.io/koorikla/ci-selftest-rust` | image |
| `ghcr.io/koorikla/ci-selftest-java-quarkus` | image (JVM) |
| `ghcr.io/koorikla/ci-selftest-java-quarkus-native` | image (native) |
| `ghcr.io/koorikla/ci-selftest-java-spring` | image |
| `ghcr.io/koorikla/ci-selftest-nextjs` | image |
| `ghcr.io/koorikla/ci-selftest-elixir` | image |
| `ghcr.io/koorikla/ci-selftest-ruby` | image |
| `ghcr.io/koorikla/ci-selftest-helm` | Helm chart (OCI) |
| `ghcr.io/koorikla/ci-selftest-crossplane-configuration` | xpkg |
| `ghcr.io/koorikla/ci-selftest-crossplane-provider` | xpkg (multi-arch) |
| `ghcr.io/koorikla/ci-selftest-crossplane-provider-controller` | image |
| `ghcr.io/koorikla/ci-toolbox` | image |

Local checks before pushing (from `ci/`): `shellcheck -x scripts/*/*.sh tests/scripts/*.sh &&
bash tests/scripts/workload-bump.test.sh`; actionlint runs in the prek hooks (`prek.toml`).
