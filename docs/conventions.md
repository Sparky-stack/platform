# Conventions and contracts

The rules every change keeps. Design and reasons: [architecture.md](architecture.md).

## Invariants
1. **Cluster name == CAPI `Cluster` name == Argo CD cluster secret name == OpenChoreo `ClusterDataPlane` name ==
   `planeID` == agent client cert CN.**
2. Cluster facts live only in `installations/<inst>/clusters/<name>.yaml`. Labels flow from there to the CAPI `Cluster`
   and the Argo CD cluster secret. ApplicationSets select on labels; nothing hardcodes a cluster name.
3. Argo CD runs only on mgmt (push mode). Workload clusters run no Argo component; apps reach them via OpenChoreo.
4. CA private keys never leave mgmt. Workload clusters receive only their own client cert/key and public CAs, via CAPI
   `ClusterResourceSet` payloads templated by ESO. The Istio mesh CA is OpenBao on mgmt (keys generated inside OpenBao,
   never exported); mesh members obtain certificates through istio-csr (docs/multicluster.md "Mesh CA (OpenBao)").
5. Every ExternalSecret on mgmt uses `ClusterSecretStore/platform` (its namespace must be in addon secret-stores
   `platformStore.namespaces`); on workload clusters `ClusterSecretStore/default`. Only exception: read-only stores
   that publish a **public CA certificate** (`ca.crt`) and nothing else: `mgmt-openchoreo` (cluster-gateway CA;
   namespace conditions), `mgmt-harbor` (registry CA; name-scoped GET of `harbor/harbor-ca-bundle`; `fleet`,
   `workflows-*`) and the namespaced `harbor/harbor-ca-source` (copies the registry CA cert into that bundle);
   `mgmt-openbao` (OpenBao CA + mesh group roots; name-scoped GET of `openbao/openbao-ca-bundle`; `fleet`) and the
   namespaced `openbao/openbao-ca-source` and `openbao/openbao-pki-public` (fill that bundle; the latter reads only
   `pki-mesh-*-root/cert/ca` from OpenBao).
   Second exception, for a credential tenants must not reach: on workload clusters the external-dns Cloudflare token
   comes from `ClusterSecretStore/dns` (only while `dns.provider: cloudflare`; conditions: namespace `external-dns`
   only; its own backend location and identity that `default`, the tenants' `secretStoreRef`, cannot read).
   Third exception, for workflow run namespaces shared with tenant build steps: on mgmt `ClusterWorkflowPlane default`
   points at `ClusterSecretStore/workflows` (conditions: `workflows-*` only; on the kubernetes backend a name-scoped
   `get` Role in `platform-secrets` limited by `resourceNames` to `workflowStore.keys` — `platform-github-build`,
   `cosign-platform`, `harbor` or `registry.external.credentialsKey`, `promotion-gate`, `promotion-gate-github`; on
   AWS/Vault a dedicated identity), so `workflows-*` never reads the full `platform` store.
   No secret value is ever committed. Secret keys are flat names (see table below).
6. Addons are wrapper charts in `addons/<addon>/` (upstream chart as dependency + optional extra templates). Config
   overlays (`installations/*/addons/`) contain only values, never templates.
7. Enable/disable files by extension (`*.yaml` ⇄ `*.yaml.disabled`), not by commenting blocks.
8. Everything after `task up` is GitOps. `bootstrap/` is the only imperative code; it installs exactly: k3d mgmt,
   the seed secrets (local backend only), Argo CD (same chart + values as GitOps), and the root Application.
9. Images fully qualified and pinned by multi-arch index digest (`<host>/<path>:<tag>@sha256:…`); versions pinned
   (charts in `Chart.yaml`, images via chart values). Renovate updates them. Contract: `hack/tests/test_image_pins.sh`
   ([build-plane.md](build-plane.md#images-and-architectures)).

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
| `addons.platform.koorikla.io/<addon>` | `"true"` \| `"false"` — overrides the catalog default for this cluster (`cilium` is derived from `cni`, `istio-eastwest` and `istio-csr` from `mesh.group`) |
| `mesh.platform.koorikla.io/group`, `.../network` | fleet file `mesh.group` (opt-in multicluster); network = cluster name; also sets `addons.platform.koorikla.io/istio-eastwest` and `.../istio-csr` (docs/multicluster.md) |
| annotation `platform.koorikla.io/addons-revision` | git revision the cluster's addon Applications follow (default `HEAD`) |

The label keys are an API between CAPI clusters, cluster secrets and ApplicationSets, not an org name: forks keep them.

On a PersistentVolumeClaim, annotation `platform.koorikla.io/delete-protection: enabled` means a ValidatingAdmissionPolicy
of the owning addon denies its deletion; every PVC that Argo CD runs as a hook must carry it (with `hook-failed` as its
only delete policy). Thunder: [openchoreo.md](openchoreo.md#argo-cd-requirements).

## Names
| Thing | Name |
|---|---|
| CAPI namespace on mgmt | `fleet` |
| ClusterClasses (namespace `fleet`) | `k3s-docker`, `k3s-aws`, `k3s-hetzner` |
| Per-cluster agent CA / client cert secrets (ns `fleet`) | `<name>-agent-ca`, `<name>-agent-tls` |
| CRS payload secrets (ns `fleet`) | `<name>-openchoreo-agent` (per cluster), `openchoreo-gateway-ca` (shared) |
| On workload clusters, ns `openchoreo-data-plane` | Secret `cluster-agent-tls`, ConfigMap `cluster-gateway-ca` |
| Mesh CA / remote secrets (opt-in) | ns `openbao`: OpenBao mounts `pki-mesh-<group>-root`, `pki-mesh-<group>-int`, role `<name>`, auth `mesh-<name>`, identity entity `mesh-<name>` (static policy `mesh-member`); ns `fleet`: `<name>-mesh-openbao`, `<name>-mesh-reader`, Issuer `<name>-client-ca`; CRS payloads `<name>-mesh-trust` (+ ConfigMap `<name>-mesh-oidc`), `<name>-mesh-remote-secret` |
| On mesh members, ns `istio-system` | Secrets `openbao-ca`, `mesh-root-ca` (public), Issuer `openbao-mesh`, `istio-remote-secret-<peer>`, Gateway `istio-eastwestgateway` |
| OpenChoreo org namespace on mgmt | `default` (label `openchoreo.dev/control-plane: "true"`) |
| Argo CD AppProjects | `platform` (mgmt + addons), `fleet` (cluster charts), `examples` (opt-in examples; always present), `tenant-<project>`; charts/platform projects sit in sync wave `-1`, before the ApplicationSets using them (Argo CD prunes in reverse) |

## Secret keys
Keys in the `platform` store (flat, backend-agnostic). The doc in the last column owns the details.

| Key | Properties | Used by | Doc |
|---|---|---|---|
| `platform-github` | `username`, `token` (or `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` with secret-stores `repoCreds.auth: githubApp`) | Argo CD repo-creds for `installation.githubOrg` (read-only) | [forking.md](forking.md#3-credentials) |
| `platform-github-app` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | git write access: Backstage scaffolder repo creation + platform PRs (opt-in, addon openchoreo-control-plane `scaffolder.githubApp`) | [project-templates.md](project-templates.md#repository-creation) |
| `platform-github-build` | `username`, `token` | in-cluster builds: clone + GitOps hand-off push, only to `buildWorkflows.git.allowedRepositoryPrefixes` | [build-plane.md](build-plane.md#secrets-clustersecretstore-platform) |
| `platform-ghcr` | `username`, `token` | node registry auth for `ghcr.io`; Harbor GHCR proxy cache | [providers.md](providers.md#node-registry-config) |
| `capi-aws` | `AWS_B64ENCODED_CREDENTIALS` | CAPA | [providers.md](providers.md#aws-capa---rendered-only) |
| `capi-hetzner` | `hcloud` | CAPH | [providers.md](providers.md#hetzner-cloud-caph---rendered-only) |
| `openchoreo` | Thunder, OpenChoreo user and Backstage secrets | addons thunder, openchoreo-control-plane | [openchoreo.md](openchoreo.md#secrets) |
| `openchoreo-observability` | `opensearch-username`, `opensearch-password`, `observer-client-secret` | observability plane; data-plane shippers (store `default`) | [observability.md](observability.md#secrets) |
| `harbor` | admin, robot and chart secrets | addon harbor, build pushes, node pulls | [build-plane.md](build-plane.md#secrets-clustersecretstore-platform) |
| `cosign-platform` | `cosign.key`, `cosign.pub`, `cosign.password` | in-cluster build signing; `cosign.pub` reaches workload clusters' Kyverno (`charts/cluster` image-verification CRS, property `cosign.pub` only) or `kyverno-policies` `imageVerification.platformKey.publicKey` | [build-plane.md](build-plane.md#signing) |
| `falco-webhook` | `url`, `token` | falcosidekick escalation -> addon argo-events; mgmt only: each cluster gets a token derived from it (charts/cluster CRS), never the key | [observability.md](observability.md#falco-response) |
| `promotion-gate` | `client-secret` | ClusterWorkflow `promotion-gate`; addon thunder registers it as client `openchoreo-promotion-gate` | [promotion.md](promotion.md#configuration-reference) |
| `openbao-unseal` | `key` (64 hex characters, generated by `task secrets`) | static auto-unseal key of the mesh CA (addon openbao; local only, KMS seal in production) | [multicluster.md](multicluster.md#unseal) |
| `promotion-gate-github` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | the promotion gate's own GitHub App | [promotion.md](promotion.md#configuration-reference) |
| `external-dns-cloudflare` | `api-token` | addon external-dns with `dns.provider: cloudflare`; on workload clusters only via store `dns`, never `default`. Route 53 has no key: IRSA / Pod Identity only | [dns.md](dns.md#credentials) |
| `openchoreo-ai` | `rca-llm-api-key`, `rca-oauth-client-secret`, `finops-llm-api-key`, `finops-oauth-client-secret`, `<provider>-api-key` | OpenChoreo AI agents, Thunder agent clients, addon agentgateway; only while switched on | [ai-agents.md](ai-agents.md) |

Workload-cluster keys (store `default`): `openchoreo-observability`, optional `datadog`, `falco-slack`; store `dns`: `external-dns-cloudflare`.

## Layout and ownership
```
bootstrap/                      k3d config, bootstrap.sh (task up/down), seed secrets
charts/platform/                root chart: AppProjects, ApplicationSets (fleet, addons catalog, tenants), mgmt cluster secret
charts/cluster/                 one workload cluster: templates/capi-*.yaml, argocd-*.yaml, openchoreo-*.yaml
charts/tenant/                  one tenant: AppProject, OpenChoreo Project, app Applications
addons/<addon>/                 wrapper charts (+ README.md, values/role-*.yaml, values/provider-*.yaml, values/cni-*.yaml)
examples/<name>/                opt-in example charts (installation.yaml examples.<name>.enabled; label selector)
installations/<inst>/           installation.yaml, clusters/, addons/, tenants/
docs/                           architecture, conventions, operations + runbooks/, one doc per area, diagrams
templates/                      golden-path project templates (Backstage scaffolder): template.yaml + skeleton/ each
hack/                           tests and helper scripts (task test); hack/lib/portable.sh
mise.toml, Taskfile.yml         pinned toolchain, cross-platform entrypoints (Makefile = shim)
```

Adding things:
- **Workload cluster**: `installations/<inst>/clusters/<name>.yaml` (schema: `charts/cluster/values.yaml`;
  [providers.md](providers.md#adding-a-cluster)).
- **Addon**: `addons/<name>/` (wrapper `Chart.yaml`, `values.yaml`, `README.md` <= 40 lines checked by
  `hack/check-docs.py`, optional `values/role-*.yaml`, `values/provider-*.yaml`, `values/cni-*.yaml`), registered in
  the catalog in `charts/platform/values.yaml` ([architecture.md](architecture.md#addons-catalog--labels-gitops-bridge-style)).
- **Tenant**: `installations/<inst>/tenants/<project>.yaml` ([openchoreo.md](openchoreo.md#tenants)).
- **Project template**: `templates/<name>/` + an entry in `templates/catalog-info.yaml`
  ([project-templates.md](project-templates.md#adding-a-template)).

## Tooling
- OS/arch-agnostic ([dev-environment.md](dev-environment.md)): tools only via `mise.toml` (aqua backends;
  `task tools:lock` after a bump), entrypoints in `Taskfile.yml` (keep the Makefile shim in step).
- Scripts: bash 3.2 + GNU/BSD/MSYS portable; use `hack/lib/portable.sh`; `${arr[@]+"${arr[@]}"}` for maybe-empty
  arrays.
- Images: multi-arch (`task images:audit`). The only exceptions are listed, with an expiry, in `hack/image-audit.sh`
  `ARCH_EXCEPTIONS` ([build-plane.md](build-plane.md#images-and-architectures)).
- `grep -rn VERIFY` lists values inferred but not yet confirmed live.

## Current practice only
No legacy patterns. Every addition uses the current upstream-recommended way; anything legacy found in review is
replaced, not copied.

- **APIs:** current stable versions only (no deprecated or beta when GA exists): Gateway API instead of Ingress, CAPI
  v1beta2 with ClusterClass topology, ESO v1, Kyverno CEL policy types (ValidatingPolicy, MutatingPolicy,
  ImageValidatingPolicy) instead of new ClusterPolicy, ValidatingAdmissionPolicy where native fits, ApplicationSets with
  goTemplate, server-side apply.
- **Security defaults:** Pod Security `restricted` is the target (`baseline` Audit only as a step), no privileged
  containers without a justifying comment, workload identity / OIDC instead of static cloud keys, secrets only via ESO,
  keyless Sigstore signing with SBOM and provenance verified at admission, images pinned by digest and multi-arch,
  never `latest`. Deliberate deviation: in-cluster builds sign with a platform key (`cosign-platform`, no public Rekor
  upload by default) because public Fulcio does not trust a private cluster's OIDC issuer
  ([build-plane.md](build-plane.md#signing)).
- **Runtime:** Cilium eBPF with kube-proxy replacement, Istio ambient (no sidecars), OpenTelemetry (no vendor agents),
  external cloud controller managers, OCI Helm charts, rootless BuildKit (no Docker-in-Docker), Crossplane v2.
- **Delivery:** everything declarative from git; no imperative `kubectl` steps or hand-run scripts on the path to
  production; CI providers are thin wrappers over the in-cluster OpenChoreo workflow plane.
