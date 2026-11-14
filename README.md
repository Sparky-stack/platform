# platform

<p align="center"><img src="docs/images/hero.png" alt="Clusters on several clouds, connected to one management hub" width="100%"></p>

A cloud-agnostic Kubernetes platform: **Cluster API** creates and lifecycles k3s clusters on Docker, AWS or Hetzner,
**Argo CD** installs the platform add-ons on all of them from one catalog, **External Secrets Operator** moves every
credential, and **OpenChoreo** is the developer platform on top (projects, components, environments, promotion).
Runtime: Cilium, Istio ambient, kgateway, Kyverno, Falco, external-dns (Route 53 / Cloudflare, opt-in); telemetry to
OpenChoreo's observability plane (Datadog-ready), with OpenChoreo's RCA and FinOps AI agents ready to switch on.

<img src="docs/diagrams/overview.svg" alt="Architecture overview: repos, management cluster, workload clusters" width="100%">

| Read | For |
|---|---|
| [docs/architecture.md](docs/architecture.md) | design and decisions (why push GitOps, trust model, secrets, installations, tenants) |
| [docs/conventions.md](docs/conventions.md) / [AGENTS.md](AGENTS.md) | invariants, labels, names - the contracts every change keeps |
| [docs/diagrams/](docs/diagrams/README.md) | cluster lifecycle, trust model, delivery, runtime security |
| [docs/providers.md](docs/providers.md), [docs/openchoreo.md](docs/openchoreo.md), [docs/networking.md](docs/networking.md), [docs/observability.md](docs/observability.md), [docs/dns.md](docs/dns.md), [docs/ai-agents.md](docs/ai-agents.md) | per-area details |
| [docs/dev-environment.md](docs/dev-environment.md) | toolchain (mise + Task) on macOS / Linux / Windows, amd64 / arm64; devcontainer |
| [docs/forking.md](docs/forking.md) | run it from your own fork: `set-repo`, least-privilege credentials, boot, troubleshooting |

Related repos: [koorikla/hello-world](https://github.com/koorikla/hello-world) (example app), [koorikla/ci](https://github.com/koorikla/ci) (reusable CI workflows).

## Status and roadmap

Solid boxes in the diagrams are built on `main`; dashed ones are planned.

| State | What |
|---|---|
| **Running locally** | k3d mgmt + two CAPD clusters (`dev1`, `prod1`) from fleet files; Argo CD push mode with the addon catalog; ESO stores and the per-cluster OpenChoreo agent identity; OpenChoreo control plane, Thunder, Backstage, data planes; hello-world released to `development`; OpenChoreo observability plane (OpenSearch, Prometheus, observer) with workload telemetry (OTel collector, Fluent Bit); Falco + falcosidekick + Talon; Cilium (`dev1`; CNI chosen at cluster birth) and flannel (`prod1`), Istio ambient with OpenChoreo app namespaces auto-enrolled by Kyverno, Kyverno Pod Security baseline (Audit) |
| **Rendered, not booted** | AWS (CAPA) and Hetzner (CAPH) installations, AWS Secrets Manager / Vault secret backends; external-dns (Route 53 / Cloudflare chosen per installation, opt-in per cluster); OpenChoreo RCA (SRE) and FinOps agents + OpenCost FinOps module + agentgateway, built and switched off until LLM keys exist |
| **On main, first boot pending** | OpenChoreo workflow plane as the primary build path (per-stack ClusterWorkflows running koorikla/ci scripts, rootless BuildKit, multi-arch, cosign-signed, GitOps hand-off) + Harbor (registry, proxy caches, k3s node mirrors) - [docs/build-plane.md](docs/build-plane.md) |
| **In progress** | [koorikla/ci](https://github.com/koorikla/ci) reusable workflows (Go, Next.js, Elixir, Ruby, Helm, Crossplane), multi-arch and cosign-signed; OS/CPU-agnostic tooling (mise + Task, devcontainer) |
| **Next** | Crossplane v2 with package promotion gated by Argo CD; SSO (Okta / Google via Thunder, Argo CD via Dex, apiserver OIDC) + Backstage scaffolder; Argo Events escalation for Falco; Datadog exporter |

## Prerequisites

- [mise](https://mise.jdx.dev) and Docker (Docker Desktop, OrbStack or Colima on macOS/Windows; Docker Engine on Linux).
  `mise install` installs every other tool at the version pinned in [`mise.toml`](mise.toml) (kubectl, helm +
  helm-unittest, k3d, clusterctl, yq, kubeconform, gh, task, ...). Works on macOS, Linux and Windows (WSL2 or Git Bash),
  amd64 and arm64; or open the repo in the devcontainer / Codespaces. Details: [docs/dev-environment.md](docs/dev-environment.md).
- GitHub credentials only if your fork or images are private: a GitHub App (preferred) or fine-grained PAT via env vars,
  or your `gh auth login` as a local fallback ([docs/forking.md](docs/forking.md#3-credentials)).

## Local quickstart

```bash
mise install  # once: the pinned toolchain (`task doctor` checks it)

task up       # Create k3d platform-mgmt (network: kind, loopback ports 8080/8443/9443/11080/11085), seed secrets, install Argo CD, apply root-app
task status   # Check CAPI clusters, Argo CD apps, ClusterDataPlanes, UI port-forward + admin password
task down     # Delete CAPD workload clusters gracefully, then delete k3d platform-mgmt
```

## Run it from your own fork

Argo CD reads everything from one git repo, so a fork runs as soon as the GitOps root points at it:

```bash
gh repo fork koorikla/platform --clone && cd platform && mise install && task doctor
task set-repo REPO=https://github.com/<you>/platform.git   # repoURL, githubOrg, tenant app repos; idempotent
git commit -am "chore: point GitOps at my fork" && git push
task up
```

A public fork needs no credentials. Private fork or images, the push credentials the platform will need, and the
labels you should *not* rename: [docs/forking.md](docs/forking.md).

`task --list` shows every entrypoint; `make <target>` still works (the Makefile is a shim for `task <target>`).

Individual bootstrap stages:

- `task secrets` — seed or refresh `platform-secrets` (`platform-github`, `platform-ghcr`, `platform-github-app`, `platform-github-build`, `openchoreo`, `harbor`, `cosign-platform`) from `GITHUB_APP_*` / `PLATFORM_GITHUB_TOKEN` / `PLATFORM_GITHUB_BUILD_TOKEN` / `GHCR_*` env vars, falling back to the `gh` CLI (preserves existing `openchoreo` secret keys; [docs/forking.md](docs/forking.md#seeding-locally-task-secrets))
- `task argocd` — install/upgrade Argo CD (`addons/argo-cd`) and apply `bootstrap/root-app.yaml`
- `task ui` — Argo CD UI on http://localhost:8081; `task kubeconfig CLUSTER=dev1` — host-usable kubeconfig of a CAPD cluster

## Cloud installations (AWS / Hetzner)

`installations/aws-example` and `installations/hetzner-example` target any existing management cluster in your current kubeconfig context:

```bash
task up INST=aws-example
# or
task up INST=hetzner-example
```

When `secrets.backend` is not `kubernetes`, `bootstrap.sh` skips k3d creation and local `platform-secrets` seeding, installs Argo CD with `addons/argo-cd/values.yaml`, optionally seeds the bootstrap repo secret from `GITHUB_APP_*` or `PLATFORM_GITHUB_TOKEN` if set, and applies `root-app.yaml` pointing at `installations/<inst>/installation.yaml`.

## Adding clusters, addons, and tenants

- **Workload cluster**: add `installations/<inst>/clusters/<name>.yaml` (see `charts/cluster/values.yaml`). `ApplicationSet/fleet` deploys `charts/cluster` to provision the CAPI `Cluster`, register the Argo CD cluster secret via `ExternalSecret`, and register the OpenChoreo `ClusterDataPlane` + `Environment`.
- **Addon**: add `addons/<name>/` (wrapper `Chart.yaml` + `values.yaml` + optional `values/role-*.yaml`, `values/provider-*.yaml`) and register it in `charts/platform/values.yaml`.
- **Tenant**: add `installations/<inst>/tenants/<project>.yaml` (reconciled by `ApplicationSet/tenants`).

## Offline validation

```bash
task lint          # Build chart deps, helm lint all charts, validate YAML, shellcheck, actionlint
task test          # Full offline validation: helm template across all installations/clusters, kubeconform -strict, helm unittest, contract tests
task images:audit  # Every image of the installation published for linux/amd64 + linux/arm64
```
