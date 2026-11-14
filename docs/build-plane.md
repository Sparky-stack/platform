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
| mgmt | (OpenChoreo) | workflows-default | one Argo Workflow + pods per WorkflowRun, per-run ExternalSecrets; namespace, ServiceAccount `workflow-sa` and Role created by the WorkflowRun controller |
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
rebase retries. Credentials: key `platform-github` (needs `contents: write` on the app repos). Argo CD (Application
`<project>-<app>`) syncs; `autoDeploy` cuts the ComponentRelease and binds development; staging/production stay
promotion-by-PR (docs/openchoreo.md "How GitOps promotion works").

### Multi-arch

`platforms` defaults to `linux/amd64,linux/arm64`. Dockerfiles that cross-compile (`FROM --platform=$BUILDPLATFORM`,
like hello-world's Go build) need no emulation. `RUN` steps of a foreign architecture need QEMU binfmt handlers on the
build node's kernel (present on the dev host; install with `tonistiigi/binfmt` where missing - it changes the host
kernel, so it is not done by the platform). Narrow `platforms` per Component to build only the node's architecture.

### Security posture of build pods

- Pod Security `restricted` for every step (non-root 65532, RuntimeDefault seccomp, no privilege escalation, all
  capabilities dropped, read-only root where the tool allows) **except `build`**: rootless BuildKit runs as uid 1000,
  no privilege escalation, no added capabilities, but needs `seccompProfile`/`appArmorProfile: Unconfined` to create user
  namespaces (rootlesskit). No privileged container, no Docker daemon, no DinD. Kyverno's Pod Security policies (Audit)
  report that pod.
- Per-run Secrets are ExternalSecrets the ClusterWorkflow renders into `workflows-<ns>` for each run (owned by the
  run, deleted with it): git credentials, registry push credentials, registry CA (public), cosign key.
- Signing: platform key pair `cosign-platform` (private key encrypted, only in the secret backend and the signing pod).
  The admission side (keyless for the GitHub path, platform public key for in-cluster builds) is the `gates` work. In
  cloud installations use a KMS key reached with workload identity (`COSIGN_KEY=awskms://…`) instead of a key file.
  cosign v3 records key-based signatures in the public Rekor log by default (digests become public). VERIFY

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

TLS terminates at the Gateway with `harbor-tls`, issued by `ClusterIssuer harbor-ca`. The CA key stays in ns
`cert-manager` on mgmt. Its **public** certificate is published through Secret `harbor/harbor-ca-bundle` (a throwaway
leaf; only `ca.crt` is read) and `ClusterSecretStore mgmt-harbor`, whose ServiceAccount may `get` exactly that Secret
(name-scoped RBAC) and which only namespaces `fleet` and `workflows-*` can use. Nodes get it as
`/etc/rancher/k3s/registry-ca.crt` (`registries.yaml` `tls.ca_file`), build pods as `<run>-registry-ca`.

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
list), so `task images:audit` flags the Harbor images. On arm64 hosts use `registry.type: external`. Everything else
added here (BuildKit, toolbox, Argo Workflows, cluster-agent, toolchains, Python, PostgreSQL) is multi-arch and pinned
by digest.

## Secrets (ClusterSecretStore `platform`)

| Key | Properties | Used by |
|---|---|---|
| `harbor` | `admin-password`, `secret-key` (16), `core-secret`, `csrf-key` (32), `jobservice-secret`, `registry-http-secret`, `registry-password`, `database-password`, `builder-secret`, `nodes-secret` | addon harbor; builds (`builder-secret`); nodes (`nodes-secret`) |
| `cosign-platform` | `cosign.key` (encrypted), `cosign.pub`, `cosign.password` | build signing; admission policies trust `cosign.pub` |
| `platform-github` | `username`, `token` (`contents: write` on app repos) | clone + GitOps commit |
| `platform-ghcr` | `username`, `token` | Harbor GHCR proxy cache + replication; external registry type |

`task secrets` seeds `harbor` (random, policy-conformant) and generates `cosign-platform` once with cosign from the
toolbox image (Docker, no host install).

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

## Known limitations and VERIFY

`grep -rn VERIFY addons/harbor addons/openchoreo-workflow-plane addons/openchoreo-platform/templates charts/cluster/templates/capi-registries.yaml`.

- OpenChoreo CEL renders object/array parameters (`checks.env`, `buildArgs`) into Argo parameter values as JSON (Argo's
  `AnyString`); upstream relies on the same for `buildArgs`.
- Harbor GHCR replication with `koorikla/**`: GHCR has no catalog API; the adapter lists packages via the GitHub API.
- kgateway TrafficPolicy timeouts on the Harbor route (large layers); Gateway Service name `harbor`.
- Harbor internal PostgreSQL password via `extraEnvVars` override + `database.external.existingSecret` for core.
- cosign v3 key-based signing uploads to public Rekor (koorikla/ci `sign-image.sh` has no tlog switch yet).
- BuildKit pulls base images directly from upstream (no Harbor mirror for build pulls yet).
- Builds on the dev host rely on its QEMU binfmt handlers for foreign-arch `RUN` steps.
