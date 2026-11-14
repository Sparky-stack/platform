# AGENTS.md

Context for every AI agent (Claude Code, Antigravity, Gemini CLI, Hermes) and human working on this repo.
Design and rationale: `docs/architecture.md`. Contracts below are mirrored from `docs/conventions.md` (keep both in sync).

## Invariants — do not break
1. **Cluster name == CAPI `Cluster` name == Argo CD cluster secret name == OpenChoreo `ClusterDataPlane` name ==
   `planeID` == agent client cert CN.**
2. Cluster facts live only in `installations/<inst>/clusters/<name>.yaml`. Labels flow from there to the CAPI `Cluster`
   and the Argo cluster secret. ApplicationSets select on labels; nothing hardcodes a cluster name.
3. Argo CD runs only on mgmt (push mode). Workload clusters run no Argo component; apps reach them via OpenChoreo.
4. CA private keys never leave mgmt. Workload clusters receive only their own client cert/key and public CAs, via CAPI
   `ClusterResourceSet` payloads templated by ESO.
5. Every ExternalSecret on mgmt uses `ClusterSecretStore/platform`; on workload clusters `ClusterSecretStore/default`.
   No secret value is ever committed. Secret keys are flat names (see table below).
6. Addons are wrapper charts in `addons/<addon>/` (upstream chart as dependency + optional extra templates). Config
   overlays (`installations/*/addons/`) contain only values, never templates.
7. Enable/disable files by extension (`*.yaml` ⇄ `*.yaml.disabled`), not by commenting blocks.
8. Everything after `make up` is GitOps. `bootstrap/` is the only imperative code; it installs exactly: k3d mgmt,
   the seed secrets (local backend only), Argo CD (same chart + values as GitOps), and the root Application.
9. Images fully qualified; versions pinned (charts in `Chart.yaml`, images via chart values). Renovate updates them.

## Labels and annotations
On the CAPI `Cluster` and the Argo CD cluster secret:

| Key | Values |
|---|---|
| `platform.koorikla.io/name` | cluster name |
| `platform.koorikla.io/role` | `mgmt` \| `workload` |
| `platform.koorikla.io/provider` | `docker` \| `aws` \| `hetzner` |
| `platform.koorikla.io/region` | free text (`local`, `eu-central-1`, `fsn1`) |
| `platform.koorikla.io/environment` | `mgmt`, `development`, `production`, … |
| `platform.koorikla.io/installation` | installation name (`local`) |
| `addons.platform.koorikla.io/<addon>` | `"true"` \| `"false"` — overrides the catalog default for this cluster |
| annotation `platform.koorikla.io/addons-revision` | git revision the cluster's addon Applications follow (default `HEAD`) |

## Names
| Thing | Name |
|---|---|
| CAPI namespace on mgmt | `fleet` |
| ClusterClasses (namespace `fleet`) | `k3s-docker`, `k3s-aws`, `k3s-hetzner` |
| Per-cluster agent CA / client cert secrets (ns `fleet`) | `<name>-agent-ca`, `<name>-agent-tls` |
| CRS payload secrets (ns `fleet`) | `<name>-openchoreo-agent` (per cluster), `openchoreo-gateway-ca` (shared) |
| On workload clusters, ns `openchoreo-data-plane` | Secret `cluster-agent-tls`, ConfigMap `cluster-gateway-ca` |
| OpenChoreo org namespace on mgmt | `default` (label `openchoreo.dev/control-plane: "true"`) |
| Argo CD AppProjects | `platform` (mgmt + addons), `fleet` (cluster charts), `tenant-<project>` |

Secret keys in the `platform` store (flat, backend-agnostic):

| Key | Properties | Used by |
|---|---|---|
| `platform-github` | `username`, `token` (or `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`) | Argo CD repo-creds for `https://github.com/koorikla` |
| `platform-ghcr` | `username`, `token` | node registry auth for `ghcr.io` |
| `capi-aws` | `AWS_B64ENCODED_CREDENTIALS` | CAPA |
| `capi-hetzner` | `hcloud` | CAPH (`HCloudCluster.spec.hetznerSecretRef`) |

## Layout and ownership
```
bootstrap/                      k3d config, bootstrap.sh (make up/down), seed secrets
charts/platform/                root chart: AppProjects, ApplicationSets (fleet, addons catalog, tenants), mgmt cluster secret
charts/cluster/                 one workload cluster: templates/capi-*.yaml, argocd-*.yaml, openchoreo-*.yaml
addons/<addon>/                 wrapper charts (+ values/role-*.yaml, values/provider-*.yaml)
installations/<inst>/           installation.yaml, clusters/, addons/, tenants/
docs/                           architecture.md, conventions.md, runbooks
hack/                           tests and helper scripts (task test); hack/lib/portable.sh
mise.toml, Taskfile.yml         pinned toolchain, cross-platform entrypoints (Makefile = shim)
```

## Working rules
- Local mgmt context is `k3d-platform-mgmt`. The homelab context `koorikla` runs other production workloads: never
  deploy there.
- `make test` must pass before pushing: helm lint + template every chart with every installation, kubeconform with CRD
  schemas, helm-unittest where present.
- Tooling is OS/arch-agnostic (docs/dev-environment.md): tools only via `mise.toml` (aqua backends, `task tools:lock`
  after a bump), entrypoints in `Taskfile.yml` (keep the Makefile shim in step), scripts bash 3.2 + GNU/BSD/MSYS
  portable (use `hack/lib/portable.sh`; `${arr[@]+"${arr[@]}"}` for maybe-empty arrays). New images must be
  multi-arch: `task images:audit`.
- Conventional commits (`feat(cluster): …`). `grep -rn VERIFY` lists values inferred but not yet confirmed live.

## Guardrails
- Never deploy to, or delete in, the homelab context `koorikla`. Only the k3d mgmt (`k3d-platform-mgmt`) and the CAPD
  clusters it creates are fair game.
- Never commit secret values; never print tokens. Seed secrets only via `make secrets`.
- No force-push to `main`. While the first boot is being proven, direct commits to `main` are allowed; afterwards: branch
  `issue-<num>-<slug>` → PR → squash merge.
- Before claiming something works, show live evidence (Argo app Synced/Healthy, `kubectl get clusters -n fleet`,
  `curl` of the app endpoint) — `make test` passing is necessary, not sufficient.
