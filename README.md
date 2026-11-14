# koorikla/ci

Reusable GitHub Actions workflows that **build, test, scan, sign and attest** everything
koorikla ships: Go, Next.js, Elixir/Phoenix, Ruby/Rails, Helm charts, Crossplane
configuration packages and Crossplane providers. Every image is **multi-arch**
(`linux/amd64` + `linux/arm64`), Trivy-scanned per platform, gets an SPDX SBOM, GitHub
SLSA build provenance + SBOM attestations, a **cosign keyless signature** and a cosign
vulnerability attestation. The per-stack logic lives in portable shell scripts
(`scripts/`) that also run in-cluster via the `ghcr.io/koorikla/ci-toolbox` image.

| Workflow | What it does | Pushes |
|---|---|---|
| [`container.yaml`](.github/workflows/container.yaml) | Shared building block: multi-arch buildx build, Trivy scan of every platform (SARIF → code scanning), syft SBOM, attestations, cosign sign | image `ghcr.io/<owner>/<repo>` |
| [`go.yaml`](.github/workflows/go.yaml) | setup-go from go.mod, `go vet`, golangci-lint, `go test -race` + coverage, govulncheck, CodeQL → `container.yaml` | image |
| [`nextjs.yaml`](.github/workflows/nextjs.yaml) | setup-node (.nvmrc / .node-version / .tool-versions / engines), npm/pnpm/yarn by lockfile, lint, typecheck, test, cached `next build`, audit, Trivy fs, CodeQL → `container.yaml` | image |
| [`elixir.yaml`](.github/workflows/elixir.yaml) | setup-beam (.tool-versions), deps/_build cache, `compile --warnings-as-errors`, `format --check-formatted`, credo, `mix test` (+ optional Postgres), sobelow, `hex.audit`, `deps.audit`, Trivy fs → `container.yaml` | image |
| [`ruby.yaml`](.github/workflows/ruby.yaml) | setup-ruby with bundler cache, rubocop, rspec / `rails test` / `rake test` (+ optional Postgres), brakeman (Rails), bundler-audit, Trivy fs, CodeQL → `container.yaml` | image |
| [`helm-chart.yaml`](.github/workflows/helm-chart.yaml) | `helm lint --strict`, helm-unittest, package, push as OCI, cosign sign, provenance | chart `oci://ghcr.io/<owner>/charts/<name>` |
| [`crossplane-configuration.yaml`](.github/workflows/crossplane-configuration.yaml) | pinned Crossplane CLI, `crossplane resource validate` (package + examples + rendered output), `crossplane composition render` tests with expected-output diff, `xpkg build`, push, cosign sign, provenance | xpkg |
| [`crossplane-provider.yaml`](.github/workflows/crossplane-provider.yaml) | generate-is-clean check, vet/test/govulncheck/lint, multi-arch controller image via `container.yaml`, one xpkg per arch with the controller embedded, pushed as one multi-arch package, cosign sign, provenance | controller image + xpkg |

## Adopt: one file in your repo

```yaml
# .github/workflows/ci.yaml
name: ci
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  go:
    uses: koorikla/ci/.github/workflows/go.yaml@v1
    permissions: {contents: read, actions: read, packages: write, id-token: write, attestations: write, security-events: write}
```

Ready-to-copy callers for every stack are in [`templates/workflows/`](templates/workflows),
Dependabot configs in [`templates/dependabot/`](templates/dependabot) and Dockerfiles in
[`templates/dockerfiles/`](templates/dockerfiles) (Go distroless cross-compiled, Elixir
release on debian-slim, Rails/Ruby slim, Next.js standalone on distroless Node).

**Permissions matter.** A reusable workflow's jobs can never get more than the calling job
grants; if a nested job asks for more, GitHub fails the whole run at startup
(`startup_failure`, "workflow file issue", no jobs). Grant exactly the set listed in the
header comment of each workflow:

| Workflow | Caller job permissions |
|---|---|
| go, nextjs, ruby, crossplane-provider | `contents: read`, `actions: read`, `packages: write`, `id-token: write`, `attestations: write`, `security-events: write` |
| container, elixir | same without `actions: read` |
| helm-chart, crossplane-configuration | `contents: read`, `packages: write`, `id-token: write`, `attestations: write` |

`push: true` (default) only pushes on non-`pull_request` events; PRs build (amd64), test
and scan but never push or sign. For a registry other than GHCR pass `registry:` plus the
`registry_username` / `registry_password` secrets.

## What gets checked, per stack

| Stack | Lint / static analysis | Tests | Dependency vulns | SAST | Image |
|---|---|---|---|---|---|
| Go | `go vet`, golangci-lint | `go test -race` + coverage | govulncheck (call-graph aware) | CodeQL go | Trivy, SBOM, sign |
| Next.js | `lint` script (eslint), `typecheck` script / `tsc --noEmit` | `test` script, `next build` | `npm audit` / `pnpm audit` / `yarn npm audit` (prod deps, `audit_level`), Trivy fs on the lockfile | CodeQL javascript-typescript | Trivy, SBOM, sign |
| Elixir | `compile --warnings-as-errors`, `format --check-formatted`, credo `--strict` (if a dependency) | `mix test` (+ Postgres service) | `mix hex.audit` (retired), `mix deps.audit` (mix_audit, if a dependency), Trivy fs on mix.lock | sobelow (if a dependency, i.e. Phoenix). **CodeQL has no Elixir support.** | Trivy, SBOM, sign |
| Ruby / Rails | rubocop (if bundled) | rspec / `bin/rails test` / `rake test` (+ Postgres) | bundler-audit, Trivy fs on Gemfile.lock | brakeman (Rails), CodeQL ruby | Trivy, SBOM, sign |
| Helm | `helm lint --strict` | helm-unittest (`<chart>/tests/`) | - | - | chart signed + provenance |
| Crossplane configuration | `crossplane resource validate` of XRDs/Compositions/function inputs against Crossplane + dependency schemas | `crossplane composition render` per example XR, composed resources validated, diff vs expected | - | - | xpkg signed + provenance |
| Crossplane provider | `make generate` must leave a clean tree, `go vet`, golangci-lint | `go test -race` | govulncheck | CodeQL go (opt-in: slow on upjet) | controller image: Trivy, SBOM, sign; xpkg signed |

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

## Signing and attestation model

GitHub-built artifacts are signed **keyless** (Sigstore Fulcio + Rekor) with the job's OIDC
token. Because signing happens inside a *reusable* workflow, the certificate identity is the
reusable workflow, and the calling repository is recorded in certificate extensions:

| Certificate field | Value |
|---|---|
| Issuer | `https://token.actions.githubusercontent.com` |
| Subject (SAN) | `https://github.com/koorikla/ci/.github/workflows/{container,helm-chart,crossplane-configuration,crossplane-provider}.yaml@refs/tags/v1` |
| `githubWorkflowRepository` (1.3.6.1.4.1.57264.1.5) | caller, e.g. `koorikla/hello-world` |
| `githubWorkflowRef` (1.3.6.1.4.1.57264.1.6) | caller ref, e.g. `refs/heads/main` |
| Build Config URI | caller workflow, e.g. `https://github.com/koorikla/hello-world/.github/workflows/ci.yaml@refs/heads/main` |

So the identity `https://github.com/koorikla/<repo>/.github/workflows/<file>@refs/heads/main`
is the *caller*; it is carried in the extensions, not the SAN. **Always pin the caller
repository/ref as well as the subject:** `koorikla/ci` is public, so any repository can call
its workflows and obtain a certificate with the same SAN.

```sh
cosign verify ghcr.io/koorikla/hello-world:<sha> \
  --certificate-identity https://github.com/koorikla/ci/.github/workflows/container.yaml@refs/tags/v1 \
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
| SBOM | `actions/attest-sbom` (OCI referrer) | `https://spdx.dev/Document/v2.3` |
| Vulnerability scan | `cosign attest --type vuln` (Trivy cosign-vuln) | `https://cosign.sigstore.dev/attestation/vuln/v1` |

In-cluster builds use the same scripts but sign with the platform key
(`COSIGN_KEY=k8s://<ns>/<secret>` or a KMS URI, see `scripts/common/sign-image.sh`); the
admission policy accepts **either** attestor.

Kyverno (illustrative only; the real policy lives in koorikla/platform):

```yaml
# apiVersion: kyverno.io/v1
# kind: ClusterPolicy
# metadata:
#   name: verify-koorikla-images
# spec:
#   validationFailureAction: Enforce
#   webhookTimeoutSeconds: 30
#   rules:
#     - name: hello-world-signed-by-ci
#       match:
#         any:
#           - resources:
#               kinds: [Pod]
#       verifyImages:
#         - imageReferences: ["ghcr.io/koorikla/hello-world*"]
#           mutateDigest: true
#           verifyDigest: true
#           required: true
#           attestors:
#             - count: 1                      # GitHub keyless OR platform key
#               entries:
#                 - keyless:
#                     issuer: https://token.actions.githubusercontent.com
#                     subjectRegExp: '^https://github\.com/koorikla/ci/\.github/workflows/container\.yaml@refs/tags/v[0-9]+$'
#                     additionalExtensions:
#                       githubWorkflowRepository: koorikla/hello-world
#                       githubWorkflowRef: refs/heads/main
#                     rekor:
#                       url: https://rekor.sigstore.dev
#                 - keys:
#                     kms: k8s://kyverno/platform-cosign-pub   # in-cluster builds
#           attestations:
#             - type: https://cosign.sigstore.dev/attestation/vuln/v1
#               attestors:
#                 - entries:
#                     - keyless:
#                         issuer: https://token.actions.githubusercontent.com
#                         subjectRegExp: '^https://github\.com/koorikla/ci/\.github/workflows/container\.yaml@refs/tags/v[0-9]+$'
#                         additionalExtensions:
#                           githubWorkflowRepository: koorikla/hello-world
#               conditions:
#                 - all:
#                     - key: "{{ time_since('','{{metadata.scanFinishedOn}}','') }}"
#                       operator: LessThanOrEquals
#                       value: "168h"
```

cosign v3 stores signatures/attestations in the Sigstore bundle format (OCI referrers); make
sure the Kyverno version in the platform verifies that format (see VERIFY in the platform repo).

## Registry: GHCR now, Harbor later

Everything pushes to `ghcr.io/<owner>` by default. Harbor on the management cluster currently
**proxy-caches ghcr.io**, so clusters pull through Harbor while signatures/attestations stay
verifiable (same digests). To push to Harbor later set `registry: harbor.<domain>/<project>`
and pass a robot account as `registry_username` / `registry_password`.

GHCR packages are private when first created: make them public (package settings) or give the
pulling clusters credentials.

## Script contract (parity with in-cluster builds)

Workflows are thin: each step calls `scripts/<stack>/*.sh` or `scripts/common/*.sh`, fetched from
`koorikla/ci` at **the same commit as the running reusable workflow** (`job.workflow_sha`).

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
| `go/check.sh`, `nextjs/{detect,check}.sh`, `elixir/check.sh`, `ruby/check.sh`, `helm/{check,package-push}.sh` | stack checks |
| `crossplane/{install-cli,validate-render,xpkg-build,xpkg-push,provider-xpkg}.sh` | Crossplane CLI, validation/render tests, packaging |

### Toolbox image

`ghcr.io/koorikla/ci-toolbox` ([`toolbox/Dockerfile`](toolbox/Dockerfile), built by
[`toolbox.yaml`](.github/workflows/toolbox.yaml) through `container.yaml`, so it is itself
multi-arch, scanned, attested and signed): trivy, syft, cosign, crane, helm, yq, jq, git,
crossplane CLI, bash, make. Scripts are in `/opt/koorikla-ci/scripts` (`common/` on `PATH`,
`$CI_SCRIPTS` set). Tags: `<short sha>`, `<full sha>`, `main`; pin by digest in-cluster.

```sh
docker run --rm -v "$PWD:/workspace" -e IMAGE_REF=ghcr.io/koorikla/hello-world:main \
  -e IMAGE_SRC=remote ghcr.io/koorikla/ci-toolbox:main scan-image.sh
```

## Versioning

Callers pin `@v1`. `v1` is a **moving, lightweight** tag on `main`, moved only after the
selftest is green:

```sh
git tag -f v1 <sha> && git push -f origin v1
```

Keep it lightweight: with an annotated `v1`, nested `$/` workflow references failed with
"workflow was not found". Backwards-incompatible changes (renamed inputs, new required
permissions) go to `v2`. Reusable workflows call siblings with `uses: $/.github/workflows/…`
and fetch scripts at `job.workflow_sha`, so a caller pinned to `@v1` or a full SHA gets one
consistent set of workflows and scripts.

## Self-tests

[`selftest.yaml`](.github/workflows/selftest.yaml) runs every workflow against
[`fixtures/`](fixtures) on PRs, `workflow_dispatch`, and pushes to `main` touching
`.github/**`, `fixtures/**` or `scripts/**`: actionlint + shellcheck, Go module, Next.js app,
mix project (credo + mix_audit, no Phoenix so sobelow skips), Rack app (rspec, rubocop,
bundler-audit), Helm chart (helm-unittest), Crossplane configuration (XRD + Composition with
function-go-templating + example XR + expected render), and a tiny native provider skeleton
(generator, controller image, per-arch xpkg). Pushed artifacts:

| Package | Kind |
|---|---|
| `ghcr.io/koorikla/ci-selftest-go` | image |
| `ghcr.io/koorikla/ci-selftest-nextjs` | image |
| `ghcr.io/koorikla/ci-selftest-elixir` | image |
| `ghcr.io/koorikla/ci-selftest-ruby` | image |
| `ghcr.io/koorikla/ci-selftest-helm` | Helm chart (OCI) |
| `ghcr.io/koorikla/ci-selftest-crossplane-configuration` | xpkg |
| `ghcr.io/koorikla/ci-selftest-crossplane-provider` | xpkg (multi-arch) |
| `ghcr.io/koorikla/ci-selftest-crossplane-provider-controller` | image |
| `ghcr.io/koorikla/ci-toolbox` | image |

Local checks before pushing: `actionlint && shellcheck -x scripts/*/*.sh`.

## Workflow reference

Secrets for every workflow: `registry_username`, `registry_password` (optional; GHCR uses
`GITHUB_TOKEN`).

### container.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `image_name` | string | `''` | Image name (default: repository name) |
| `registry` | string | `''` | Registry prefix, e.g. ghcr.io/koorikla or harbor.example.com/apps (default ghcr.io/<owner>) |
| `context` | string | `.` | Docker build context |
| `dockerfile` | string | `Dockerfile` | Path to the Dockerfile |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated target platforms (PR builds are linux/amd64 only) |
| `build_args` | string | `''` | Newline-separated extra build-args (VERSION=<short sha> is always set) |
| `push` | boolean | `true` | Push, attest and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Comma-separated severities that fail the Trivy scan |
| `trivy_ignore_unfixed` | boolean | `true` | Ignore vulnerabilities without a fixed version |
| `trivy_fail` | boolean | `true` | Fail the job on findings at trivy_severity (false = report only) |
| `trivy_ignore_file` | string | `''` | Repo-relative .trivyignore(.yaml) with accepted risks (empty = none) |
| `upload_sarif` | boolean | `true` | Upload Trivy SARIF to GitHub code scanning |
| `sarif_category` | string | `''` | Code-scanning category (default container-<image>) |
| `artifact_name` | string | `''` | If set, download this workflow artifact into <context> before building (e.g. a prebuilt binary or xpkg inputs) |
| `multiarch_strategy` | string | `native` | native = one runner per arch (ubuntu-24.04 + ubuntu-24.04-arm) merged into one manifest list; qemu = single amd64 runner with buildx + QEMU |
| `runner_amd64` | string | `ubuntu-24.04` | Runner label for linux/amd64 builds |
| `runner_arm64` | string | `ubuntu-24.04-arm` | Runner label for linux/arm64 builds (native strategy) |

Outputs: `image`, `image_ref`, `image_repo`, `digest`, `image_digest_ref`, `short_sha`

### go.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `working_directory` | string | `.` | Go module directory |
| `go_version_file` | string | `''` | go.mod / .go-version used by setup-go (default <working_directory>/go.mod) |
| `run_lint` | boolean | `true` | Run golangci-lint |
| `golangci_lint_version` | string | `latest` | golangci-lint version |
| `run_vulncheck` | boolean | `true` | Run govulncheck |
| `run_codeql` | boolean | `true` | Run CodeQL (go) |
| `extra_test_cmd` | string | `''` | Extra shell command run in working_directory after tests |
| `build_container` | boolean | `true` | Build/scan/sign the container image after checks |
| `image_name` | string | `''` | Image name (default: repository name) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `context` | string | `''` | Docker build context (default working_directory) |
| `dockerfile` | string | `''` | Dockerfile (default <working_directory>/Dockerfile) |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated image platforms |
| `multiarch_strategy` | string | `native` | native (per-arch runners) or qemu |
| `build_args` | string | `''` | Newline-separated extra build-args |
| `push` | boolean | `true` | Push, attest and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Severities that fail the image scan |
| `trivy_ignore_unfixed` | boolean | `true` | Ignore unfixed vulnerabilities |
| `trivy_ignore_file` | string | `''` | Repo-relative .trivyignore(.yaml) with accepted risks |
| `trivy_fail` | boolean | `true` | Fail on findings at trivy_severity |

Outputs: `image`, `image_ref`, `image_repo`, `digest`, `image_digest_ref`, `short_sha`

### nextjs.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `working_directory` | string | `.` | Directory containing package.json |
| `node_version` | string | `''` | Node.js version (overrides .nvmrc/.node-version/.tool-versions/package.json engines) |
| `run_lint` | boolean | `true` | Run the lint script |
| `run_typecheck` | boolean | `true` | Run the typecheck script (or tsc --noEmit) |
| `run_test` | boolean | `true` | Run the test script |
| `run_audit` | boolean | `true` | Run npm/pnpm/yarn audit of production deps |
| `audit_level` | string | `critical` | Audit failure level: low, moderate, high, critical |
| `run_codeql` | boolean | `true` | Run CodeQL (javascript-typescript) |
| `build_container` | boolean | `true` | Build/scan/sign the container image after checks |
| `image_name` | string | `''` | Image name (default: repository name) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `context` | string | `''` | Docker build context (default working_directory) |
| `dockerfile` | string | `''` | Dockerfile (default <working_directory>/Dockerfile) |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated image platforms |
| `multiarch_strategy` | string | `native` | native (per-arch runners) or qemu |
| `build_args` | string | `''` | Newline-separated extra build-args |
| `push` | boolean | `true` | Push, attest and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Severities that fail the Trivy scans (image and lockfiles) |
| `trivy_ignore_unfixed` | boolean | `true` | Ignore unfixed vulnerabilities |
| `trivy_ignore_file` | string | `''` | Repo-relative .trivyignore(.yaml) with accepted risks |
| `trivy_fail` | boolean | `true` | Fail on Trivy findings at trivy_severity |

Outputs: `image`, `image_ref`, `image_repo`, `digest`, `image_digest_ref`, `short_sha`

### elixir.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `working_directory` | string | `.` | Directory containing mix.exs |
| `otp_version` | string | `''` | OTP version (default: from .tool-versions) |
| `elixir_version` | string | `''` | Elixir version (default: from .tool-versions) |
| `postgres` | boolean | `false` | Start a Postgres service for tests (DATABASE_URL, PG* env are set) |
| `postgres_image` | string | `postgres:17` | Postgres service image |
| `run_credo` | boolean | `true` | Run credo (only if it is a dependency) |
| `run_sobelow` | boolean | `true` | Run sobelow (only if it is a dependency) |
| `test_args` | string | `''` | Extra mix test arguments |
| `build_container` | boolean | `true` | Build/scan/sign the container image after checks |
| `image_name` | string | `''` | Image name (default: repository name) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `context` | string | `''` | Docker build context (default working_directory) |
| `dockerfile` | string | `''` | Dockerfile (default <working_directory>/Dockerfile) |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated image platforms |
| `multiarch_strategy` | string | `native` | native (per-arch runners) or qemu |
| `build_args` | string | `''` | Newline-separated extra build-args |
| `push` | boolean | `true` | Push, attest and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Severities that fail the Trivy scans (image and lockfiles) |
| `trivy_ignore_unfixed` | boolean | `true` | Ignore unfixed vulnerabilities |
| `trivy_ignore_file` | string | `''` | Repo-relative .trivyignore(.yaml) with accepted risks |
| `trivy_fail` | boolean | `true` | Fail on Trivy findings at trivy_severity |

Outputs: `image`, `image_ref`, `image_repo`, `digest`, `image_digest_ref`, `short_sha`

### ruby.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `working_directory` | string | `.` | Directory containing Gemfile |
| `ruby_version` | string | `''` | Ruby version (default: .ruby-version / .tool-versions) |
| `test_command` | string | `auto` | Test command; 'auto' = rspec / bin/rails test / rake test; 'none' skips |
| `run_rubocop` | boolean | `true` | Run rubocop (only if bundled) |
| `run_brakeman` | string | `auto` | Run brakeman: 'auto' (Rails apps), 'true' or 'false' |
| `postgres` | boolean | `false` | Start a Postgres service for tests (DATABASE_URL, PG* env are set) |
| `postgres_image` | string | `postgres:17` | Postgres service image |
| `run_codeql` | boolean | `true` | Run CodeQL (ruby) |
| `build_container` | boolean | `true` | Build/scan/sign the container image after checks |
| `image_name` | string | `''` | Image name (default: repository name) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `context` | string | `''` | Docker build context (default working_directory) |
| `dockerfile` | string | `''` | Dockerfile (default <working_directory>/Dockerfile) |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated image platforms |
| `multiarch_strategy` | string | `native` | native (per-arch runners) or qemu |
| `build_args` | string | `''` | Newline-separated extra build-args |
| `push` | boolean | `true` | Push, attest and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Severities that fail the Trivy scans (image and lockfiles) |
| `trivy_ignore_unfixed` | boolean | `true` | Ignore unfixed vulnerabilities |
| `trivy_ignore_file` | string | `''` | Repo-relative .trivyignore(.yaml) with accepted risks |
| `trivy_fail` | boolean | `true` | Fail on Trivy findings at trivy_severity |

Outputs: `image`, `image_ref`, `image_repo`, `digest`, `image_digest_ref`, `short_sha`

### helm-chart.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `chart_path` | string | `.` | Chart directory |
| `chart_version` | string | `''` | Chart version override |
| `app_version` | string | `''` | appVersion override |
| `lint_args` | string | `''` | Extra helm lint arguments |
| `helm_version` | string | `latest` | Helm version for azure/setup-helm |
| `registry` | string | `''` | OCI registry prefix for charts (default ghcr.io/<owner>/charts) |
| `push` | boolean | `true` | Push and sign on non-PR events |

Outputs: `chart`, `digest`, `chart_digest_ref`

### crossplane-configuration.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `package_root` | string | `.` | Directory containing crossplane.yaml |
| `examples_dir` | string | `examples` | Example XRs (relative to package_root); bundled into the package |
| `render_dir` | string | `tests/render` | Render test assets relative to package_root (functions.yaml, expected/, observed/, extra-resources/) |
| `ignore` | string | `''` | Extra comma-separated xpkg build --ignore patterns |
| `crossplane_version` | string | `v2.5.0` | Crossplane CLI version |
| `package_name` | string | `''` | Package (OCI repository) name (default: metadata.name in crossplane.yaml) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `push` | boolean | `true` | Push and sign on non-PR events |

Outputs: `package`, `digest`, `package_digest_ref`

### crossplane-provider.yaml

| Input | Type | Default | Description |
|---|---|---|---|
| `working_directory` | string | `.` | Provider repository root (go.mod, Makefile) |
| `package_root` | string | `package` | Directory with crossplane.yaml + crds, relative to working_directory |
| `generate_command` | string | `make generate` | Code generation command checked for a clean git diff ('' skips) |
| `run_lint` | boolean | `true` | Run golangci-lint |
| `run_vulncheck` | boolean | `true` | Run govulncheck |
| `run_codeql` | boolean | `false` | Run CodeQL (go); slow on large generated upjet providers |
| `go_test_flags` | string | `-race -coverprofile=coverage.out -covermode=atomic ./...` | go test flags |
| `crossplane_version` | string | `v2.5.0` | Crossplane CLI version |
| `package_name` | string | `''` | Package (OCI repository) name (default: metadata.name in crossplane.yaml) |
| `controller_image_name` | string | `''` | Controller image name (default <package_name>-controller) |
| `registry` | string | `''` | Registry prefix (default ghcr.io/<owner>) |
| `dockerfile` | string | `''` | Controller Dockerfile (default <working_directory>/Dockerfile) |
| `platforms` | string | `linux/amd64,linux/arm64` | Comma-separated platforms (controller image and package) |
| `multiarch_strategy` | string | `native` | native (per-arch runners) or qemu |
| `push` | boolean | `true` | Push and sign on non-PR events |
| `trivy_severity` | string | `CRITICAL` | Severities that fail the controller image scan |

Outputs: `package`, `digest`, `package_digest_ref`, `controller_image_digest_ref`

