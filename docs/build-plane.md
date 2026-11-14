# Build plane: OpenChoreo workflow plane + Harbor

In-cluster builds are the **primary, CI-provider-agnostic build path**: a Component names a ClusterWorkflow, a
WorkflowRun (Backstage "Build", `occ`, or an autoBuild webhook) runs it on the OpenChoreo workflow plane, the image
lands in Harbor signed and scanned, and the new image ref is **committed to the app repo** so Argo CD deploys it. GitHub
Actions ([koorikla/ci](https://github.com/koorikla/ci) reusable workflows) remain an optional path that runs the same
scripts. Teams choose per Component.

```
WorkflowRun (Backstage / occ / webhook)            mgmt
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
`ghcr.io/koorikla/ci-toolbox:v1@sha256:c557…c608` (multi-arch, cosign-signed) for checkout, scans, SBOM, signing and
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

Trigger a build: Backstage → component → **Build** (WorkflowRun with live task status and logs), `occ`, or a
`WorkflowRun` object. `autoBuild: true` additionally builds on every push once a GitHub webhook reaches openchoreo-api
(webhook secret in Secret `openchoreo-control-plane/git-webhook-secrets`; GitHub cannot reach a laptop). OpenChoreo's webhook matcher treats appPath `.` as "every change", so the hand-off commit would re-trigger the
build: `checkout` skips commits that only touch the GitOps directory (loop guard), and the commit message carries
`[skip ci]` for the GitHub Actions path.

### GitOps hand-off

`gitops` clones the source repo at the built branch, sets `spec.container.image` (`<repo>:<short sha>@sha256:<digest>`)
and `spec.source.commit` in `deploy/openchoreo/workload.yaml` with yq, commits as `OpenChoreo build`, and pushes with
rebase retries. Credentials: key `platform-github-build` (fine-grained PAT, app repos only, Contents: Read and write;
not Argo CD's read-only `platform-github`). Only an OpenChoreo `Workload` at `deploy/openchoreo/<name>.yaml` is ever
rewritten (schema pattern on `gitops.workloadPath`, plus a script check: no symlink on the path, `kind: Workload`).
Argo CD (Application
`<project>-<app>`) syncs; `autoDeploy` cuts the ComponentRelease and binds development; staging/production stay
promotion-by-PR (docs/openchoreo.md "How GitOps promotion works").

### Multi-arch

`platforms` defaults to `linux/amd64,linux/arm64`. Dockerfiles that cross-compile (`FROM --platform=$BUILDPLATFORM`,
like hello-world's Go build) need no emulation. `RUN` steps of a foreign architecture need QEMU binfmt handlers on the
build node's kernel (present on the dev host; install with `tonistiigi/binfmt` where missing - it changes the host
kernel, so it is not done by the platform). Narrow `platforms` per Component to build only the node's architecture.

### Security posture of build pods

- **Repository allowlist.** Builds clone from and push to only the installation's allowed repository prefixes
  (`buildWorkflows.git.allowedRepositoryPrefixes`, default `installation.githubOrg` + `/`, each `https://<host>/<owner>/`).
  Three layers: the ClusterWorkflow schema `pattern` on `repository.url` (one repo name after a prefix); `BUILD_GUARDS`
  in the checkout and gitops scripts (same check, git config only from the environment, `protocol.allow=never` except
  https); and git's credential helper registered per prefix (`credential.<prefix>.helper`, no global `GIT_ASKPASS`), so
  the token never answers a 401 from another host or owner, redirects included. Branch, commit and path parameters
  have patterns against option injection (`--upload-pack=…`) and traversal; the build step refuses a context or
  Dockerfile that resolves outside the checkout (that pod also mounts the registry push credentials).
  `hack/tests/test_build_guards.sh` exercises all of it with real `git credential fill` (negative cases first).
  Residual: any build may use any repo under an allowed owner (a tenant can rebuild another tenant's repo at an old
  commit); per-repo GitHub App installation tokens (`platform-github-app`) close that (deferred).
- Pod Security `restricted` for every step (non-root 65532, RuntimeDefault seccomp, no privilege escalation, all
  capabilities dropped, read-only root where the tool allows) **except `build`**: rootless BuildKit runs as uid 1000,
  no privilege escalation, no added capabilities, but needs `seccompProfile`/`appArmorProfile: Unconfined` to create user
  namespaces (rootlesskit). No privileged container, no Docker daemon, no DinD. Kyverno's Pod Security policies (Audit)
  report that pod.
- **No ServiceAccount token in run containers**: both ClusterWorkflowTemplates (and the ClusterWorkflows' run
  templates) set `automountServiceAccountToken: false` + `executor.serviceAccountName: workflow-sa`, so only Argo's
  init/wait containers can write `workflowtaskresults`. Tenant check code cannot rewrite another run's outputs (e.g. the
  digest that `sign` signs).
- **Default-deny network** for `workflows-<org ns>` (addon openchoreo-workflow-plane `runNetworkPolicy`; the addon
  also renders the namespace so the policy exists before the first run): no ingress; egress only to DNS, the Harbor
  Gateway proxy pods (port 9443), the API server (Argo's executor) and TCP 80/443 outside private ranges. Tenant check
  and `RUN` code cannot reach argocd-repo-server, harbor-core over HTTP, webhooks or other mgmt Services.
- Supply-chain steps (`scan-fs`, `scan-image`, `sbom`, `sign`) run with `HOME=/tmp` and `TRIVY_CACHE_DIR=/tmp/trivy`
  (per-pod emptyDir), not on the run volume the tenant `check` step writes, so tenant code cannot plant tool config
  (`~/.docker`, `~/.sigstore`, Trivy DB). Cost: each scan step downloads the Trivy DB.
- Per-run Secrets are ExternalSecrets the ClusterWorkflow renders into `workflows-<ns>` for each run (owned by the
  run, deleted with it): git credentials, registry push credentials, registry CA (public), cosign key.
- Signing: see "Signing" below.

### Signing (deliberate deviation from keyless)

AGENTS.md asks for keyless Sigstore signing. In-cluster builds use a **static platform key** instead: public Fulcio
issues certificates only for OIDC issuers it trusts, and a local k3d (or private EKS/Hetzner) workload identity is not
one of them. The GitHub Actions path stays keyless.

- Key pair `cosign-platform` (private key encrypted with `cosign.password`; only in the secret backend and the signing
  pod; `task secrets` generates it once). Cloud installations should use a KMS key reached through workload identity
  instead of a key file (`COSIGN_KEY=awskms://…` with EKS Pod Identity / IRSA, GCP KMS with Workload Identity): no key
  material in the secret backend at all. Tracked with the `gates` work.
- **No public transparency log by default**: `buildWorkflows.signing.transparencyLog: false` makes the sign steps use a
  cosign v3 signing config without Rekor/TSA (a shim adds `--signing-config` to `cosign sign|attest` until koorikla/ci
  `sign-image.sh` grows a switch), so private repo names and digests never reach public Rekor and signing needs no
  egress to Sigstore. Set it `true` per installation (`installations/<inst>/addons/openchoreo-platform/values.yaml`) to
  upload to public Rekor.
- Verify: `cosign verify --key cosign.pub --insecure-ignore-tlog=true <image>@sha256:…` (and `verify-attestation --type
  vuln|spdxjson`). `cosign.pub`: `kubectl -n platform-secrets get secret cosign-platform -o jsonpath='{.data.cosign\.pub}' | base64 -d`.
- Not yet enforced at admission: a Kyverno `ImageValidatingPolicy` for `<registry>/apps/*` trusting `cosign.pub`
  (ignoring the tlog) is the `gates` work; until then "signed" is evidence, not a gate.

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
| registries | one endpoint per upstream; `ghcr.io` with `platform-ghcr` credentials |
| replication | `ghcr-koorikla`: pull `koorikla/**` from GHCR into `apps-ghcr` every 6h |
| robots | `robot$builder` (push/pull `apps`, pull the rest), `robot$nodes` (pull all); secrets set from the secret backend |
| system | CVE allowlist empty |

Content trust (`enable_content_trust_cosign` on `apps`) is **off** until verified that Harbor 2.15 counts cosign v3
Sigstore-bundle referrers as signatures; enabling it blocks every pull without one (VERIFY). Every chart secret
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
breaking them. Bootstrap data is rendered once per Machine: changes reach new machines. Applying this branch changes
the ClusterClass patches (host alias, CA file, patch order), so CAPI **rolls every CAPD machine** of dev1 and prod1.

The same change fixes a bug on main: `cni-flannel` replaced the control plane's whole `files` list after
`registryAuth` appended `registries.yaml`, so flannel clusters (prod1) booted their control plane without GHCR auth
(seen live: `KThreesControlPlane prod1` has only the CNI drop-in). `cni-flannel` now runs before every files patch.

### Images and architectures

Harbor 2.15 publishes linux/amd64 images only (arm64 arrives as separate `-arm64` tags in 2.16, not as a manifest
list). This is a **deliberate, expiring exception** to the multi-arch rule: the 8 Harbor images (`goharbor/harbor-core`,
`harbor-db`, `harbor-jobservice`, `harbor-portal`, `harbor-registryctl`, `registry-photon`, `trivy-adapter-photon`,
`valkey-photon`, tag prefix `v2.15.`) are listed in `hack/image-audit.sh` `ARCH_EXCEPTIONS` with an expiry
(2027-03-31), so `task images:audit` stays green and reports them as `EXCEPTION`. A Harbor bump or the expiry date
drops the exception and the audit fails again; remove the list at the Harbor 2.16 bump (arm64 tags).
`hack/tests/test_image_audit.sh` pins the list to exactly those images. On arm64 hosts use `registry.type: external`.
Everything else added here (BuildKit, toolbox, Argo Workflows, cluster-agent, toolchains, Python, PostgreSQL) is
multi-arch and pinned by digest.

## Secrets (ClusterSecretStore `platform`)

| Key | Properties | Used by |
|---|---|---|
| `harbor` | `admin-password`, `secret-key` (16), `core-secret`, `csrf-key` (32), `jobservice-secret`, `registry-http-secret`, `registry-password`, `database-password`, `builder-secret`, `nodes-secret` | addon harbor; builds (`builder-secret`); nodes (`nodes-secret`) |
| `cosign-platform` | `cosign.key` (encrypted), `cosign.pub`, `cosign.password` | build signing; admission policies trust `cosign.pub` |
| `platform-github-build` | `username`, `token` (fine-grained PAT, app repos only, Contents: Read and write) | clone + GitOps commit, sent only to the allowed repository prefixes |
| `platform-ghcr` | `username`, `token` | Harbor GHCR proxy cache + replication; external registry type |

`task secrets` seeds `harbor` (random, policy-conformant), generates `cosign-platform` once with cosign from the
toolbox image (Docker, no host install; password only through the environment, key files removed on any exit), and
seeds `platform-github-build` from `PLATFORM_GITHUB_BUILD_TOKEN` (local fallback: the `gh` CLI token, with a warning;
Argo CD's read-only `platform-github` is never reused).

## Ports and DNS (local)

| Port (127.0.0.1) | k3d config | What |
|---|---|---|
| 9443 | `bootstrap/k3d-mgmt.yaml` | Harbor (Gateway `harbor`, TLS); CAPD nodes use the same port on the serverlb |

Live cluster: `k3d cluster edit platform-mgmt --port-add "127.0.0.1:9443:9443@loadbalancer"`. Names: `harbor.openchoreo.localhost`
(browser: loopback; mgmt pods: coredns-local; workload pods: coredns-local generic rule → serverlb; CAPD nodes:
`/etc/hosts`). Trust the CA in a browser/docker: `kubectl -n harbor get secret harbor-ca-bundle -o jsonpath='{.data.ca\.crt}' | base64 -d`.

## Resource budget (requests, mgmt)

| Component | CPU | Memory |
|---|---|---|
| Harbor core / jobservice / registry+ctl / portal | 50m / 20m / 30m / 10m | 128Mi / 64Mi / 96Mi / 32Mi |
| Harbor PostgreSQL / Valkey / Trivy | 25m / 10m / 50m | 128Mi / 32Mi / 192Mi |
| Harbor Gateway proxy (kgateway Envoy) | kgateway default | ~64Mi (VERIFY) |
| Argo Workflows controller / cluster-agent | 25m / 10m | 64Mi / 64Mi |
| **Steady state total** | **~240m** | **~0.85 GiB** (budget: 1.5 GiB) |
| Per build (peak, sequential steps) | 500m (BuildKit) | 768Mi BuildKit; checks 512Mi; scans 384Mi |

Storage (local-path): Harbor registry 20Gi (not enforced by local-path), DB 2Gi, Trivy 2Gi, job logs 1Gi, Redis 1Gi;
per run a 5Gi workspace PVC (deleted with the workflow).

## Deferred hardening (tracked)

Accepted for the local installation, required before builds run untrusted code on a shared cloud mgmt cluster:

- **Dedicated build node or cluster.** `build` runs rootless BuildKit with seccomp/AppArmor `Unconfined` on the node
  that also holds the CA keys, `platform-secrets` and Argo CD. Cloud installations should move the workflow plane to a
  tainted build node pool or its own cluster (OpenChoreo supports a remote `ClusterWorkflowPlane`), and try a Localhost
  seccomp profile allowing only what rootlesskit needs instead of `Unconfined`.
- **Scoped cluster-agent RBAC.** The upstream workflow-plane agent ClusterRole is effectively cluster-admin (`*` on
  secrets, pods, namespaces, ClusterSecretStores, roles/rolebindings incl. bind/escalate). Target:
  `clusterAgent.rbac.create: false` + a platform role limited to `workflows-*`, argoproj.io and externalsecrets, no
  ClusterSecretStores, no RBAC escalation. Needs the agent's exact API usage per OpenChoreo release first.
- **Per-repository git credentials.** `platform-github-build` is one PAT for every allowed repository: a build may clone
  or rebuild another tenant's repo under the same owner. Next step: `platform-github-app` installation tokens minted
  per run by ESO's `GithubAccessToken` generator, scoped to the Component's repository.
- **Per-project Harbor robots.** One robot `builder` pushes to all of `apps`; per-project robots (`apps/<project>/*`)
  would contain a compromised build.
- **Admission.** Kyverno `ImageValidatingPolicy` for `<registry>/apps/*` (platform `cosign.pub`, ignore tlog) and a
  rule restricting images in `workflows-*` to digest-pinned refs (`gates` work).
- **GitOps push to the branch head.** The hand-off commits straight to the built branch (development autoDeploy); with
  the GitHub App it should honour branch protection (PR or a ruleset bypass for the App only).

## Known limitations and VERIFY

`grep -rn VERIFY addons/harbor addons/openchoreo-workflow-plane addons/openchoreo-platform/templates charts/cluster/templates/capi-registries.yaml`.

- OpenChoreo CEL renders object/array parameters (`checks.env`, `buildArgs`) into Argo parameter values as JSON (Argo's
  `AnyString`); upstream relies on the same for `buildArgs`.
- Harbor GHCR replication with `koorikla/**`: GHCR has no catalog API; the adapter lists packages via the GitHub API.
- kgateway TrafficPolicy timeouts on the Harbor route (large layers); Gateway Service name `harbor`.
- Harbor internal PostgreSQL password via `extraEnvVars` override + `database.external.existingSecret` for core.
- The tlog-free signing config is injected with a cosign shim (koorikla/ci `sign-image.sh` has no switch yet).
- BuildKit pulls base images directly from upstream (no Harbor mirror for build pulls yet).
- Builds on the dev host rely on its QEMU binfmt handlers for foreign-arch `RUN` steps.
