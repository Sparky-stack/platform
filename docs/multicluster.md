# Cluster-to-cluster connectivity (Istio ambient multicluster)

Opt-in. Workloads in different workload clusters call each other's Services by their usual names
(`<svc>.<ns>.svc.cluster.local`), with mTLS and identity-based authorization. There is no flat pod network, no VPN
appliance and no route between pod CIDRs: each cluster exposes one **east-west gateway**, and Istio ambient carries
cross-cluster traffic through it. Locally `dev1` (Cilium) and `prod1` (flannel) form the mesh group `local`, with the
example service on `prod1` and its callers on `dev1`.

Everything is declarative. Three settings turn it on, and adding a third cluster to the group needs nothing else:

```yaml
# installations/<inst>/installation.yaml
mgmt:
  addons:
    openbao: true               # the mesh CA (OpenBao PKI) + reader-cert admission guards on mgmt
mesh:
  groups: [local]               # one root + one intermediate per group, keys generated inside OpenBao
  ca: { host: openbao.openchoreo.localhost, port: 8200 }   # where members reach OpenBao (TLS passthrough)
examples:
  eastwest: { enabled: true }   # optional demo (examples/eastwest)

# installations/<inst>/clusters/<name>.yaml (every member)
mesh:
  group: local                  # meshID; network = cluster name
```

## Istio 1.32 status (what is GA, beta, alpha)
| Piece | Status in 1.32 | Used here |
|---|---|---|
| Ambient mode (ztunnel, istio-cni, L4 policy, waypoints) | GA (since 1.24) | yes |
| Ambient **multi-primary, multi-network** multicluster | **Beta** ("production ready" per the 1.32 docs, promoted in 1.29). The CNCF announced it as GA at KubeCon NA 2026 (10 Nov 2026), but the 1.32 docs and flags still describe it as beta: it is off by default behind `AMBIENT_ENABLE_MULTI_NETWORK`. **VERIFY** in the next release notes | yes |
| `istio-east-west` GatewayClass (Gateway API, HBONE listener, double HBONE) | ships with multi-network ambient; the class only exists while istiod runs with `AMBIENT_ENABLE_MULTI_NETWORK=true` | yes |
| `AMBIENT_ENABLE_BAGGAGE` (peer metadata across networks, correct metrics labels) | recommended with multi-network | yes |
| Ambient multicluster on a **single network** | alpha, untested upstream | no (every cluster is its own network) |
| Primary-remote (one istiod for several clusters) | not supported in ambient | no (every member runs its own istiod) |
| Ambient + sidecars in one multicluster mesh | not recommended upstream | no (ambient only) |
| Service scope `istio.io/global` label (default `serviceScopeConfigs`) | part of ambient multicluster | yes |
| External CA via istio-csr (`ENABLE_CA_SERVER=false`, `caAddress`) | supported integration (cert-manager istio-csr, ztunnel node authorisation via `--ca-trusted-node-accounts`) | yes, on members |
| Gateway API `Gateway` v1 + `infrastructure.parametersRef` | GA (standard channel, v1.5.1 installed) | yes |
| `security.istio.io/v1` `AuthorizationPolicy` | GA | yes |

Upstream's known limitations that apply: service scope must be the same on every cluster (only the local cluster's
`istio.io/global` label counts), waypoints must have the same names on every cluster, and load to a remote network is
not spread evenly (one remote endpoint can take a large share; istio/istio#58039).

## How a call travels
```
dev1                                                    prod1
client pod --(captured)--> ztunnel(dev1) ==HBONE in HBONE==> east-west gw (prod1) --HBONE--> ztunnel(prod1) --> echo pod
   echo.eastwest-demo:8080        outer mTLS: ztunnel(dev1) <-> gateway (15008)
                                  inner mTLS: ztunnel(dev1) <-> ztunnel(prod1), end to end (client identity kept)
```
- `echo` exists as a Service in **both** clusters, so DNS resolves in dev1. It carries the label `istio.io/global=true`.
  dev1's istiod merges prod1's endpoints (seen through the remote secret) behind the hostname. Because those endpoints
  sit on network `prod1`, dev1's ztunnel sends the call to prod1's east-west gateway instead of to the pod IP. Pod CIDRs
  may overlap.
- The gateway terminates only the outer tunnel. Authorization at the destination sees
  `cluster.local/ns/eastwest-demo/sa/client`, the caller's identity, not the gateway's.
- Each cluster's network = its name. ztunnel's `NETWORK`, the istio-system label `topology.istio.io/network` and the
  Gateway label must agree, and they all come from one label (below).

## Configuration flow
`charts/cluster` turns `mesh.group` into labels on the CAPI `Cluster` and the Argo CD cluster secret. Everything else
selects or reads those labels; no template names a cluster.

| Label (derived) | Consumed by |
|---|---|
| `mesh.platform.koorikla.io/group: <group>` | catalog `clusterLabelParameters` → istio-ambient `global.meshID`; CRS selector of the peers' remote secrets |
| `mesh.platform.koorikla.io/network: <name>` | istio-ambient `global.network` (ztunnel `NETWORK`); istio-eastwest Gateway label |
| `addons.platform.koorikla.io/istio-eastwest: "true"` (`"false"` without a group) | selects addon `istio-eastwest` and the example; istiod env `AMBIENT_ENABLE_MULTI_NETWORK`, `AMBIENT_ENABLE_BAGGAGE` |
| `addons.platform.koorikla.io/istio-csr: "true"` (`"false"` without a group) | selects addon `istio-csr`; istio-ambient layers `values/mesh-member.yaml` on clusters with a group label (istiod CA off) |

`global.multiCluster.clusterName` = cluster name on **every** cluster (catalog `clusterNameParameters`), so istiod and
ztunnel always agree on the cluster ID. Clusters outside the mesh keep network and meshID empty: ztunnel and istiod
must agree on the network, otherwise local traffic is sent to a gateway that doesn't exist.

The catalog gained a generic field for this:
```yaml
clusterLabelParameters: { <helm param>: { label: <cluster secret label>, default: <string> } }
# -> '{{ $v := index .metadata.labels "<label>" }}{{ if $v }}{{ $v }}{{ else }}<default>{{ end }}' (forceString)
```

| Where | What | Owner |
|---|---|---|
| mgmt, `openbao` | OpenBao (StatefulSet, raft, TLS), Gateway + TLSRoute `openbao`, reconcile Job/CronJob `mesh-reconcile`, ExternalSecrets `openbao-unseal`, `mesh-clients`, `openbao-ca-bundle`, ClusterSecretStore `mgmt-openbao`; ValidatingAdmissionPolicies `platform-mesh-*` (reader certs) | addon `openbao` (mgmt, opt-in) |
| mgmt, OpenBao | per group: mounts `pki-mesh-<group>-root`, `pki-mesh-<group>-int`; per member: role `<name>` in its group's intermediate, policy `mesh-member-<name>`, JWT auth mount `auth/mesh-<name>` | `addons/openbao/files/mesh-reconcile.sh` |
| mgmt, `fleet` | `ExternalSecret <name>-mesh-openbao` (the member's API server URL + cluster CA certificate for OpenBao); `ExternalSecret` + `ConfigMap <name>-mesh-oidc` + `ClusterResourceSet <name>-mesh-trust` (public certificates, network label, issuer-discovery binding) | `charts/cluster` `templates/mesh-openbao.yaml`, `mesh-trust.yaml` |
| mgmt, `fleet` | `Issuer <name>-client-ca` (over `<name>-cca`), `Certificate <name>-mesh-reader`, `ExternalSecret` + `ClusterResourceSet <name>-mesh-remote-secret` | `charts/cluster` `templates/mesh-remote-secret.yaml` |
| member, `istio-system` | istio-csr, `Issuer openbao-mesh` (cert-manager Vault issuer), ServiceAccount `istio-csr-openbao`, `Certificate istiod`; ValidatingAdmissionPolicies `platform-mesh-ca-*` | addon `istio-csr` |
| member, `istio-system` | `Gateway istio-eastwestgateway` (+ params ConfigMap), `ClusterRole`/`ClusterRoleBinding`/`Role`/`RoleBinding platform-istio-reader` | addon `istio-eastwest` |
| member, `istio-system` | istiod/ztunnel multicluster values, istiod CA off (`values/mesh-member.yaml`) | addon `istio-ambient` (catalog parameters) |
| member, `istio-system` | `Secret openbao-ca`, `Secret mesh-root-ca` (public certificates), label on the namespace, `Secret istio-remote-secret-<peer>` per peer; cluster-scoped `ClusterRoleBinding platform-oidc-discovery` | CAPI ClusterResourceSets (from mgmt) |
| member, `eastwest-demo` | example | `examples/eastwest` via ApplicationSet `example-eastwest` |

## Mesh CA (OpenBao)
Every member of a group must chain to the same root so that a dev1 workload certificate verifies in prod1. The CA is
OpenBao's PKI engine on mgmt; **no CA private key exists on any workload cluster** ([conventions.md](conventions.md)
invariant 4) and none is ever exported from OpenBao.

```
member (istio-system)                                          mgmt (openbao)
ztunnel / gateways --CSR--> istio-csr --CertificateRequest--> cert-manager Vault Issuer openbao-mesh
                                                                 | JWT login: projected token of SA istio-csr-openbao,
                                                                 |   audience vault://istio-system/openbao-mesh
                                                                 v   (TLS passthrough via kgateway, mesh.ca.host:port)
                                                    auth/mesh-<name> --policy mesh-member-<name>-->
                                                    pki-mesh-<group>-int/sign/<name>  (intermediate key inside OpenBao)
                                                    pki-mesh-<group>-root             (root key inside OpenBao)
```

- **One root and one intermediate per group**: installation.yaml lists the groups (`mesh.groups`). The reconcile
  creates `pki-mesh-<group>-root` (`root/generate/internal`, EC P-384, 10y) and `pki-mesh-<group>-int`
  (`intermediate/generate/internal`, EC P-256, signed by the root with `max_path_length=0`). `internal` means OpenBao
  generates the key and never returns it; no policy grants `generate/exported`, key import or `sys/raw`. A fleet file's
  `mesh.group` must be listed (charts/cluster fails otherwise). A group is a cryptographic boundary: a member of group A
  can only reach group A's intermediate, so it cannot obtain an identity that group B accepts. All groups still use the
  trust domain `cluster.local` (per-environment trust domains:
  [#71](https://github.com/koorikla/platform/issues/71)).
- **Groups follow trust levels.** Clusters of different environments or trust levels never share a group. `local`
  (dev1 + prod1 on one laptop) is the deliberate exception for the demo; real installations use e.g. `dev` and `prod`.
- **One role per member**, `pki-mesh-<group>-int/roles/<name>`: URI SANs `spiffe://cluster.local/ns/*/sa/*` only, DNS
  names only `istiod.istio-system.svc` and `cert-manager-istio-csr.istio-system.svc` (istiod's and istio-csr's serving
  certs), no IP SANs, no wildcards, no subdomains, no CA certificates, `ttl` 24h, `max_ttl` 48h, `no_store` (nothing
  to revoke: see below).
- **Per-member authentication without static tokens.** `auth/mesh-<name>` is a JWT auth mount that verifies tokens
  against that member's own API server keys (`<server>/openid/v1/jwks`, TLS pinned to the member's cluster CA). Its
  only role accepts subject `system:serviceaccount:istio-system:istio-csr-openbao` and audience
  `vault://istio-system/openbao-mesh` (cert-manager requests exactly this audience for a Vault issuer's
  `serviceAccountRef`), and issues a 10-minute batch token with one policy: `create`/`update` on
  `pki-mesh-<group>-int/sign/<name>`. A member's token is useless at another member's mount (other keys) and its
  policy reaches no other role, mount or path. On the member, only cert-manager's controller may mint that
  ServiceAccount's tokens (`Role` on `serviceaccounts/token`, `resourceNames`).
- **Issuer discovery is public, and delivered first.** OpenBao fetches the JWKS without a credential, so every member
  binds the read-only ClusterRole `system:service-account-issuer-discovery` (GET `/.well-known/openid-configuration`
  and `/openid/v1/jwks`, nothing else) to `system:unauthenticated` (`ClusterRoleBinding platform-oidc-discovery`;
  upstream's documented setup for an external relying party). It ships in the member's `ClusterResourceSet
  <name>-mesh-trust` from a static `ConfigMap <name>-mesh-oidc` (no ESO, no OpenBao), so it is applied as soon as the
  member's API server is up, before the reconcile configures `auth/mesh-<name>`; an addon would sync too late (seen on
  the live boot: OpenBao got `403 system:anonymous` because addon istio-csr had not synced yet). The keys are public;
  minting a token still needs the member's signing key. Rejected alternatives: TokenReview from OpenBao (a member
  credential on mgmt), or mgmt reading the JWKS with the CAPI admin kubeconfig into static `jwt_validation_pubkeys`
  (admin credential in the reconcile, manual key rotation); OpenBao's JWT auth has no authenticated JWKS fetch. Next
  hardening: restrict anonymous requests to these paths with the API server's `AuthenticationConfiguration`
  (`anonymous.conditions`) in the ClusterClasses.
- **Member inputs come from the fleet file, declaratively.** charts/cluster renders `ExternalSecret
  <name>-mesh-openbao` in `fleet`: it reads the CAPI kubeconfig and keeps only the API server URL and the cluster CA
  certificate (both public), labelled `mesh.platform.koorikla.io/openbao-client`. Addon openbao's `ExternalSecret
  mesh-clients` collects all of them by label (store `mgmt-fleet`) into one file set; the reconcile turns each into
  `auth/mesh-<name>` + role + policy. A new member is configured within one ESO refresh plus the 5-minute CronJob; a
  removed member's auth mount and policy are deleted on the next run (an empty input set prunes nothing, so an ESO
  outage cannot wipe the mesh).
- **One member cannot fail the fleet.** The reconcile configures each member on its own: a member whose API server is
  unreachable, or whose JWKS is not readable yet, is logged as `FAILED` and skipped, the others are configured, and its
  existing auth mount is kept (never pruned while it is in the inputs). Each run ends with
  `done: configured=[...] failed=[...] invalid=[...]`. The Job/CronJob fails only for invalid global config (groups,
  environment), when no member could be configured, or when every member input is invalid. Check:
  `kubectl -n openbao logs job/mesh-reconcile | grep -E 'FAILED|done:'`.
- **Public trust delivery.** OpenBao publishes each group root (`pki-mesh-<group>-root/cert/ca`, read by ESO with
  OpenBao role `mesh-ca-read`) into `openbao/openbao-ca-bundle` together with OpenBao's TLS CA certificate. Store
  `mgmt-openbao` may GET only that Secret (name-scoped RBAC, namespace `fleet`). `ClusterResourceSet <name>-mesh-trust`
  delivers `istio-system/openbao-ca` (verifies OpenBao's listener) and `istio-system/mesh-root-ca` (istio-csr pins it
  as its root; cert-manager's `ca.crt` must match it) plus the namespace label `topology.istio.io/network=<name>`.
  Contract tests assert that no ClusterResourceSet payload or workload-cluster ExternalSecret reads a CA private key.
- **istiod has no CA on members** (`values/mesh-member.yaml`: `ENABLE_CA_SERVER=false`, `caAddress` = istio-csr).
  istio-csr answers ztunnel's and gateways' CSRs (ztunnel is a trusted node account, as ambient requires) and issues
  istiod's serving certificate (`Certificate istiod`, 48h, renewed after 24h). istiod decides once at start whether it
  has serving certs, so the pod mounts `Secret istiod-tls` and `ConfigMap istio-ca-root-cert` as non-optional volumes
  and stays in `ContainerCreating` until istio-csr has both: no silent fallback to a self-signed root.

### Configuration as code, no root token
OpenBao's [self-initialisation](https://openbao.org/docs/configuration/self-init/) (`initialize` blocks in the
server config, `addons/openbao/values.yaml`) runs once on the first start: it enables the file audit device to stdout,
the Kubernetes auth method for mgmt ServiceAccounts, the policy `platform-mesh-config` and its role, then **revokes
its own root token**. No root token or recovery key is ever stored. Everything after that is applied by
`files/mesh-reconcile.sh` (Argo CD PostSync Job + CronJob, idempotent, POSIX sh + the pinned `bao` CLI), which logs in
with a projected, audience-bound token of ServiceAccount `openbao/openbao-mesh-config` (15-minute OpenBao token, no
Kubernetes API access). `platform-mesh-config` covers only the mesh: `pki-mesh-*` mounts, their roles and
`root/generate/internal` / `intermediate/*`, `auth/mesh-*`, policies `mesh-*`. It cannot read or change itself,
`platform-*` policies, `sys/raw`, seal or generate-root, and it cannot export a key.

Chosen over the alternatives: a Terraform/OpenTofu provider needs state and a runner outside GitOps; the young
OpenBao config operators (CR per mount/role/policy) are not yet widely used and would add a privileged controller
holding a broad token. The script is ~150 lines, tested against a fake CLI (`hack/tests/test_openbao_reconcile.sh`,
part of `task test`) and against the real pinned image (`task test:openbao`, docker).

### Unseal
Locally OpenBao uses the **static seal** (`seal "static"`, AES-256-GCM key from the secret backend): `make secrets`
seeds `openbao-unseal` once in the `platform` store, ESO mounts it, and OpenBao unseals itself on every start. This
is auto-unseal with the key next to the data, acceptable for a laptop only. **Production**: replace the stanza with a
cloud KMS seal (`seal "awskms"` with IRSA / Pod Identity, no static keys) or `seal "transit"` against a separate
OpenBao, and run 3 raft replicas: [#31](https://github.com/koorikla/platform/issues/31).

### When OpenBao is down
Running workloads keep working; nothing new gets an identity:

| | Effect while OpenBao (or the path to it) is down |
|---|---|
| existing pods, ztunnel, gateways | keep their certificates; ztunnel renews at half-life, so a workload certificate (24h) lasts >= 12h after the last renewal |
| istiod | keeps serving with its 48h cert (renewed after 24h): >= 24h |
| new pods / restarted ztunnel | get no certificate until OpenBao is back (traffic from them fails closed) |
| reconcile, new members | wait; the CronJob retries every 5m |

So the outage budget is about 12 hours for workloads. TTLs are a trade-off between that budget and exposure: Istio
checks no CRL or OCSP, so a leaked workload certificate is valid until `notAfter` (<= 24h, istiod's <= 48h). A
compromised member is cut off at once by deleting its auth mount (remove `mesh.group` from the fleet file); its
issued certificates expire within a day. The 7-day reader client certs (remote secrets) cannot be revoked either.

### Bootstrapping order
1. mgmt: `make secrets` seeds `openbao-unseal`; addon openbao starts, self-initialises, unseals; the PostSync Job
   creates the group mounts. `openbao-ca-bundle` is filled once the roots exist (ESO retries).
2. A member's fleet file gets `mesh.group`: charts/cluster labels the Cluster and renders `<name>-mesh-openbao`.
   `ClusterResourceSet <name>-mesh-trust` applies the issuer-discovery binding as soon as the member's API server is
   up (static ConfigMap), then the public certificates once ESO has them. The next reconcile creates
   `auth/mesh-<name>`, role and policy; if the member's JWKS is not readable yet it is reported `FAILED`, the other
   members are configured, and the CronJob (5 min) retries.
3. On the member, cert-manager (catalog default) and addon istio-csr come up; the Vault issuer turns Ready once
   OpenBao accepts its login; istio-csr issues istiod's cert. istiod (gated) starts, then ztunnel (sync wave 1).

### Admission guards
cert-manager's internal approver approves every CertificateRequest, and a CA issuer signs whatever it is asked.

On mgmt, the `<name>-client-ca` Issuers (the k3s client CA of a workload cluster, whose API server accepts anything they
sign, `O=system:masters` included) are guarded by addon openbao's ValidatingAdmissionPolicies
(`admissionregistration.k8s.io/v1`, Deny):

| Policy | Admits |
|---|---|
| `platform-mesh-reader-certificates` | Certificates for a `*-client-ca` issuer: in `fleet`, `CN=platform:istio-reader`, no subject (no O/OU = no groups), no SANs, not a CA, usages client auth + digital signature, duration set and <= 168h |
| `platform-mesh-certificaterequests` | CertificateRequests for them: created by cert-manager's controller only (so they come from an admitted Certificate; CEL cannot parse the CSR), in `fleet`, same profile |
| `platform-mesh-issuers` | a `<x>-cca` Secret may back only `Issuer fleet/<x>-client-ca` |

On members, OpenBao's role already limits *what* can be signed (SPIFFE IDs of the trust domain). Addon istio-csr limits
*who* may ask: `platform-mesh-ca-requests` admits CertificateRequests for `Issuer istio-system/openbao-mesh` only from
istio-csr's or cert-manager's ServiceAccount and never as a CA; `platform-mesh-ca-certificates` admits only the chart's
`Certificate istio-system/istiod` for that issuer. Without them anyone allowed to create CertificateRequests in
`istio-system` could mint any SPIFFE identity of the mesh.

`hack/tests/test_mesh_admission.sh` evaluates the CEL offline with the kyverno CLI: the rendered objects pass, the
negative cases (system:masters, other CNs, sub-CAs, long durations, SANs, other namespaces, hand-made requests, rogue
issuers, workload ServiceAccounts) are denied.

### Root and intermediate rotation
Planned procedure, not a renewal (the intermediate lives 5 years inside OpenBao; the issued certificates are what is
short-lived): generate a new root next to the old one, publish both in `mesh-root-ca` (a trust bundle), switch the
intermediate to the new root, then drop the old root. Tracked with the other follow-ups in
[#71](https://github.com/koorikla/platform/issues/71).

## Discovery: declarative remote secrets
Each istiod watches the other members' API servers (Services, EndpointSlices, Pods, Namespaces) through a remote
secret: `istio-system/istio-remote-secret-<peer>`, labelled `istio/multiCluster=true`, holding a kubeconfig. Here
**each cluster's own chart publishes its remote secret to every other member of its group**:

1. `Issuer <name>-client-ca`: a cert-manager CA issuer over `fleet/<name>-cca`, the k3s **client CA** that
   cluster-api-k3s generates and keeps on mgmt. That cluster's API server already trusts it for client
   authentication (the CAPI admin kubeconfig is signed by it). cert-manager only reads that Secret.
2. `Certificate <name>-mesh-reader`: client cert `CN=platform:istio-reader`, no organisation (so no groups), ECDSA,
   **7 days**, renewed after 4.
3. On the member, addon `istio-eastwest` binds user `platform:istio-reader` to `ClusterRole platform-istio-reader`
   (read-only discovery; Secrets only if the installation opts in, "Reader RBAC" below).
4. `ExternalSecret <name>-mesh-remote-secret` (store `mgmt-fleet`, refreshed every 5m) builds the kubeconfig. It
   takes the API endpoint and CA from the CAPI kubeconfig and the user from the reader cert, and writes it as JSON
   so no YAML indentation is templated. The result is a ClusterResourceSet payload.
5. `ClusterResourceSet <name>-mesh-remote-secret` selects `mesh.platform.koorikla.io/group=<group>` and
   `platform.koorikla.io/name NotIn [<name>]`. A new member gets every existing member's secret, and every existing
   member gets the new one. No file lists peers.

Why not the alternatives:
- `istioctl create-remote-secret` is imperative.
- The CAPI admin kubeconfig (`system:masters`) would hand cluster-admin to every peer.
- A ServiceAccount token Secret is long-lived, needs a read path back from the workload cluster, and is the legacy
  token mechanism.

Kubernetes can't revoke client certificates, hence the 7-day lifetime.

### Reader RBAC: what a peer may read
Upstream's `istio-reader-clusterrole-istio-system` (istiod chart) grants cluster-wide get/list/watch on `secrets` and
`configmaps`, create/delete on MCS `serviceexports` and create on `tokenreviews`/`subjectaccessreviews`. Bound to the
reader user, every peer could read this cluster's istio-csr and istiod serving keys, the OpenChoreo agent identity and
every tenant Secret. So the reader is bound to the platform's own roles instead (addon `istio-eastwest`
`templates/reader-rbac.yaml`), derived from what istiod 1.32.0 actually reads on a remote cluster:

| istiod 1.32.0 source | Remote reads | Granted |
|---|---|---|
| `pkg/kube/multicluster/cluster.go` (ambient KRT collections) | namespaces, pods, services, nodes, endpointslices, Gateway API gateways | `ClusterRole platform-istio-reader` get/list/watch |
| `serviceregistry/kube/controller` | the same + endpoints, MCS serviceimports, CRDs (delayed informers) | same |
| `PILOT_ENABLE_CROSS_CLUSTER_WORKLOAD_ENTRY` (default on) | networking.istio.io workloadentries | Istio config groups, read-only |
| remote mesh watcher (`controller/multicluster.go`) | ConfigMap `istio-system/istio` (trust domain), by field selector | `Role platform-istio-reader`, `resourceNames: [istio]` |
| remote credentials controller (`pilot/pkg/credentials/kube`) | Secrets list/watch, cluster-wide (field selector excludes only Helm releases and SA tokens). The data serves only gateways whose istiod is in another cluster (primary-remote), but the informer gates the peer's sync (below) | **none by default**; opt-in `reader.remoteCredentialsSecrets` (separate `ClusterRole platform-istio-reader-secrets`, list/watch) |
| leader election / namespace controller on remotes | only with `EXTERNAL_ISTIOD` | none |
| `serviceexports` writes, tokenreviews, SARs | `ENABLE_MCS_AUTO_EXPORT` (off), primary-remote proxy auth | none |

#### The remote Secret informer (istiod 1.32.0): no knob keeps Secrets out and the peer in
Read from the 1.32.0 source (also unchanged in 1.31.4 and on `release-1.32`/`master` as of this PR):
1. `PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` (added by istio/istio#59874 for exactly this RBAC) makes the
   component constructor in `pilot/pkg/credentials/kube/multicluster.go` return a nil `*CredentialsController` for
   each remote cluster. `Component.clusterAdded` (`pkg/kube/multicluster/component.go`) returns it as the handler's
   syncer, and `Cluster.Run` (`pkg/kube/multicluster/cluster.go`) calls `kube.WaitForCacheSync(..., h.HasSynced)` on
   it: `CredentialsController.HasSynced` dereferences `s.secrets` on a nil receiver, istiod SIGSEGVs as soon as it
   has a remote secret (seen on the live boot). The flag is unusable until upstream makes it nil-safe.
2. With the controller on (the default) and Secrets forbidden, its `kclient.NewFiltered[*v1.Secret]` informer is
   started on the peer's client before `c.Client.RunAndWait(c.stop)`, which waits on every started informer
   (`informerFactory.WaitForCacheSync`); a reflector whose list is forbidden never syncs. After
   `PILOT_REMOTE_CLUSTER_TIMEOUT` (30s) `Cluster.Run` marks the peer `timeout`, and `ClusterStore.AllReady`
   (`clusterstore.go`) leaves timed-out clusters out of the `RemoteClusters` KRT collection the ambient index is
   built from: **the peer's services and workloads are not served**. istiod itself becomes ready (the timeout counts as
   synced), which is why this looked harmless in sidecar-mode reports on 1.29 (istio/istio#59845) but is not on 1.32.
3. Other knobs do not help: `PILOT_REMOTE_CLUSTER_TIMEOUT=0` blocks istiod's readiness instead,
   `ISTIO_WATCH_NAMESPACE` restricts every informer (services, pods) to one namespace, and
   `PILOT_ENABLE_XDS_IDENTITY_CHECK=false` (skips the credentials controller entirely) turns off XDS client
   authorisation. RBAC cannot scope a cluster-wide list by field selector.

So the choice is per installation (`installations/<inst>/addons/istio-eastwest/values.yaml`):
- `reader.remoteCredentialsSecrets: false` (default, the B1 position): peers read no Secret; on istiod 1.32.0
  cross-cluster discovery does not work (`istioctl remote-clusters`: `timeout`).
- `reader.remoteCredentialsSecrets: true`: `ClusterRole platform-istio-reader-secrets` (list/watch on Secrets, no get)
  for the reader user; peers are served. Blast radius: a compromised peer istiod of the same group reads every Secret
  of the member (OpenChoreo agent identity, istio-csr/istiod serving keys, tenant Secrets) - on top of what a group
  peer can already do (mint any workload identity of the trust domain). Use only where all members of a group sit
  at one trust level.
- Exit: once upstream makes `CredentialsController.HasSynced`/`Close` nil-safe (or skips nil components in
  `Cluster.Run`), set `PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` in istio-ambient and drop the opt-in.

Unittests pin the rules and assert the negatives (default: no Secret rule; opt-in: list/watch only, separate
objects; istio-ambient never sets the flag). **VERIFY** on the live run: no istiod restart/SIGSEGV; with the default,
`istioctl remote-clusters` shows each peer `timeout` and istiod logs `failed to list *v1.Secret ... forbidden` (this
analysis); with the opt-in, each peer `synced`, no `forbidden`, and `kubectl auth can-i --as platform:istio-reader get
secrets -A` is still `no` (list/watch only). Re-check this section on every Istio upgrade.

Peers can still read Pods, Services and Istio config of each other, so members of one group must sit at the same
trust level (see "Trust").

Peers must reach each member's API endpoint: locally the CAPD load balancer container on docker network `kind`, on AWS
the CAPA API ELB, on Hetzner the API load balancer.

### Removing a member (decommissioning)
CRS never deletes what it applied, and Istio checks no revocation, so decommissioning is explicit:
1. Remove `mesh.group` from the fleet file (or delete the fleet file). `<name>-mesh-openbao` goes with the cluster
   chart, and the next reconcile deletes `auth/mesh-<name>` and policy `mesh-member-<name>`: the member can no longer
   get certificates. Its issued certificates expire within 24h (istiod's 48h).
2. On every remaining member delete `istio-system/istio-remote-secret-<gone>` (CRS leaves it behind; istiod logs a
   failing remote cluster until then). Its reader cert stops authenticating within 7 days in any case.
3. On mgmt delete the leftover Secret `fleet/<gone>-mesh-reader` (cert-manager does not delete a Certificate's Secret
   with it).

## Example (`examples/eastwest`)
The `ApplicationSet example-eastwest` (charts/platform `templates/appset-examples.yaml`) is rendered only when
`installation.yaml` sets `examples.eastwest.enabled`. It targets clusters labelled
`addons.platform.koorikla.io/istio-eastwest=true`, and values layer as
`examples/eastwest/values.yaml` < `installations/<inst>/examples/eastwest/{values,cluster-<name>}.yaml`.

- Namespace `eastwest-demo`: `istio.io/dataplane-mode=ambient`, Pod Security `restricted` enforced.
- `Service echo` (global) on every member. The `echo` Deployment (`hashicorp/http-echo`, answers
  `hello from <cluster>`) runs on prod1 only (`installations/local/examples/eastwest/cluster-dev1.yaml` disables it).
- Callers `client` and `stranger` run on dev1 only. Each curls `echo.eastwest-demo.svc.cluster.local:8080` every 10s
  and logs `OK: hello from prod1` or `FAILED: ...`.
- `AuthorizationPolicy echo-allow-client` (`security.istio.io/v1`, ALLOW, enforced by prod1's ztunnel at L4, no
  waypoint) admits only `cluster.local/ns/eastwest-demo/sa/client` on port 8080. `client` succeeds and `stranger` is
  reset, which proves the identity crossed the clusters.
- Images are multi-arch and pinned by digest. Requests are 5m CPU / 8Mi each, limit 32Mi.
- AppProject `examples` (charts/platform `templates/projects.yaml`) admits only the catalog's example namespaces and
  is rendered whether or not an example is enabled, in sync wave `-1`. The generated Applications carry the resources
  finalizer, which Argo CD can only run while their project exists (the live boot left them stuck with
  `DeletionError: project not found` when the project went first). Turning an example off prunes just its
  ApplicationSet, foreground, so its Applications and their resources are deleted under an unchanged project; if the
  project is ever removed, Argo CD prunes in reverse wave order and waits for the ApplicationSets to be gone first
  (`hack/tests/test_appprojects.sh`).
- On istiod 1.32.0 the cross-cluster call needs the installation's `reader.remoteCredentialsSecrets` decision
  ("Reader RBAC"); with the default the peer is not served and `client` logs `FAILED`.

The example is a platform smoke test delivered like an addon (Argo CD push). Tenant apps still reach clusters through
OpenChoreo (invariant 3). Making an OpenChoreo component cross-cluster takes the same two things: its namespace is
ambient (Kyverno already enrolls cell namespaces), and its Service carries `istio.io/global=true` on every member. Cell
namespaces are named per data plane, so a cross-cluster call needs the same namespace and Service name on both sides:
that is an OpenChoreo ComponentType/trait design question, left open here.

## Reachability per provider
| | east-west gateway (Service type LoadBalancer, tcp 15008 + 15021 status) | peer API servers (tcp 6443) |
|---|---|---|
| local (CAPD) | klipper servicelb: `EXTERNAL-IP` = node container IP on docker network `kind`, which the other CAPD clusters reach directly (checked: servicelb hostPorts answer on both dev1/Cilium and prod1/flannel) | CAPD LB container IP on `kind` |
| AWS (CAPA + aws-ccm) | `values/provider-aws.yaml`: NLB (`aws-load-balancer-type: nlb`), internet-facing. CAPA's default node SG already admits NodePorts (30000-32767) for the NLB targets, so **no ClusterClass change**. `gateway.loadBalancerSourceRanges` (the peers' NAT gateway EIPs) is **required** outside docker: the render fails without it, so 15008/15021 are never open to 0.0.0.0/0. Also narrow CAPA's NodePort CIDRs (`AWSCluster.spec.network.nodePortIngressRuleCidrBlocks`). **VERIFY** NLB with aws-ccm and that CAPA keeps CCM-added SG rules | CAPA API ELB (`controlPlaneLoadBalancer.scheme` internet-facing by default); restrict 6443 via `controlPlaneLoadBalancer.ingressRules` to the peers' egress IPs (**VERIFY** CAPA's default ingress CIDRs) |
| Hetzner (CAPH + hcloud-ccm) | the template adds `load-balancer.hetzner.cloud/location: <region>` (hcloud-ccm needs a location or network zone). CAPH creates no firewall, so the LB reaches the node ports; `gateway.loadBalancerSourceRanges` is required here too. **VERIFY** that hcloud-ccm honours it | CAPH API LB (public) |

Only 15008 (HBONE) needs to be reachable between clusters for data. 15012/15017 (istiod xDS/webhook) don't cross
clusters in multi-primary, and API access is 6443 on the existing API load balancers. In real installations, restrict
both to the peers' egress addresses.

## Mixed CNIs (dev1 Cilium, prod1 flannel)
The mesh only needs node-level reachability between clusters, so the CNI doesn't matter. ztunnel runs inside each
pod's network namespace (istio-cni in-pod redirection) and dials the remote gateway's LoadBalancer IP. That traffic
leaves the cluster like any pod egress: SNAT to the node IP (Cilium iptables masquerade, since
`bpf.masquerade: false` for ambient; flannel's masquerade). The gateway's servicelb hostPort works under Cilium's
kube-proxy replacement as well as under kube-proxy (the OpenChoreo gateway uses the same mechanism on both clusters).
On dev1, Cilium WireGuard encrypts node-to-node traffic *inside* the cluster. Between clusters the HBONE mTLS is the
encryption.

## Footprint (per member, requests)
| Component | CPU | Memory |
|---|---|---|
| east-west gateway (1 replica, `parametersRef`) | 50m | 64Mi (limit 256Mi) |
| istiod: extra informers for each peer | - | grows with the peers' object counts; estimate +50-100Mi for small clusters (**VERIFY**) |
| example (echo + 2 callers, only where enabled) | 15m | 24Mi |

## Turning it on for running clusters (dev1, prod1)
Adding `mesh.group` to live clusters is handled entirely by Argo CD, ESO, CAPI and the reconcile; there is no manual
step. Order of events:
1. The Cluster labels change. ESO refreshes the Argo CD cluster secret (1m); the istio-ambient Application re-renders
   (istiod: multi-network, CA off, gated on `istiod-tls`; ztunnel: new network/cluster ID/CA address and the pod
   annotation `mesh.platform.koorikla.io/group`) and addon istio-csr is selected.
2. In parallel, the reconcile configures `auth/mesh-<name>` and the CRS delivers the public certificates. The new
   istiod pod starts only once istio-csr has issued `istiod-tls`; the old istiod keeps serving until then.
3. ztunnel's DaemonSet carries `argocd.argoproj.io/sync-wave: "1"` (addons/istio-ambient/values.yaml), so Argo CD
   applies it only after the wave-0 resources, istiod included, are Healthy. The ztunnel rollout is the restart: the
   new pods fetch workload certificates from istio-csr, chained to the group root, so in-mesh mTLS never mixes roots.
   Leaving or changing a group changes the pod annotation, so that rollout happens as well.
   If istiod is not Healthy within `progressDeadlineSeconds` (600s) the sync fails and Argo retries (limit 10, backoff
   up to 5m); ztunnel stays on the old config meanwhile. Watch `kubectl -n argocd get application
   istio-ambient-<cluster>`.

Fresh clusters follow the same order; ztunnel simply waits until istiod is up.

## Follow-ups and open checks
Deferred work (per-environment trust domains + URI name constraints, root rotation runbook, baggage stripping at the
north-south edge, peer API 6443 restrictions on CAPA/CAPH): [#71](https://github.com/koorikla/platform/issues/71).
Production unseal and HA: [#31](https://github.com/koorikla/platform/issues/31). istiod's nil-unsafe
`PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` (upstream fix needed before the Secret opt-in can go; "Reader
RBAC"). Values inferred but not yet confirmed
live (`grep -rn VERIFY docs/multicluster.md addons/openbao addons/istio-csr addons/istio-eastwest addons/istio-ambient
charts/cluster/templates/mesh-*`): [#72](https://github.com/koorikla/platform/issues/72).
