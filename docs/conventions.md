# Conventions and contracts

Design and rationale: `architecture.md`. These are the rules every change must keep.

## Invariants — do not break
1. **Cluster name == CAPI `Cluster` name == Argo CD cluster secret name == OpenChoreo `ClusterDataPlane` name ==
   `planeID` == agent client cert CN.**
2. Cluster facts live only in `installations/<inst>/clusters/<name>.yaml`. Labels flow from there to the CAPI `Cluster`
   and the Argo cluster secret. ApplicationSets select on labels; nothing hardcodes a cluster name.
3. Argo CD runs only on mgmt (push mode). Workload clusters run no Argo component; apps reach them via OpenChoreo.
4. CA private keys never leave mgmt. Workload clusters receive only their own client cert/key and public CAs, via CAPI
   `ClusterResourceSet` payloads templated by ESO.
5. Every ExternalSecret on mgmt uses `ClusterSecretStore/platform` (its namespace must be in addon secret-stores
   `platformStore.namespaces`); on workload clusters `ClusterSecretStore/default`. Only exception: read-only stores
   that publish a **public CA certificate** (`ca.crt`) and nothing else: `mgmt-openchoreo` (cluster-gateway CA;
   namespace conditions), `mgmt-harbor` (registry CA; name-scoped GET of `harbor/harbor-ca-bundle`; `fleet`,
   `workflows-*`) and the namespaced `harbor/harbor-ca-source` (copies the registry CA cert into that bundle).
   Second exception, for a credential tenants must not reach: on workload clusters the external-dns Cloudflare token
   comes from `ClusterSecretStore/dns` (only while `dns.provider: cloudflare`; conditions: namespace `external-dns`
   only; its own backend location and identity that `default`, the tenants' `secretStoreRef`, cannot read).
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
| `platform.koorikla.io/cni` | `cilium` \| `flannel` — fleet file `cni` (mgmt: `flannel`); selects `values/cni-<cni>.yaml` |
| `addons.platform.koorikla.io/<addon>` | `"true"` \| `"false"` — overrides the catalog default for this cluster (`cilium` is derived from `cni`) |
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
| `platform-github` | `username`, `token` (or `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` with secret-stores `repoCreds.auth: githubApp`) | Argo CD repo-creds for `installation.githubOrg` (read-only) |
| `platform-github-app` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | git write access (GitOps hand-off, scaffolder; promotion PRs use `promotion-gate-github`); reserved, no consumer yet (docs/forking.md) |
| `platform-github-build` | `username`, `token` | in-cluster builds: clone + GitOps hand-off push, only to `buildWorkflows.git.allowedRepositoryPrefixes` (default `installation.githubOrg`/); fine-grained PAT, app repos only, Contents: Read and write (docs/build-plane.md) |
| `platform-ghcr` | `username`, `token` | node registry auth for `ghcr.io` |
| `capi-aws` | `AWS_B64ENCODED_CREDENTIALS` | CAPA |
| `capi-hetzner` | `hcloud` | CAPH (`HCloudCluster.spec.hetznerSecretRef`) |
| `harbor` | admin/robot/chart secrets (docs/build-plane.md) | addon harbor, build pushes (`builder-secret`), node pulls (`nodes-secret`) |
| `cosign-platform` | `cosign.key`, `cosign.pub`, `cosign.password` | in-cluster build signing (OpenChoreo workflow plane); `cosign.pub` is what `kyverno-policies` `imageVerification.platformKey.publicKey` must hold (installation value) |
| `falco-webhook` | `url`, `token` | falcosidekick escalation -> addon argo-events (also seeded to workload clusters) |
| `promotion-gate` | `client-secret` | ClusterWorkflow promotion-gate (Thunder client `openchoreo-promotion-gate`) |
| `promotion-gate-github` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | the promotion gate's own GitHub App (Contents, Pull requests, Commit statuses: write; app repos only); per-run token scoped to one repo (docs/promotion.md) |
| `external-dns-cloudflare` | `api-token` | addon external-dns, `dns.provider: cloudflare` (on workload clusters in store `dns`, never `default`; docs/dns.md). Route 53 has no key: IRSA / Pod Identity only |
| `openchoreo-ai` | `rca-llm-api-key`, `rca-oauth-client-secret`, `finops-llm-api-key`, `finops-oauth-client-secret`, `<provider>-api-key` | OpenChoreo AI agents, Thunder agent clients, addon agentgateway; only while switched on (docs/ai-agents.md) |

## Layout and ownership
```
bootstrap/                      k3d config, bootstrap.sh (make up/down), seed secrets
charts/platform/                root chart: AppProjects, ApplicationSets (fleet, addons catalog, tenants), mgmt cluster secret
charts/cluster/                 one workload cluster: templates/capi-*.yaml, argocd-*.yaml, openchoreo-*.yaml
addons/<addon>/                 wrapper charts (+ values/role-*.yaml, values/provider-*.yaml, values/cni-*.yaml)
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
  multi-arch: `task images:audit`. The only exceptions are listed, with an expiry, in `hack/image-audit.sh`
  `ARCH_EXCEPTIONS` (today: Harbor 2.15, amd64-only until 2.16; docs/build-plane.md).
- Conventional commits (`feat(cluster): …`). `grep -rn VERIFY` lists values inferred but not yet confirmed live.
