# platform

Cloud-agnostic Kubernetes platform built with **Cluster API** (k3s + CAPD/CAPA/CAPH), **Argo CD** (push-based GitOps), **External Secrets Operator**, and **OpenChoreo**.

See [docs/architecture.md](docs/architecture.md) for the design and [docs/conventions.md](docs/conventions.md) for repo invariants.

## Prerequisites

- `kubectl`, `helm` (with `helm-unittest` plugin for tests), `yq`, `kubeconform`
- Local installation (`INST=local`): `docker`, `k3d`, `gh` (authenticated with `read:packages` scope if pulling private GHCR images)

## Local quickstart

```bash
# Point repoURL at your fork if needed:
# make set-repo REPO=https://github.com/<you>/platform.git

make up       # Create k3d platform-mgmt (network: kind, ports 8080/8443), seed secrets, install Argo CD, apply root-app
make status   # Check CAPI clusters, Argo CD apps, ClusterDataPlanes, UI port-forward + admin password
make down     # Delete CAPD workload clusters gracefully, then delete k3d platform-mgmt
```

Individual bootstrap stages:

- `make secrets` — seed or refresh `platform-secrets` (`platform-github`, `platform-ghcr`, `openchoreo`) from `gh` CLI (preserves existing `openchoreo` secret keys)
- `make argocd` — install/upgrade Argo CD (`addons/argo-cd`) and apply `bootstrap/root-app.yaml`

## Cloud installations (AWS / Hetzner)

`installations/aws-example` and `installations/hetzner-example` target any existing management cluster in your current kubeconfig context:

```bash
make up INST=aws-example
# or
make up INST=hetzner-example
```

When `secrets.backend` is not `kubernetes`, `bootstrap.sh` skips k3d creation and local `platform-secrets` seeding, installs Argo CD with `addons/argo-cd/values.yaml`, optionally seeds the bootstrap repo secret from `GITHUB_USER`/`GITHUB_TOKEN` if set, and applies `root-app.yaml` pointing at `installations/<inst>/installation.yaml`.

## Adding clusters, addons, and tenants

- **Workload cluster**: add `installations/<inst>/clusters/<name>.yaml` (see `charts/cluster/values.yaml`). `ApplicationSet/fleet` deploys `charts/cluster` to provision the CAPI `Cluster`, register the Argo CD cluster secret via `ExternalSecret`, and register the OpenChoreo `ClusterDataPlane` + `Environment`.
- **Addon**: add `addons/<name>/` (wrapper `Chart.yaml` + `values.yaml` + optional `values/role-*.yaml`, `values/provider-*.yaml`) and register it in `charts/platform/values.yaml`.
- **Tenant**: add `installations/<inst>/tenants/<project>.yaml` (reconciled by `ApplicationSet/tenants`).

## Offline validation

```bash
make lint     # Build chart deps, helm lint all charts, validate YAML + shellcheck
make test     # Full offline validation: helm template across all installations/clusters, kubeconform -strict, helm unittest, contract tests
```
