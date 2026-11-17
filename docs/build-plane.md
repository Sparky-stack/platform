# Build plane: OpenChoreo workflow plane + Harbor

In-cluster builds are the **primary, CI-provider-agnostic build path**: a Component names a ClusterWorkflow, a
WorkflowRun (Backstage "Build", `occ`, or the platform's auto-build trigger on every push) runs it on the OpenChoreo
workflow plane, the image lands in Harbor signed and scanned, and the new image ref is **committed to the app repo** so
Argo CD deploys it. GitHub Actions ([koorikla/ci](https://github.com/koorikla/ci) reusable workflows) remain an
optional path that runs the same scripts. Teams choose per Component.

```
WorkflowRun (Backstage / occ / auto-build)         mgmt
  └ ClusterWorkflow <stack> (control plane) ──► Argo Workflow in workflows-<org ns> (workflow plane, via cluster-agent)
       checkout ─┬ check (toolchain image + koorikla/ci scripts/<stack>/check.sh) ─┐
                 └ scan-fs (scan-fs.sh) ────────────────────────────────────────────┴ build (rootless BuildKit,
       multi-arch, push by digest, SLSA provenance) ─┬ scan-image (scan-image.sh) ─┬ sign (sign-image.sh + SBOM attest,
                                                     └ sbom (sbom.sh) ─────────────┘  platform cosign key) ─ gitops
  gitops: commit image <repo>:<sha>@sha256:… into deploy/openchoreo/workload.yaml ──► Argo CD syncs ──► autoDeploy
          → ComponentRelease → ReleaseBinding development → data plane (unchanged delivery path, docs/openchoreo.md)
```

Git stays the source of truth: no step writes a Workload into the cluster (upstream's samples PUT the Workload through
the OpenChoreo API; here the Workload changes only by commit).

## What runs where

| Where | Addon | Namespace | What |
|---|---|---|---|
| mgmt | `openchoreo-workflow-plane` | openchoreo-workflow-plane | Argo Workflows v4.0.8 controller (no UI), cluster-agent (in-cluster to the cluster-gateway), `ClusterWorkflowPlane default`, Argo `ClusterWorkflowTemplate`s `koorikla-build`, `koorikla-helm-chart` |
| mgmt | `openchoreo-platform` | default | `ClusterWorkflow`s `go`, `nextjs`, `elixir`, `ruby`, `dockerfile` (component) and `helm-chart` (generic); every ClusterComponentType's `allowedWorkflows` |
| mgmt | `harbor` | harbor | Harbor 2.15.4 behind Gateway `harbor` (kgateway, HTTPS 9443), Trivy, desired-state Job; `ClusterSecretStore mgmt-harbor` |
| mgmt | (OpenChoreo) | workflows-default | one Argo Workflow + pods per WorkflowRun, per-run ExternalSecrets; ServiceAccount `workflow-sa` and Role created by the WorkflowRun controller; namespace + default-deny NetworkPolicy from addon openchoreo-workflow-plane |
| workload | `charts/cluster` + ClusterClass | node OS | k3s `registries.yaml`: Harbor proxy-cache mirrors, robot auth, registry CA; CAPD `/etc/hosts` alias |

## Build ClusterWorkflows

One ClusterWorkflow per stack (`addons/openchoreo-platform/values.yaml` `buildWorkflows.stacks`), all running
`koorikla-build` with the [koorikla/ci](https://github.com/koorikla/ci) toolbox
`ghcr.io/koorikla/ci-toolbox:v1@sha256:d950…6b79` (multi-arch, cosign-signed) for checkout, scans, SBOM, signing and
the GitOps commit, and the official toolchain image for the stack checks:

| ClusterWorkflow | Checks (koorikla/ci script) | Toolchain image (default, override per Component) |
|---|---|---|
| `go` | `go/check.sh`: vet, golangci-lint if present, `go test -race`, govulncheck | `golang:1.27.4-trixie` |
| `nextjs` | `nextjs/check.sh`: install, lint, typecheck, test, `next build`, audit | `node:24.22.3-trixie-slim` |
| `elixir` | `elixir/check.sh` (+ optional ephemeral PostgreSQL) | `elixir:1.19.7-otp-28` |
| `ruby` | `bundle install` + `ruby/check.sh` (+ optional PostgreSQL) | `ruby:3.4.12-trixie` |
| `dockerfile` | none (lockfile scan, image scan, SBOM, signing only) | - |
| `helm-chart` (generic) | `helm/check.sh` + `helm/package-push.sh` → `<registry>/charts/<chart>` (OCI), signed | toolbox |

All images are pinned by digest. Every step after `checkout` gates the next: a CRITICAL finding (Trivy, lockfiles or
image, `ignore-unfixed` by default) stops the run before anything is signed or committed, so an unsigned image never
reaches a Workload.

### Using it from a Component (app repo)

```yaml
# deploy/openchoreo/component.yaml
spec:
  autoDeploy: true
  workflow:
    kind: ClusterWorkflow
    name: go                         # go | nextjs | elixir | ruby | dockerfile
    parameters:
      repository:
        url: https://github.com/koorikla/hello-world.git
        revision: { branch: main }
        appPath: "."
      docker: { context: ".", filePath: Dockerfile }
      # platforms: linux/amd64        # default linux/amd64,linux/arm64
      # checks: { image: docker.io/library/golang:1.27.4-trixie@sha256:…, env: { RUN_LINT: "false" } }
      # scan: { failSeverities: "CRITICAL,HIGH", ignoreFile: .trivyignore.yaml }
      # gitops: { workloadPath: deploy/openchoreo/workload.yaml }
```

Trigger a build: Backstage → component → **Build** (WorkflowRun with live task status and logs), `occ`, a
`WorkflowRun` object, or a push to the build branch when the Component sets `autoBuild: true` ("Auto-build" below).
OpenChoreo's matcher treats appPath `.` as "every change", so the hand-off commit would re-trigger the build:
`checkout` skips commits that only touch the GitOps directory (loop guard), the auto-build trigger does not even start
a run for them, and the commit message carries `[skip ci]` for the GitHub Actions path (in hello-world, GitHub Actions
runs only the checks unless `IMAGE_BUILDER=github-actions`).

### Auto-build (poll or webhook)

`spec.autoBuild: true` (OpenChoreo's own flag) builds every new commit of the Component's build branch. OpenChoreo
1.3.3 has no polling, only a webhook into openchoreo-api (`POST /api/v1alpha1/autobuild`, secret
`openchoreo-control-plane/git-webhook-secrets`) whose runs get random names (a redelivered push builds twice), and a
local k3d stack cannot receive webhooks at all. The platform therefore owns the trigger, selected per installation in
`installation.yaml` `openchoreo.workflowPlane.autoBuild`:

| Trigger | Installations | Push → build |
|---|---|---|
| `poll` | local | CronWorkflow `auto-build-poll`, every minute (`concurrencyPolicy: Forbid`); nothing exposed |
| `webhook` | aws-example, gcp-example, hetzner-example | GitHub App webhook → `https://events.<host>/github` (control-plane Gateway, TLS listener) → Argo Events EventSource `github` (checks `X-Hub-Signature-256` with store key `github-webhook`, never calls GitHub) → Sensor `auto-build` → a Workflow for the pushed repository; the CronWorkflow still runs every 30 min to catch missed deliveries |
| `none` | - | Backstage / `occ` / `kubectl` only |

Both triggers run the same Argo WorkflowTemplate `auto-build` in `workflows-<org ns>` (addon openchoreo-platform,
`files/auto-build/auto_build.py`). One pass:

1. Lists Components with `autoBuild: true` and reads repository URL, branch and commit parameter paths from their
   ClusterWorkflow schema's `x-openchoreo-component-parameter-repository-*` markers (the ones OpenChoreo's webhook
   matcher uses). Only github.com repositories under `buildWorkflows.git.allowedRepositoryPrefixes`.
2. Reads the branch head (`GET /repos/<owner>/<repo>/commits/<branch>`), conditionally with the cached ETag.
3. Stops if WorkflowRun `<component>-<sha[:12]>` exists, or while an earlier auto-build run of the component is still
   running (no out-of-order image bumps; a run unfinished after 2 h no longer blocks).
4. Reads `spec.source.commit` from the Workload file at the head commit: when every change since that commit is inside
   the GitOps directory (the hand-off commit itself, promotion merges), there is nothing to build.
5. Otherwise creates WorkflowRun `<component>-<sha[:12]>` (labels `openchoreo.dev/component`, `openchoreo.dev/project`,
   `platform.koorikla.io/trigger: auto-build`; annotation `platform.koorikla.io/commit`) from the Component's workflow
   with `repository.revision.commit` set to the head. From there it is an ordinary build: hand-off commit, Argo CD,
   `autoDeploy` to development.

**Idempotent per commit.** The run name is derived from the SHA (a second create is `AlreadyExists`), and "already
built" is read from git (step 4), not from cluster state. ConfigMap `auto-build-state` (ETags, last handled head per
Component) is only a cache: restarts, a lost cache, garbage-collected runs (`ttlAfterCompletion`) and redelivered or
replayed webhooks never build a commit twice. A webhook payload only selects the repository; the head always comes from
GitHub, so a forged push can at most cause one extra reconcile.

**Credentials.** ESO's `GithubAccessToken` generator mints an installation token of the platform's GitHub App (store
key `autoBuild.github.key`, default `promotion-gate-github`, through the scoped store `workflows`) restricted to
`contents: read`, re-minted every 30 min (GitHub expires it after 1 h). The pass mounts only that token; the App key
stays in a Secret that only ESO reads. No PAT.

**PR heads.** With `installation.yaml` `previews.enabled` the same pass also builds the head of every open pull request
of an opted-in Component (WorkflowRun `<component>-pr<n>-<sha[:12]>`, label `platform.koorikla.io/trigger: preview`,
`gitops.enabled: false`) for its preview environment: [preview-environments.md](preview-environments.md).

**Least privilege.** ServiceAccount `auto-build`: `list` Components, `get` (Cluster)Workflows, `get`/`list`/`create`
WorkflowRuns in the org namespace; in the run namespace `create` ConfigMaps, `get`/`update` only `auto-build-state`, and
Argo's task results. Network: the run namespace's default-deny policy (DNS, API server, public 443), no ingress. Webhook
mode: the Sensor may only create Workflows in the run namespace, and ValidatingAdmissionPolicy
`argo-events-auto-build-workflows` pins them to WorkflowTemplate `auto-build` with only the `repository` argument.

**Rate limits.** Per pass one conditional request per repository and branch (a 304 does not count against GitHub's
limit), two more (Workload file, compare) only when the head moved; a pass pauses when fewer than `minRateRemaining`
requests are left and creates at most `maxRunsPerPass` runs. Values: addon openchoreo-platform `autoBuild`, addon
argo-events `autoBuildWebhook`.

Operate:

```bash
kubectl -n workflows-default get cronworkflow auto-build-poll
kubectl -n workflows-default get workflows -l workflows.argoproj.io/cron-workflow=auto-build-poll
kubectl -n workflows-default get cm auto-build-state -o jsonpath='{.data.state\.json}'
kubectl -n default get workflowrun -l platform.koorikla.io/trigger=auto-build
```

Opt out per Component with `autoBuild: false`, per installation with `none`. Webhook setup (cloud): GitHub App
settings → Webhook active, URL `https://events.<openchoreo.controlPlane.host>/github`, secret = store key
`github-webhook` property `secret`, subscribe to Push. The webhook path renders and is tested offline; live
verification: [#166](https://github.com/koorikla/platform/issues/166).

### GitOps hand-off

`gitops` clones the source repo at the built branch, sets `spec.container.image` (`<repo>:<short sha>@sha256:<digest>`)
and `spec.source.commit` in `deploy/openchoreo/workload.yaml` with yq, and commits the file through the GitHub contents
API (`PUT /repos/<owner>/<repo>/contents/<path>` with the blob `sha` as compare-and-swap; a 409 re-reads the branch and
retries). GitHub authors, commits and signs that commit as the App's bot (`<app-slug>[bot]`, Verified). Only an
OpenChoreo `Workload` at `deploy/openchoreo/<name>.yaml` is ever rewritten (schema pattern on `gitops.workloadPath`,
plus a script check: no symlink on the path, `kind: Workload`). A protected build branch needs the App on the
branch-protection or ruleset bypass list (hello-world's `main` is unprotected). Argo CD (Application
`<project>-<app>`) syncs; `autoDeploy` cuts the ComponentRelease and binds development; staging/production stay
promotion-by-PR (docs/openchoreo.md "How GitOps promotion works").

### Git credentials

No long-lived token. Every WorkflowRun renders an ESO `GithubAccessToken` generator `<run>-git` in `workflows-<org ns>`
that mints an installation token of the platform GitHub App (store key `buildWorkflows.github.key`, default
`promotion-gate-github`) for exactly one repository, the name of the run's `repository.url` (OpenChoreo CEL, `.git`
removed), with `permissions` `contents: write` (helm-chart builds: `contents: read`). ExternalSecret `<run>-git` turns
it into the basic-auth Secret the checkout and gitops pods mount (`x-access-token`), re-minted every
`tokenRefreshInterval` (30 min; GitHub expires tokens after 1 h); both are deleted with the WorkflowRun. A build can
therefore neither read nor push to another repository, even one the App is installed on.

The App's private key reaches only ESO: ExternalSecret `build-github-app` (template `build-github.yaml`) reads it
through the scoped store `workflows`; no pod mounts it. OpenChoreo's workflow-plane agent applies the per-run
generators, so it gets a Role for `githubaccesstokens` in the run namespace only. Requirements: the App has
Contents: Read and write and is installed on the repository. If it is not, GitHub refuses the token, the Secret never
appears, and checkout fails with `no GitHub token for <repo>: Secret <run>-git was not created ...`. The ExternalSecret
only reports `could not get secret data from provider`; GitHub's answer (`422 ... not accessible to the parent
installation`) is in the ESO controller log (`kubectl -n external-secrets logs deploy/external-secrets | grep <run>-git`). Fix: GitHub → Settings → Applications → the App →
Configure → Repository access → add the repository.

### Multi-arch

`platforms` defaults to `linux/amd64,linux/arm64`. Dockerfiles that cross-compile (`FROM --platform=$BUILDPLATFORM`,
like hello-world's Go build) need no emulation. `RUN` steps of a foreign architecture need QEMU binfmt handlers on the
build node's kernel (present on the dev host: an arm64 `RUN uname -m` printed `aarch64` in rootless BuildKit on the
amd64 mgmt node; install with `tonistiigi/binfmt` where missing - it changes the host kernel, so it is not done by the
platform). Narrow `platforms` per Component to build only the node's architecture.

### Security posture of build pods

- **Repository allowlist.** Builds clone from and push to only the installation's allowed repository prefixes
  (`buildWorkflows.git.allowedRepositoryPrefixes`, default `installation.githubOrg` + `/`, each `https://<host>/<owner>/`).
  Three layers: the ClusterWorkflow schema `pattern` on `repository.url` (one repo name after a prefix); `BUILD_GUARDS`
  in the checkout and gitops scripts (same check, git config only from the environment, `protocol.allow=never` except
  https); and git's credential helper registered per prefix (`credential.<prefix>.helper`, no global `GIT_ASKPASS`), so
  the token never answers a 401 from another host or owner, redirects included. The token itself only works for the
  run's repository ([Git credentials](#git-credentials)). Branch, commit and path parameters
  have patterns against option injection (`--upload-pack=…`) and traversal; the build step refuses a context or
  Dockerfile that resolves outside the checkout (that pod also mounts the registry push credentials).
  `hack/tests/test_build_guards.sh` exercises all of it with real `git credential fill` (negative cases first).
  Residual: any build may use any repo under an allowed owner (a tenant can rebuild another tenant's repo at an old
  commit); per-repo GitHub App installation tokens close that ([#34](https://github.com/koorikla/platform/issues/34)).
- Pod Security `restricted` for every step (non-root 65532, RuntimeDefault seccomp, no privilege escalation, all
  capabilities dropped, read-only root where the tool allows) **except `build`**: rootless BuildKit runs as uid 1000
  with no effective capabilities, but needs `seccompProfile`/`appArmorProfile: Unconfined` to create user namespaces
  (rootlesskit), and privilege escalation with `SETUID`/`SETGID` kept in the bounding set (all others dropped):
  rootlesskit maps the user namespace with `newuidmap`/`newgidmap`, which gain those two caps from file capabilities.
  It reads the run volume through `supplementalGroups: [65532]`, not `fsGroup` (which would chown BuildKit's state
  emptyDir to a gid the user namespace does not map). Snapshotter `overlayfs` (rootless overlay mounts, Linux >= 5.11):
  `auto` picked the copying `native` snapshotter on the k3d node and a hello-world build took over 15 minutes. No
  privileged container, no Docker daemon, no DinD. Kyverno's Pod Security policies (Audit) report that pod.
- **No ServiceAccount token in run containers**: both ClusterWorkflowTemplates (and the ClusterWorkflows' run
  templates) set `automountServiceAccountToken: false` + `executor.serviceAccountName: workflow-sa`, so only Argo's
  init/wait containers can write `workflowtaskresults`. Tenant check code cannot rewrite another run's outputs (e.g. the
  digest that `sign` signs). Argo mounts that executor token from the Secret `workflow-sa.service-account-token`, which
  addon openchoreo-workflow-plane renders in the run namespace with the ServiceAccount (`runExecutorToken`; Kubernetes
  no longer creates token Secrets and OpenChoreo creates only the ServiceAccount and its Role). Without it every run pod
  hangs in `Init` (`FailedMount`).
- **Default-deny network** for `workflows-<org ns>` (addon openchoreo-workflow-plane `runNetworkPolicy`; the addon
  also renders the namespace so the policy exists before the first run): no ingress; egress only to DNS, the Harbor
  Gateway proxy pods (port 9443), the API server (Argo's executor) and TCP 80/443 outside private ranges. Tenant check
  and `RUN` code cannot reach argocd-repo-server, harbor-core over HTTP, webhooks or other mgmt Services. Platform
  workflows that must call OpenChoreo (the `promotion-gate` ClusterWorkflow, docs/promotion.md) opt in through the pod
  label `runNetworkPolicy.platformWorkflows.podLabels`: NetworkPolicy `platform-workflows-openchoreo` adds egress to the
  control-plane Gateway (8080: API, Thunder) and the observability Gateway (`httpPort`). Build runs never carry it.
- Supply-chain steps (`scan-fs`, `scan-image`, `sbom`, `sign`) run with `HOME=/tmp` and `TRIVY_CACHE_DIR=/tmp/trivy`
  (per-pod emptyDir), not on the run volume the tenant `check` step writes, so tenant code cannot plant tool config
  (`~/.docker`, `~/.sigstore`, Trivy DB). Cost: each scan step downloads the Trivy DB.
- Per-run Secrets are ExternalSecrets the ClusterWorkflow renders into `workflows-<ns>` for each run (owned by the
  run, deleted with it): git credentials, registry push credentials and the cosign key via `ClusterSecretStore/workflows`
  (scoped to `workflows-*` and `workflowStore.keys`, never the full `platform` store), plus the registry CA (public,
  via `ClusterSecretStore/mgmt-harbor`).
- Signing: see "Signing" below.

### Signing

Deliberate deviation from keyless: [conventions.md](conventions.md#current-practice-only) asks for keyless Sigstore
signing. In-cluster builds use a **static platform key** instead: public Fulcio
issues certificates only for OIDC issuers it trusts, and a local k3d (or private EKS/Hetzner) workload identity is not
one of them. The GitHub Actions path stays keyless.

- Key pair `cosign-platform` (private key encrypted with `cosign.password`; only in the secret backend and the signing
  pod; `task secrets` generates it once). Cloud installations should use a KMS key reached through workload identity
  instead of a key file, so no key material sits in the secret backend
  ([#37](https://github.com/koorikla/platform/issues/37)).
- **No public transparency log by default**: `buildWorkflows.signing.transparencyLog: false` makes the sign steps use a
  cosign v3 signing config without Rekor/TSA (a shim adds `--signing-config` to `cosign sign|attest`; koorikla/ci
  `sign-image.sh` has no switch yet, [#37](https://github.com/koorikla/platform/issues/37)), so private repo names and digests never reach public Rekor and signing needs no
  egress to Sigstore. Set it `true` per installation (`installations/<inst>/addons/openchoreo-platform/values.yaml`) to
  upload to public Rekor.
- Verify: `cosign verify --key cosign.pub --insecure-ignore-tlog=true <image>@sha256:…` (and `verify-attestation --type
  vuln` / `--type https://spdx.dev/Document/v2.3`: the SBOM uses the predicate type of koorikla/ci's GitHub path, so
  admission checks one SBOM type for both). `cosign.pub`: `kubectl -n platform-secrets get secret cosign-platform -o jsonpath='{.data.cosign\.pub}' | base64 -d`.
- Admission: addon kyverno-policies trusts `<registry.host>/<registry.appsProject>/` (prefix from installation.yaml)
  only with this `cosign.pub` (tlog ignored, `rekor: false`) and the signed SBOM + vuln attestations: inline
  (`imageVerification.platformKey.publicKey`) or, with Harbor, delivered from mgmt to each workload cluster's Kyverno
  together with the Harbor CA and a pull-only robot (local default): [supply-chain.md](supply-chain.md#wiring-the-key).

## Registry: Harbor

`installation.yaml`:

```yaml
registry:
  type: harbor                                # harbor | external
  host: harbor.openchoreo.localhost:9443
  appsProject: apps
  proxyCache: [{ upstream: docker.io, project: dockerhub }, ...]   # + ghcr.io, quay.io, registry.k8s.io, cr.openchoreo.dev, gcr.io
  mirror: { enabled: true }                   # node mirrors
  nodeHostAlias: k3d-platform-mgmt-serverlb   # local only
  external: { repository: ghcr.io/koorikla, credentialsKey: platform-ghcr }   # type external
```

`type: external` (aws/hetzner examples): builds push to `<external.repository>/<component>` with that key's
credentials, nodes pull upstream, the `harbor` addon is disabled for mgmt.

### Endpoint, TLS and trust

One name everywhere, `https://harbor.openchoreo.localhost:9443` (Harbor's token realm is its externalURL, so every
client must resolve that name itself):

| Client | Path |
|---|---|
| browser / `docker login` on the host | 127.0.0.1:9443 → k3d serverlb → mgmt node → klipper hostPort of Gateway Service `harbor` |
| mgmt pods (builds) | coredns-local rewrites the name to `harbor.harbor.svc.cluster.local` (Service port 9443) |
| CAPD nodes (containerd) | `/etc/hosts`: name → IP of `k3d-platform-mgmt-serverlb` on network `kind` (ClusterClass `registryHostAlias`, written before k3s starts) |

TLS terminates at the Gateway with `harbor-tls` (SAN: the registry host only, the listener's hostname), issued by the
**namespaced** `Issuer harbor/harbor-ca`: no `ClusterIssuer`, so nobody allowed to create cert-manager `Certificate`s
elsewhere on mgmt can mint a cert the nodes trust for the registry host. The CA key stays in ns `harbor`. Its **public**
certificate alone is copied by ESO (namespaced `SecretStore harbor-ca-source`, may `get` only Secret `harbor-ca`,
property `tls.crt`) into Secret `harbor/harbor-ca-bundle`, which holds nothing but `ca.crt`, and published through
`ClusterSecretStore mgmt-harbor`, whose ServiceAccount may `get` exactly that Secret (name-scoped RBAC) and which only
namespaces `fleet` and `workflows-*` can use. Nodes get it as
`/etc/rancher/k3s/registry-ca.crt` (`registries.yaml` `tls.ca_file`), build pods as `<run>-registry-ca`.

### Pod Security

Harbor is **not** a Kyverno-excluded platform namespace: its 2.15 workloads meet Pod Security baseline (no privileged
container, host namespaces, hostPath, hostPort or added capabilities), so the Audit `ValidatingPolicies` report on
`harbor` like on any workload and no `PolicyException` is needed (`hack/tests/test_gitops_contracts.sh` check 9 fails
if a Harbor bump changes that).

### Declarative configuration

Harbor has no CRDs, and no maintained operator covers 2.15. `files/harbor-config.py` (stdlib Python, Harbor API v2.0)
applies the desired state rendered from `addons/harbor/values.yaml` `config` as an Argo CD PostSync hook and an hourly
CronJob: idempotent create/update, never delete. Chosen over Terraform/OpenTofu (state backend + provider credentials
on mgmt for a handful of objects).

| Object | Desired state |
|---|---|
| projects | `apps` (builds; scan on push, severity critical, system CVE allowlist), `apps-ghcr` (replication target), proxy-cache projects `dockerhub`, `ghcr`, `quay`, `k8s`, `openchoreo`, `gcr`; all private |
| registries | one endpoint per upstream; `ghcr.io` anonymous by default, or with the credentials in `secrets.ghcrKey` (e.g. `platform-ghcr`, needed for private packages and replication) |
| replication | `ghcr-koorikla`: pull `koorikla/**` from GHCR into `apps-ghcr` every 6h |
| robots | `robot$builder` (push/pull `apps`, pull the rest), `robot$nodes` (pull all); secrets set from the secret backend |
| system | CVE allowlist empty |

Content trust (`enable_content_trust_cosign` on `apps`) is **off** until it is confirmed that Harbor 2.15 counts cosign
v3 Sigstore-bundle referrers as signatures; enabling it blocks every pull without one
([#39](https://github.com/koorikla/platform/issues/39)). Every chart secret
(core, jobservice, registry, CSRF, secretKey, htpasswd, DB password, admin password) comes from key `harbor`: the
chart's own generated values re-roll on every Argo CD render (`helm template` has no `lookup`).

### Node pulls: mirrors with fallback

`charts/cluster` renders `fleet/<name>-registries` (ESO) with `registries.yaml`:

```yaml
mirrors:
  docker.io:
    endpoint: ["https://harbor.openchoreo.localhost:9443"]
    rewrite: { "^(.*)$": "dockerhub/$1" }     # same for ghcr.io, quay.io, registry.k8s.io, cr.openchoreo.dev, gcr.io
configs:
  ghcr.io: { auth: … }                         # platform-ghcr (fallback path)
  harbor.openchoreo.localhost:9443:
    auth: { username: robot$nodes, password: … }
    tls: { ca_file: /etc/rancher/k3s/registry-ca.crt }
```

containerd tries Harbor first and falls back to the upstream registry, so a Harbor outage slows pulls instead of
breaking them. Bootstrap data is rendered once per Machine: changes reach new machines only, and a change to the
ClusterClass patches rolls every machine of the class ([providers.md](providers.md#template-changes-roll-clusters)).
Patch order matters: `cni-flannel` replaces the control plane's whole `files` list, so it runs before every patch that
appends files (`registries.yaml`, the registry CA).

### Images and architectures

Harbor 2.15 publishes linux/amd64 images only (arm64 arrives as separate `-arm64` tags in 2.16, not as a manifest
list). This is a **deliberate, expiring exception** to the multi-arch rule: the 8 Harbor images (`goharbor/harbor-core`,
`harbor-db`, `harbor-jobservice`, `harbor-portal`, `harbor-registryctl`, `registry-photon`, `trivy-adapter-photon`,
`valkey-photon`, tag prefix `v2.15.`) are listed in `hack/image-audit.sh` `ARCH_EXCEPTIONS` with an expiry
(2027-03-31), so `task images:audit` stays green and reports them as `EXCEPTION`. A Harbor bump or the expiry date
drops the exception and the audit fails again; the list goes away with Harbor 2.16
([#27](https://github.com/koorikla/platform/issues/27)).
`hack/tests/test_image_audit.sh` pins the list to exactly those images. On arm64 hosts use `registry.type: external`.
Everything else added here (BuildKit, toolbox, Argo Workflows, cluster-agent, toolchains, Python, PostgreSQL) is
multi-arch and pinned by digest.

Digest pinning (every addon, not only the build plane): each image an addon renders is
`<registry host>/<path>:<tag>@sha256:<multi-arch index digest>`, set in the addon's `values.yaml` (`tag: <v>@sha256:…`,
or the chart's own `digest` / `sha` field where `tag@digest` would break a label or a semver parse). The same holds for
the CAPD node image (`addons/clusterclasses` `docker.kindImage`) and the k3d mgmt node (`bootstrap/k3d-mgmt.yaml`).
`hack/tests/test_image_pins.sh` renders every installation with opt-in addons (`hack/image-audit.sh --list --rendered
--opt-in`) and fails on any image without a registry host or digest, and on a tag@digest leaking into a label. Its
`PIN_EXCEPTIONS` (exact image or glob, commented, failing once unused) holds what a chart cannot render: the
falcosidekick `helm test` pod, falco-talon 0.5.0 and Strimzi's per-Kafka-version broker map (pin brokers per Kafka CR,
[data-services.md](data-services.md#kafka-strimzi)). Resolve a digest with `crane digest <image>:<tag>` (the index digest of a
multi-arch image); a chart bump updates tag and digest together. Images created at runtime from upstream manifests
(k3s system images, CAPI provider controllers, k3d helpers, the CAPD load balancer, the kgateway envoy proxy) are
audited for architectures by `task images:audit` but not digest-pinned here.

## Secrets (ClusterSecretStore `platform`)

| Key | Properties | Used by |
|---|---|---|
| `harbor` | `admin-password`, `secret-key` (16), `core-secret`, `csrf-key` (32), `jobservice-secret`, `registry-http-secret`, `registry-password`, `database-password`, `builder-secret`, `nodes-secret` | addon harbor; builds (`builder-secret`); nodes (`nodes-secret`) |
| `cosign-platform` | `cosign.key` (encrypted), `cosign.pub`, `cosign.password` | build signing; admission policies trust `cosign.pub` |
| `promotion-gate-github` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | the platform GitHub App: per-run build tokens for one repository (clone + GitOps commit, [Git credentials](#git-credentials)), auto-build, promotion gate |
| `platform-ghcr` | `username`, `token` | Harbor GHCR proxy cache + replication; external registry type |
| `github-webhook` | `secret` | auto-build trigger `webhook` only: HMAC secret of the GitHub App webhook (addon argo-events) |

`task secrets` seeds `harbor` (random, policy-conformant), generates `cosign-platform` once with cosign from the
toolbox image (Docker, no host install; password only through the environment, key files removed on any exit), and
seeds `promotion-gate-github` from `GITHUB_GATE_APP_*` ([forking.md](forking.md#3-credentials) (c2)). Builds hold no
git token of their own. Build and promotion-gate runs in `workflows-*` read their
keys through `ClusterSecretStore/workflows` (`ClusterWorkflowPlane default` `secretStoreRef`), whose ServiceAccount
`eso-workflows` has a name-scoped `get` Role in `platform-secrets` for `workflowStore.keys` only (`cosign-platform`,
`harbor` or `registry.external.credentialsKey`, `promotion-gate`, `promotion-gate-github`);
`workflows-*` cannot use `ClusterSecretStore/platform`.

## Ports and DNS (local)

| Port (127.0.0.1) | k3d config | What |
|---|---|---|
| 9443 | `bootstrap/k3d-mgmt.yaml` | Harbor (Gateway `harbor`, TLS); CAPD nodes use the same port on the serverlb |

Names: `harbor.openchoreo.localhost`
(browser: loopback; mgmt pods: coredns-local; workload pods: coredns-local generic rule → serverlb; CAPD nodes:
`/etc/hosts`). Trust the CA in a browser/docker: `kubectl -n harbor get secret harbor-ca-bundle -o jsonpath='{.data.ca\.crt}' | base64 -d`.

## Resource budget (requests, mgmt)

| Component | CPU | Memory |
|---|---|---|
| Harbor core / jobservice / registry+ctl / portal | 50m / 20m / 30m / 10m | 128Mi / 64Mi / 96Mi / 32Mi |
| Harbor PostgreSQL / Valkey / Trivy | 25m / 10m / 50m | 128Mi / 32Mi / 192Mi |
| Harbor Gateway proxy (kgateway Envoy) | kgateway default | ~55Mi (measured after builds) |
| Argo Workflows controller / cluster-agent | 25m / 10m | 64Mi / 64Mi |
| Auto-build pass (`poll`: one pod a minute, a few seconds) | 10m | 32Mi (limit 96Mi) |
| **Steady state total** | **~240m** | **~0.85 GiB** (budget: 1.5 GiB) |
| Per build (peak, sequential steps) | 500m (BuildKit) | 768Mi BuildKit; checks 512Mi; scans 384Mi |

Storage (local-path): Harbor registry 20Gi (not enforced by local-path), DB 2Gi, Trivy 2Gi, job logs 1Gi, Redis 1Gi;
per run a 5Gi workspace PVC (deleted with the workflow).

## Open work

Before builds run untrusted code on a shared cloud mgmt cluster: dedicated build nodes
([#32](https://github.com/koorikla/platform/issues/32)), scoped workflow-plane agent RBAC
([#33](https://github.com/koorikla/platform/issues/33)), per-repository git credentials and branch protection for the
hand-off ([#34](https://github.com/koorikla/platform/issues/34)), per-project Harbor robots
([#35](https://github.com/koorikla/platform/issues/35)), digest-pinned images in `workflows-*`
([#36](https://github.com/koorikla/platform/issues/36)). BuildKit pulls base images
directly from upstream ([#38](https://github.com/koorikla/platform/issues/38)). Values not yet confirmed live:
[#40](https://github.com/koorikla/platform/issues/40).
