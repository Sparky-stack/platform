# Cluster-to-cluster connectivity (Istio ambient multicluster)

Opt-in. Workloads in different workload clusters call each other's Services by their usual names
(`<svc>.<ns>.svc.cluster.local`) with mTLS and identity-based authorization. There is no flat pod network, VPN or
route between pod CIDRs: each cluster exposes one **east-west gateway** and Istio ambient carries cross-cluster
traffic through it. The mesh CA is OpenBao on mgmt, which also holds the tenants' app secrets
([Tenant secrets](#tenant-secrets-openbao)). Locally `dev1` (Cilium) is the only member of mesh group `local` in the
default profile; the multicluster profile ([dev-environment.md](dev-environment.md#local-profiles)) adds `prod1`
(flannel).

| Task | How |
|---|---|
| Put a cluster in the mesh | `mesh.group` in its fleet file (below); on an existing local mgmt publish port 8200 first ([Turning it on](#turning-it-on-for-running-clusters-dev1-prod1)) |
| Check the mesh CA reconcile | `kubectl -n openbao logs -l app.kubernetes.io/name=mesh-reconcile --tail=-1 \| grep -E 'FAILED\|WARNING\|ERROR\|done:'` |
| Write a tenant app secret | [Writing a secret](#writing-a-secret) |
| Remove a member | delete `mesh.group`, then [clean up](#removing-a-member-decommissioning) |
| Check east-west discovery | [Verifying east-west](#verifying-east-west-with-an-openchoreo-component) |
| OpenBao down or sealed | [When OpenBao is down](#when-openbao-is-down), [runbooks/incidents.md](runbooks/incidents.md#openbao-sealed) |

Three settings turn it on; a third member needs nothing else:

```yaml
# installations/<inst>/installation.yaml
mgmt:
  addons:
    openbao: true               # the mesh CA (OpenBao PKI) + reader-cert admission guards on mgmt
mesh:
  groups: [local]               # one root + one intermediate per group, keys generated inside OpenBao
  ca: { host: openbao.openchoreo.localhost, port: 8200 }   # where members reach OpenBao (TLS passthrough)

# installations/<inst>/clusters/<name>.yaml (every member)
mesh:
  group: local                  # meshID; network = cluster name
```

## Istio 1.32 status (what is GA, beta, alpha)

| Piece | Status in 1.32 | Used here |
|---|---|---|
| Ambient mode (ztunnel, istio-cni, L4 policy, waypoints) | GA (since 1.24) | yes |
| Ambient **multi-primary, multi-network** multicluster | **Beta** ("production ready" per the 1.32 docs, promoted in 1.29). The CNCF announced it as GA at KubeCon NA 2026 (10 Nov 2026), but the 1.32 docs and flags still call it beta: off by default behind `AMBIENT_ENABLE_MULTI_NETWORK`. **VERIFY** in the next release notes | yes |
| `istio-east-west` GatewayClass (Gateway API, HBONE listener, double HBONE) | ships with multi-network ambient; exists only while istiod runs with `AMBIENT_ENABLE_MULTI_NETWORK=true` | yes |
| `AMBIENT_ENABLE_BAGGAGE` (peer metadata across networks, correct metrics labels) | recommended with multi-network | yes |
| Ambient multicluster on a **single network** | alpha, untested upstream | no (every cluster is its own network) |
| Primary-remote (one istiod for several clusters) | not supported in ambient | no (every member runs its own istiod) |
| Ambient + sidecars in one multicluster mesh | not recommended upstream | no (ambient only) |
| Service scope `istio.io/global` label (default `serviceScopeConfigs`) | part of ambient multicluster | yes |
| External CA via istio-csr (`ENABLE_CA_SERVER=false`, `caAddress`) | supported (cert-manager istio-csr, ztunnel node authorisation via `--ca-trusted-node-accounts`) | yes, on members |
| Gateway API `Gateway` v1 + `infrastructure.parametersRef` | GA (standard channel, v1.5.1 installed) | yes |
| `security.istio.io/v1` `AuthorizationPolicy` | GA | yes |

Upstream limitations that apply: service scope must be the same on every cluster (only the local cluster's
`istio.io/global` label counts), waypoints must have the same names everywhere, and load to a remote network is not
spread evenly (one remote endpoint can take a large share; istio/istio#58039).

## How a call travels

```
dev1                                                    prod1
client pod --(captured)--> ztunnel(dev1) ==HBONE in HBONE==> east-west gw (prod1) --HBONE--> ztunnel(prod1) --> echo pod
   echo.<ns>:8080                 outer mTLS: ztunnel(dev1) <-> gateway (15008)
                                  inner mTLS: ztunnel(dev1) <-> ztunnel(prod1), end to end (client identity kept)
```

- The Service (`echo` here) exists in **both** clusters, so DNS resolves in dev1, and carries `istio.io/global=true`.
  dev1's istiod merges prod1's endpoints (seen through the remote secret) behind the hostname; because they sit on
  network `prod1`, dev1's ztunnel sends the call to prod1's east-west gateway, not the pod IP. Pod CIDRs may overlap.
- The gateway terminates only the outer tunnel: authorization at the destination sees the caller's identity
  `cluster.local/ns/<ns>/sa/client`, not the gateway's.
- Each cluster's network is its name. ztunnel's `NETWORK`, the istio-system label `topology.istio.io/network` and the
  Gateway label must agree; all come from one label (below).

## Configuration flow

`charts/cluster` turns `mesh.group` into labels on the CAPI `Cluster` and the Argo CD cluster secret. Everything else
selects or reads those labels; no template names a cluster.

| Label (derived) | Consumed by |
|---|---|
| `mesh.platform.koorikla.io/group: <group>` | catalog `clusterLabelParameters` → addon mesh `global.meshID`; CRS selector of the peers' remote secrets |
| `mesh.platform.koorikla.io/network: <name>` | addon mesh `global.network` (ztunnel `NETWORK`); east-west Gateway label |
| (the group label, via the ApplicationSet's `values/mesh-<member\|none>.yaml`) | addon mesh layers `values/mesh-member.yaml`: istio-csr + Vault Issuer, east-west gateway + reader RBAC, istiod CA off, `AMBIENT_ENABLE_MULTI_NETWORK` / `AMBIENT_ENABLE_BAGGAGE` |

`global.multiCluster.clusterName` is the cluster name on **every** cluster (catalog `clusterNameParameters`), so istiod
and ztunnel agree on the cluster ID. Clusters outside the mesh keep network and meshID empty: if ztunnel and istiod
disagreed on the network, local traffic would go to a gateway that does not exist. The catalog's generic field:

```yaml
clusterLabelParameters: { <helm param>: { label: <cluster secret label>, default: <string> } }
# -> '{{ $v := index .metadata.labels "<label>" }}{{ if $v }}{{ $v }}{{ else }}<default>{{ end }}' (forceString)
```

| Where | What | Owner |
|---|---|---|
| mgmt, `openbao` | OpenBao (StatefulSet, raft, TLS), Gateway + TLSRoute `openbao`, reconcile Job/CronJob `mesh-reconcile`, ExternalSecrets `openbao-unseal`, `mesh-clients`, `openbao-ca-bundle`, ClusterSecretStore `mgmt-openbao`; ValidatingAdmissionPolicies `platform-mesh-*` (reader certs) | addon `openbao` (mgmt, opt-in) |
| mgmt, OpenBao | static (self-initialisation, once): policies `mesh-member` (templated), `mesh-ca-read`, `platform-mesh-config`, `platform-mesh-bootstrap` and their Kubernetes auth roles | `addons/openbao/values.yaml` |
| mgmt, OpenBao | per group: mounts `pki-mesh-<group>-root`, `pki-mesh-<group>-int`; per member: role `<name>` in its group's intermediate, identity entity `mesh-<name>` (metadata `cluster`, `group`), JWT auth mount `auth/mesh-<name>` | `addons/openbao/files/mesh-reconcile.sh` |
| mgmt, `fleet` | `ExternalSecret <name>-mesh-openbao` (the member's API server URL + cluster CA certificate for OpenBao); `ExternalSecret` + `ConfigMap <name>-mesh-oidc` + `ClusterResourceSet <name>-mesh-trust` (public certificates, network label, issuer-discovery binding) | `charts/cluster` `templates/common/mesh-openbao.yaml`, `mesh-trust.yaml` |
| mgmt, `fleet` | `Issuer <name>-client-ca` (over `<name>-cca`), `Certificate <name>-mesh-reader`, `ExternalSecret` + `ClusterResourceSet <name>-mesh-remote-secret` | `charts/cluster` `templates/common/mesh-remote-secret.yaml` |
| member, `istio-system` | istio-csr, `Issuer openbao-mesh` (cert-manager Vault issuer), ServiceAccount `istio-csr-openbao`, `Certificate istiod`; ValidatingAdmissionPolicies `platform-mesh-ca-*` | addon `mesh` (istio-csr) |
| member, `istio-system` | `Gateway istio-eastwestgateway` (+ params ConfigMap), `ClusterRole`/`ClusterRoleBinding`/`Role`/`RoleBinding platform-istio-reader` | addon `mesh` (east-west) |
| member, `istio-system` | istiod/ztunnel multicluster values, istiod CA off (`values/mesh-member.yaml`) | addon `mesh` (catalog parameters) |
| member, `istio-system` | `Secret openbao-ca`, `Secret mesh-root-ca` (public certificates), label on the namespace, `Secret istio-remote-secret-<peer>` per peer; cluster-scoped `ClusterRoleBinding platform-oidc-discovery` | CAPI ClusterResourceSets (from mgmt) |

## Mesh CA (OpenBao)

Every member of a group chains to the same root, so a dev1 workload certificate verifies in prod1. The CA is
OpenBao's PKI engine on mgmt: **no CA private key exists on any workload cluster** ([conventions.md](conventions.md)
invariant 4) and none is ever exported from OpenBao.

```
member (istio-system)                                          mgmt (openbao)
ztunnel / gateways --CSR--> istio-csr --CertificateRequest--> cert-manager Vault Issuer openbao-mesh
                                                                 | JWT login: projected token of SA istio-csr-openbao,
                                                                 |   audience vault://istio-system/openbao-mesh
                                                                 v   (TLS passthrough via kgateway, mesh.ca.host:port)
                                                    auth/mesh-<name> --entity mesh-<name>, policy mesh-member-->
                                                    pki-mesh-<group>-int/sign/<name>  (intermediate key inside OpenBao)
                                                    pki-mesh-<group>-root             (root key inside OpenBao)
```

- **One root and one intermediate per group** (`mesh.groups`). The reconcile's Job (Argo CD Sync hook, wave 1;
  bootstrap identity) creates `pki-mesh-<group>-root` (`root/generate/internal`, EC P-384, 10y) and
  `pki-mesh-<group>-int` (`intermediate/generate/internal`, EC P-256, signed by the root with `max_path_length=0`).
  `internal` means OpenBao never returns the key; every reconcile policy denies `generate/exported`, key
  import/rotation and `sign-verbatim`, and nobody is granted `sys/raw`. A fleet file's `mesh.group` must be listed
  (charts/cluster fails otherwise).
- **A group is a cryptographic boundary.** A member of group A reaches only group A's intermediate, so it cannot get
  an identity group B accepts. All groups still share trust domain `cluster.local` (per-environment trust domains:
  [#71](https://github.com/koorikla/platform/issues/71)).
- **Groups follow trust levels.** Clusters of different environments or trust levels never share a group. `local`
  (dev1 + prod1 on one laptop) is the deliberate demo exception; real installations use e.g. `dev` and `prod`.
- **One role per member**, `pki-mesh-<group>-int/roles/<name>`: URI SANs `spiffe://cluster.local/ns/*/sa/*` only, DNS
  names only `istiod.istio-system.svc` and `cert-manager-istio-csr.istio-system.svc` (istiod's and istio-csr's serving
  certs), no IP SANs, wildcards, subdomains or CA certificates, `ttl` 24h, `max_ttl` 48h, `no_store` (nothing to
  revoke, [below](#when-openbao-is-down)).
- **Per-member authentication without static tokens.** `auth/mesh-<name>` is a JWT auth mount that verifies tokens
  against that member's API server keys (`<server>/openid/v1/jwks`, TLS pinned to the member's cluster CA). Its only
  role accepts subject `system:serviceaccount:istio-system:istio-csr-openbao` and audience
  `vault://istio-system/openbao-mesh` (what cert-manager requests for a Vault issuer's `serviceAccountRef`) and issues a
  10-minute batch token with static policy `mesh-member`: `create`/`update` on
  `pki-mesh-{{identity.entity.metadata.group}}-int/sign/{{identity.entity.metadata.cluster}}`. The reconcile binds the
  mount's alias for that subject to entity `mesh-<name>` (metadata `cluster=<name>`, `group=<group>`) before the role
  exists, so the template resolves to exactly `pki-mesh-<group>-int/sign/<name>`. A token is useless at another
  member's mount (other keys) and reaches no other role, mount or path (integration test: a same-named role in another
  group, or another role in its own group, answers 403).
- **On the member** only cert-manager's controller may mint that ServiceAccount's tokens (`Role` on
  `serviceaccounts/token`, `resourceNames`), and only for Issuer `openbao-mesh`. OpenBao accepts any token of that
  subject and audience, so `ValidatingAdmissionPolicy platform-mesh-ca-issuers` (addon mesh,
  `templates/csr-admission.yaml`) denies every other Issuer or ClusterIssuer naming ServiceAccount `istio-csr-openbao`
  or audience `vault://istio-system/openbao-mesh` (a second Vault Issuer would bypass `platform-mesh-ca-requests`, which
  matches `issuerRef.name == openbao-mesh` only).
- **Issuer discovery is public and delivered first.** OpenBao fetches the JWKS without a credential, so every member
  binds read-only ClusterRole `system:service-account-issuer-discovery` (GET `/.well-known/openid-configuration` and
  `/openid/v1/jwks`, nothing else) to `system:unauthenticated` (`ClusterRoleBinding platform-oidc-discovery`, upstream's
  setup for an external relying party). It ships in `ClusterResourceSet <name>-mesh-trust` from a static `ConfigMap
  <name>-mesh-oidc` (no ESO, no OpenBao), so it applies as soon as the member's API server is up, before the reconcile
  configures `auth/mesh-<name>` (an addon would sync too late). The keys are public; minting a token still needs the
  member's signing key. OpenBao's JWT auth has no authenticated JWKS fetch; TokenReview (a member credential on mgmt)
  and static `jwt_validation_pubkeys` (admin kubeconfig in the reconcile, manual rotation) were rejected. Next
  hardening: `AuthenticationConfiguration` `anonymous.conditions` in the ClusterClasses, limiting anonymous requests to
  these paths.
- **Member inputs come from the fleet file.** charts/cluster renders `ExternalSecret <name>-mesh-openbao` in `fleet`:
  only the API server URL and cluster CA certificate from the CAPI kubeconfig (both public), labelled
  `mesh.platform.koorikla.io/openbao-client`. Addon openbao's `ExternalSecret mesh-clients` collects them by label (store
  `mgmt-fleet`). Its template accepts a Secret only if named exactly `<cluster>-mesh-openbao`; anything else (a Secret
  claiming another cluster's name, a missing `cluster`) becomes `rejected.<secret>`, which the reconcile logs and counts
  as invalid. Secret names are unique, so no two inputs claim one cluster. This does not authenticate the writer:
  anyone who may create Secrets in `fleet` can enrol a member `<x>` with their own JWKS and get signing rights for
  `pki-mesh-<group>-int/sign/<x>`. So write access to Secrets in `fleet` (which also holds every kubeconfig) is mesh-CA
  admin access. A new member is configured within one ESO refresh plus the 5-minute CronJob; a removed one's auth
  mount and entity go on the next run (an empty input set prunes nothing, so an ESO outage cannot wipe the mesh).
- **One member cannot fail the fleet.** A member whose API server is unreachable or JWKS not yet readable is logged
  `FAILED` and skipped; its existing auth mount is kept while it is in the inputs. Each run ends with
  `done: configured=[...] failed=[...] invalid=[...]`, also the pod's termination message. Job and CronJob fail on
  invalid groups, a failed login or group bootstrap, or when every input is invalid. When no member could be configured
  the **CronJob** fails (failed Jobs, `kube_job_status_failed`) but the **Sync-hook Job exits 0** with a `WARNING`: on a
  cold boot members register before they are reachable, and the hook must not leave the openbao Application
  `SyncFailed` for what the CronJob converges. Check the logs (command at the top) or
  `kubectl -n openbao get pods -l app.kubernetes.io/name=mesh-reconcile -o
  jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].state.terminated.message}{"\n"}{end}'`.
- **Public trust delivery.** ESO reads each group root (`pki-mesh-<group>-root/cert/ca`, OpenBao role `mesh-ca-read`:
  read `+/cert/ca` plus `auth/token/lookup-self` and `revoke-self`, which ESO's vault provider uses to validate the
  store and close its client) into `openbao/openbao-ca-bundle` together with OpenBao's TLS CA certificate. Store
  `mgmt-openbao` may GET only that Secret (name-scoped RBAC, namespace `fleet`). `ClusterResourceSet <name>-mesh-trust`
  delivers `istio-system/openbao-ca` (verifies OpenBao's listener), `istio-system/mesh-root-ca` (istio-csr pins it as
  its root; cert-manager's `ca.crt` must match) and the namespace label `topology.istio.io/network=<name>`. Contract
  tests assert that no ClusterResourceSet payload or workload-cluster ExternalSecret reads a CA private key
  (`spec.data`, `dataFrom.extract` of a CA Secret, any `dataFrom.find`), for every cluster of every installation; a
  cluster or workload addon that does not render fails the test.
- **istiod has no CA on members** (`values/mesh-member.yaml`: `ENABLE_CA_SERVER=false`, `caAddress` = istio-csr).
  istio-csr answers ztunnel's and gateways' CSRs (ztunnel is a trusted node account) and issues istiod's serving
  certificate (`Certificate istiod`, 48h, renewed after 24h). istiod decides once at start whether it has serving certs,
  so it mounts `Secret istiod-tls` and `ConfigMap istio-ca-root-cert` as non-optional volumes and reads them
  (`--tlsCertFile`/`--tlsKeyFile`/`--caCertFile`): it stays `ContainerCreating` until istio-csr wrote both, with no
  silent fallback to a self-signed root (the chart's optional mount is filled only after start, leaving `:15012`
  without xDS TLS).

### Configuration as code, no root token

OpenBao's [self-initialisation](https://openbao.org/docs/configuration/self-init/) (`initialize` blocks in the server
config, `addons/openbao/values.yaml`) runs once on first start: it enables the file audit device to stdout and
Kubernetes auth for mgmt ServiceAccounts, writes **every mesh ACL policy**, every mgmt identity and the policy
reconciler's narrow identity, then **revokes its own root token**. Self-initialisation creates no recovery keys, so
nobody can `generate-root` later, not even with the unseal key (`task test:openbao` checks this). From then on
`files/mesh-reconcile.sh` (Sync-hook Job + CronJob, idempotent, POSIX sh + the pinned `bao` CLI) applies the desired
state from git, logging in with projected, audience-bound ServiceAccount tokens (15-minute OpenBao tokens, no
Kubernetes API access); it **authors no ACL policy**.

#### Who may do what in OpenBao

| Identity (Kubernetes auth role) | Used by | May | May not (403, `task test:openbao`) |
|---|---|---|---|
| `platform-mesh-bootstrap` (SA `openbao/openbao-mesh-bootstrap`) | Sync-hook Job only | mount `pki-mesh-*` (type `pki` only); `root/generate/internal`, `intermediate/generate/internal`, `root/sign-intermediate` with `max_path_length=0` only, `intermediate/set-signed` | write any policy or auth method, enrol members, any `exported` generation, key/issuer import, `config/ca`, `sign-verbatim`, `sign-self-issued`, `cross-sign`, root rotation, issuing or signing leaves |
| `platform-mesh-config` (SAs `openbao-mesh-config`, `openbao-mesh-bootstrap`) | CronJob + Sync-hook Job | enable/configure `jwt` auth at `auth/mesh-*` (type pinned to `jwt`, roles may only carry policy `mesh-member`); write `<mount>/roles/<name>` with every widening flag pinned (`required_parameters` + `allowed_parameters`: no any-name, IP SANs, localhost, globs, wildcards, subdomains, other SANs, URI templates, code-signing/email EKUs; `no_store`, `issuer_ref=default`); write identity entities `mesh-*` (metadata only, no policies) and their aliases | everything above, plus any CA operation: no mount, no key generation, no `sign-intermediate` (not CA-equivalent) |
| `mesh-member` (templated) | members' istio-csr (JWT, batch tokens) | `pki-mesh-<group>-int/sign/<name>` of its own entity | everything else |
| `mesh-ca-read` (SA `eso-openbao-pki-public`) | ESO | read `+/cert/ca` (public); `auth/token/lookup-self`, `auth/token/revoke-self` (its own token) | everything else |
| `platform-policy-reconciler` (SA `openbao/openbao-policy-reconciler`, 5-minute tokens) | CronJob `policy-reconcile` ([below](#policies-from-git-the-policy-reconciler)) | write, delete and list ACL policies named `tenant-*`; create/update exactly the roles `tenant-config` and `tenant-writer` with every parameter pinned (ServiceAccount, namespace, audience, policy, no default policy, 15m TTLs); revoke its own token | any other policy name (`mesh-*`, `platform-*`, `default`), its own policy or role, any other or widened Kubernetes auth role, reading roles, Kubernetes auth config, PKI, mounts, auth methods, identities, secrets, tokens, `generate-root`, `sys/raw` |
| `tenant-config` (SA `openbao-tenant-config`; role and policy written by the policy reconciler) | CronJob `tenant-reconcile` ([tenant secrets](#tenant-secrets-openbao)) | mount `kv-tenant-*` (type `kv` only; no delete); enable/configure `jwt` auth at `auth/tenants-*` whose roles may only carry `tenant-read`; entities `tenant-*` (metadata only) and their aliases | read or write any secret (`kv-tenant-*` denied), any policy, Kubernetes auth roles, anything of the mesh (`auth/mesh-*`, `pki-*`) |
| `tenant-read` (templated) | per-namespace `SecretStore`s on members (JWT, `auth/tenants-<cluster>`) | read `kv-tenant-<tenant>/data/*`, list its metadata, of its own entity's `tenant`; token self-operations | everything else |
| `tenant-write` (templated, role `tenant-writer`) | SA `openbao-tenants/<tenant>-writer` on mgmt | write `kv-tenant-<tenant>/` of its own entity, incl. key metadata (ESO marks pushed keys `managed-by`) | everything else |

The reconcile identities are **mesh CA administrators, not OpenBao administrators**: only the bootstrap identity can
sign an intermediate (CA-equivalent), and only the Sync-hook Job holds it; the config identity decides which JWKS a
`mesh-<name>` mount trusts. Whoever can create pods or ServiceAccount tokens in namespace `openbao` can use them and,
with the static seal, holds the unseal key: protect namespace `openbao` like the CA (Argo AppProject + RBAC;
production: KMS seal, [#31](https://github.com/koorikla/platform/issues/31)).

The mesh policies and mgmt identities apply only on first start; changing them later means re-initialising OpenBao
([break-glass.md](runbooks/break-glass.md#openbao-local-re-initialization), new mesh roots). Tenant policies change from
git at any time (next section). `hack/tests/test_openbao_reconcile.sh` and `hack/tests/test_openbao_policy_reconcile.sh`
check that the self-init roles and the addon values name the same ServiceAccounts and values, so a rename cannot lock a
reconcile out.

#### Policies from git: the policy reconciler

`files/policies/tenant-*.hcl` are the tenant ACL policies (`tenant-read`, `tenant-write`, `tenant-config`). CronJob
`policy-reconcile` (`files/policy-reconcile.sh`, every 5 minutes, final sync wave, only with
`secrets.tenantStores.enabled`) logs in as `platform-policy-reconciler` and:

1. writes each file as the policy of the same name when the stored text differs (drift is restored);
2. deletes `tenant-*` policies without a file, never when there are zero files;
3. writes the Kubernetes auth roles `tenant-config` and `tenant-writer`.

A file not named `tenant-*` fails the render and the script refuses it. The identity's policy (self-initialisation,
`initialize "policy-reconciler"`) pins every parameter (table above). It can write *any content* into a `tenant-*`
policy, so a compromised reconciler pod could widen tenant tokens; its trust boundary is namespace `openbao`, like the
mesh reconcile's.

Non-tenant policies (`mesh-*`, `platform-*`) are not reconcilable (whoever writes them is CA-equivalent or could lift
the reconciler's bounds): they change only by re-initialisation. A "grant root, then revoke" Job is impossible (no
recovery keys; the static seal key is not a key share). An installation initialised before the policy reconciler existed has no identity that may write a policy and gets it
only through one re-initialisation ([break-glass.md](runbooks/break-glass.md#openbao-local-re-initialization); new mesh
roots, members re-enrol); after that, tenant policy changes come from git.

Rejected: Terraform/OpenTofu (state and a runner outside GitOps), OpenBao config operators (young, a privileged
controller with a broad token). The script is ~150 lines, tested against a fake CLI
(`hack/tests/test_openbao_reconcile.sh`, `task test`) and the real pinned image (`task test:openbao`, docker).

### Unseal

Locally OpenBao uses the **static seal** (`seal "static"`, AES-256-GCM key from the secret backend): `task secrets` seeds
`openbao-unseal` once in the `platform` store, ESO mounts it, and OpenBao unseals itself on every start. That puts the
key next to the data: laptop only. **Production**: a cloud KMS seal (`seal "awskms"` with IRSA / Pod Identity, no static
keys) or `seal "transit"` against a separate OpenBao, and 3 raft replicas ([#31](https://github.com/koorikla/platform/issues/31)).
Backup/restore of the raft directory + unseal secret, sealed triage and local re-initialisation:
[runbooks/backup-restore.md](runbooks/backup-restore.md#3-openbao-raft-storage-and-unseal-key),
[runbooks/incidents.md](runbooks/incidents.md#openbao-sealed),
[runbooks/break-glass.md](runbooks/break-glass.md#openbao-local-re-initialization).

### When OpenBao is down

Running workloads keep working; nothing new gets an identity:

| | Effect while OpenBao (or the path to it) is down |
|---|---|
| existing pods, ztunnel, gateways | keep their certificates; ztunnel renews at half-life, so a workload certificate (24h) lasts >= 12h after the last renewal |
| istiod | keeps serving with its 48h cert (renewed after 24h): >= 24h |
| new pods / restarted ztunnel | get no certificate until OpenBao is back (traffic from them fails closed) |
| reconcile, new members | wait; the CronJob retries every 5m |

The outage budget is about 12 hours for workloads. TTLs trade that budget against exposure: Istio checks no CRL or OCSP,
so a leaked workload certificate is valid until `notAfter` (<= 24h, istiod's <= 48h). Cut off a compromised member at
once by deleting its auth mount (remove `mesh.group` from the fleet file); its certificates expire within a day. The
7-day reader client certs (remote secrets) cannot be revoked either.

### Bootstrapping order

1. mgmt: `task secrets` seeds `openbao-unseal`; addon openbao starts, self-initialises, unseals. Sync waves: 0 OpenBao
   (Ready = unsealed), 1 the `mesh-reconcile` Job (Sync hook) creates the group mounts, 2 store `openbao-pki-public`,
   `openbao-ca-bundle` and the CronJob. Not PostSync: a PostSync hook runs only once every resource is Healthy, and
   `openbao-ca-bundle` cannot be before the roots exist (contract: `hack/tests/test_mesh_ca_sync_order.sh`). The CronJob
   is in the final wave because a final-wave resource that degrades later does not fail a sync.
2. A member's fleet file gets `mesh.group`: charts/cluster labels the Cluster and renders `<name>-mesh-openbao`.
   `ClusterResourceSet <name>-mesh-trust` applies the issuer-discovery binding as soon as the API server is up, then the
   public certificates once ESO has them. The next reconcile creates `auth/mesh-<name>`, PKI role and entity, or
   reports the member `FAILED` (JWKS not readable yet) and retries in 5 minutes.
3. On the member, cert-manager (catalog default) and the istio-csr part of addon mesh come up; the Vault issuer turns
   Ready once OpenBao accepts its login; istio-csr issues istiod's cert. istiod (gated) starts, then ztunnel (sync wave 1).

### Admission guards

cert-manager's internal approver approves every CertificateRequest, and a CA issuer signs whatever it is asked.

On mgmt, the `<name>-client-ca` Issuers (the k3s client CA of a workload cluster: its API server accepts anything they
sign, `O=system:masters` included) are guarded by addon openbao's ValidatingAdmissionPolicies
(`admissionregistration.k8s.io/v1`, Deny):

| Policy | Admits |
|---|---|
| `platform-mesh-reader-certificates` | Certificates for a `*-client-ca` issuer: in `fleet`, `CN=platform:istio-reader`, no subject (no O/OU = no groups), no SANs, not a CA, usages client auth + digital signature, duration set and <= 168h |
| `platform-mesh-certificaterequests` | CertificateRequests for them: created by cert-manager's controller only (so they come from an admitted Certificate; CEL cannot parse the CSR), in `fleet`, same profile |
| `platform-mesh-issuers` | a `<x>-cca` Secret may back only `Issuer fleet/<x>-client-ca` |

On members, OpenBao's role limits *what* can be signed (SPIFFE IDs of the trust domain); addon mesh (istio-csr part)
limits *who* may ask: `platform-mesh-ca-requests` admits CertificateRequests for `Issuer istio-system/openbao-mesh` only
from istio-csr's or cert-manager's ServiceAccount and never as a CA; `platform-mesh-ca-certificates` admits only the
chart's `Certificate istio-system/istiod` for that issuer. Otherwise anyone allowed to create CertificateRequests in
`istio-system` could mint any SPIFFE identity of the mesh.

`hack/tests/test_mesh_admission.sh` evaluates the CEL offline with the kyverno CLI: rendered objects pass; the negative
cases (system:masters, other CNs, sub-CAs, long durations, SANs, other namespaces, hand-made requests, rogue issuers,
workload ServiceAccounts) are denied.

### Root and intermediate rotation

A planned procedure, not a renewal (the intermediate lives 5 years inside OpenBao; issued certificates are the
short-lived part): generate a new root next to the old one, publish both in `mesh-root-ca` (a trust bundle), switch the
intermediate to the new root, then drop the old root. Tracked in [#71](https://github.com/koorikla/platform/issues/71).

## Tenant secrets (OpenBao)

Tenants never share a secret store ([#96](https://github.com/koorikla/platform/issues/96)). With `installation.yaml
secrets.tenantStores.enabled` (on in `local`; needs `mgmt.addons.openbao` and mesh members) every OpenChoreo cell
namespace on a workload cluster has its own `SecretStore openbao-tenant`, and the OpenBao that is the mesh CA holds one
KV v2 mount per tenant (tenant = OpenChoreo project). Developer steps: [openchoreo.md](openchoreo.md#application-secrets-developer-view).

| Where | What | Rendered by |
|---|---|---|
| mgmt `openbao-tenants` | `Secret <project>-openbao-tenant` (the project's cell namespaces, computed like OpenChoreo 1.3.3 names them: `dp-<org>-<project>-<env>-<sha256[:8]>`), `ServiceAccount <project>-writer` | charts/tenant |
| mgmt `openbao-tenants` | `Secret <project>-openbao-tenant-<environment>` per open PR preview (data `tenant`, `environment`; the reconcile computes the preview's cell namespace the same way and adds it to that tenant only, if the tenant has a descriptor above; [previews](preview-environments.md#isolation-and-policy-tier), #267) | addon openbao, Kyverno `GeneratingPolicy platform-preview-tenant-secrets` on preview ProjectReleaseBindings (synchronised) |
| OpenBao | `kv-tenant-<project>`; entity `tenant-<project>` (metadata `tenant`, the writer's alias); per member `auth/tenants-<cluster>` (jwt, the member's JWKS like `auth/mesh-<cluster>`) with role `<project>` = exactly the `openbao-tenant` ServiceAccount of those namespaces, audience `openbao-tenant-secrets`, policy `tenant-read`; one entity `tenant-<project>.<cluster>.<namespace>` (metadata `tenant`) per namespace, because OpenBao gives an entity only one alias per auth mount | addon openbao, CronJob `tenant-reconcile` (`files/tenant-reconcile.sh`, every 5 min) |
| member, each cell namespace | `ServiceAccount` + `SecretStore openbao-tenant`: vault provider, `path: kv-tenant-<project>`, JWT login with a 10-minute projected token, CA from `istio-system/openbao-ca` | addon secret-stores, Kyverno `GeneratingPolicy platform-tenant-secret-store` (synchronised) |
| member | `ClusterSecretStore default`: conditions exclude namespaces labelled `openchoreo.dev/project`; VAPs: tenant `ExternalSecret`/`PushSecret`s may reference only `SecretStore openbao-tenant` (no `ClusterSecretStore`, `ClusterGenerator`, other store or label selector), `SecretStore`s there are written only by Kyverno | addon secret-stores |
| OpenChoreo | component types render `SecretReference`s as `ExternalSecret`s on `SecretStore openbao-tenant` (`refreshInterval: 15s`): developers never name a store; `remoteRef.key` is the key inside their own mount | addon openchoreo-platform |

OpenBao enforces isolation, not naming. Policies come from git (`files/policies/`, written by the
[policy reconciler](#policies-from-git-the-policy-reconciler); the tenant reconcile writes none) and are templated on the
caller's entity, so a token reaches only `kv-tenant-<its entity's tenant>`; a login whose alias the reconcile did not
bind resolves to an entity without metadata and reaches nothing. A namespace two descriptors claim is bound to neither.
A tenant removed from git loses its roles and entities at once, a namespace that leaves a tenant its entity; the mount
(the data) stays. Tests: `hack/tests/test_openbao_tenant_reconcile.sh` (fake CLI, `task test`), the tenant section of
`task test:openbao` (real OpenBao: tenant A's token is denied on tenant B's mount, writers and the reconcile identity
confined), `tests/vap` of addon secret-stores (kyverno CLI).

Running pods keep the old value until restarted; the component types make Reloader roll them
([runbook](runbooks/certificates-and-secrets.md#7-tenant-application-secrets-openbao)). Tenant self-service (OpenBao
UI/CLI with OIDC from Thunder and a per-tenant group) and per-tenant build secrets on mgmt (`workflows-<org>` is shared
by all projects of an org) are follow-ups: [#169](https://github.com/koorikla/platform/issues/169).

### Writing a secret

The value never goes through git. Whoever may mint a token for `openbao-tenants/<project>-writer` (Kubernetes RBAC on
mgmt; platform operators by default) writes to the tenant's mount:

```bash
K="kubectl --context k3d-platform-mgmt"
# line 1: a 10-minute token of the writer ServiceAccount (`create token` prints no newline when piped: the `echo` ends
# the line); the rest: the value (here from a local file, never echoed, without a trailing newline)
{ $K -n openbao-tenants create token demo-writer --audience openbao --duration 10m; echo; tr -d '\n' < ./db-password; } \
  | $K -n openbao exec -i openbao-0 -- sh -c 'read -r jwt
      BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=tenant-writer jwt="$jwt") bao kv put kv-tenant-demo/db password=-'
```

The app consumes it with an OpenChoreo `SecretReference` (`remoteRef: {key: db, property: password}`) named in its
Workload.

### Demo values

Local installation only, zero-touch after `task down && task up`. A tenant file may list `demoSecrets: [{key,
property}]` (`installations/local/tenants/demo.yaml`: `hello-world`/`greeting`, the remoteRef of hello-world's
`SecretReference`). charts/tenant then renders three ESO objects in `openbao-tenants`, all in the final sync wave
(`templates/demo-secrets.yaml`):

| Object | What it does |
|---|---|
| `SecretStore <project>-openbao-writer` | logs in like the command above: as `<project>-writer`, role `tenant-writer` (never root, only its own mount) |
| `Password <project>-demo-value` | generates `demo-only-<24 hex>` inside ESO (never in git or a log) |
| `PushSecret <project>-seed-<key>` | one per entry: writes the property only if it is missing (`updatePolicy: IfNotExists`, new keys with `cas=0`), never deletes it (`deletionPolicy: None`) |

- An existing value is never overwritten, so a hand-written value or a rotation wins; a key removed completely
  (`bao kv metadata delete`) is seeded again within `refreshInterval` (5 minutes).
- One entry per key (a lowercase DNS label: it names the PushSecret). ESO writes only into keys it created (custom
  metadata `managed-by=external-secrets`, allowed by policy `tenant-write`): a hand-written key that lacks the property
  is not patched; the PushSecret reports `secret not managed by external-secrets`.
- Until OpenBao and `tenant-reconcile` (mount + writer alias) exist, store and PushSecrets are not Ready and ESO
  retries with backoff (up to ~17 minutes), without holding any sync. Retry now:
  `kubectl --context k3d-platform-mgmt -n openbao-tenants annotate pushsecret <name> force-sync=$(date +%s) --overwrite`.
- OpenBao's CA reaches the store as `openbao-tenants/openbao-ca` (ExternalSecret of addon openbao through
  `ClusterSecretStore mgmt-openbao`, public certificate only).
- Never list real secrets there. Tests: `hack/tests/test_tenant_demo_secrets.sh` (every remoteRef of the vendored
  hello-world SecretReference is seeded; pins shared with addon openbao; IfNotExists, deletionPolicy None, final wave;
  kubeconform against the ESO CRDs) and `charts/tenant/tests/demo_secrets_test.yaml`.

## Discovery: declarative remote secrets

Each istiod watches the other members' API servers (Services, EndpointSlices, Pods, Namespaces) through a remote secret:
`istio-system/istio-remote-secret-<peer>`, labelled `istio/multiCluster=true`, holding a kubeconfig. **Each cluster's
own chart publishes its remote secret to every other member of its group**:

1. `Issuer <name>-client-ca`: a cert-manager CA issuer over `fleet/<name>-cca`, the k3s **client CA** that
   cluster-api-k3s generates and keeps on mgmt. That API server already trusts it for client authentication (the CAPI
   admin kubeconfig is signed by it). cert-manager only reads that Secret.
2. `Certificate <name>-mesh-reader`: client cert `CN=platform:istio-reader`, no organisation (so no groups), ECDSA,
   **7 days**, renewed after 4. Kubernetes cannot revoke client certificates, hence the short lifetime.
3. On the member, addon `mesh` (`templates/eastwest-reader-rbac.yaml`) binds user `platform:istio-reader` to
   `ClusterRole platform-istio-reader` (read-only discovery; Secrets only on opt-in, [Reader RBAC](#reader-rbac-what-a-peer-may-read)).
4. `ExternalSecret <name>-mesh-remote-secret` (store `mgmt-fleet`, refreshed every 5m) builds the kubeconfig from the
   CAPI kubeconfig's endpoint and CA and the reader cert, written as JSON (no templated YAML indentation), as a
   ClusterResourceSet payload.
5. `ClusterResourceSet <name>-mesh-remote-secret` selects `mesh.platform.koorikla.io/group=<group>` and
   `platform.koorikla.io/name NotIn [<name>]`: a new member gets every existing member's secret and they get its. No
   file lists peers.

Rejected: `istioctl create-remote-secret` (imperative), the CAPI admin kubeconfig (cluster-admin for every peer), a
ServiceAccount token Secret (long-lived, legacy).

Peers must reach each member's API endpoint: locally the CAPD load balancer container on docker network `kind`, on AWS
the CAPA API ELB, on Hetzner the API load balancer.

### Reader RBAC: what a peer may read

Upstream's `istio-reader-clusterrole-istio-system` (istiod chart) grants cluster-wide get/list/watch on `secrets` and
`configmaps`, create/delete on MCS `serviceexports` and create on `tokenreviews`/`subjectaccessreviews`. Bound to the
reader user, every peer could read this cluster's istio-csr and istiod serving keys, the OpenChoreo agent identity and
every tenant Secret. So the reader is bound to the platform's own roles (addon `mesh`
`templates/eastwest-reader-rbac.yaml`), derived from what istiod 1.32.0 reads on a remote cluster:

| istiod 1.32.0 source | Remote reads | Granted |
|---|---|---|
| `pkg/kube/multicluster/cluster.go` (ambient KRT collections) | namespaces, pods, services, nodes, endpointslices, Gateway API gateways | `ClusterRole platform-istio-reader` get/list/watch |
| `serviceregistry/kube/controller` | the same + endpoints, MCS serviceimports, CRDs (delayed informers) | same |
| `PILOT_ENABLE_CROSS_CLUSTER_WORKLOAD_ENTRY` (default on) | networking.istio.io workloadentries | Istio config groups, read-only |
| remote mesh watcher (`controller/multicluster.go`) | ConfigMap `istio-system/istio` (trust domain), by field selector | `Role platform-istio-reader`, `resourceNames: [istio]` |
| remote credentials controller (`pilot/pkg/credentials/kube`) | Secrets list/watch, cluster-wide (istiod's own field selector skips Helm releases and SA tokens; RBAC cannot express that, so a grant covers them too). The data serves only gateways whose istiod is in another cluster (primary-remote), but the informer gates the peer's sync (below) | **none by default**; opt-in `reader.remoteCredentialsSecrets` (separate `ClusterRole platform-istio-reader-secrets`, list/watch) |
| leader election / namespace controller on remotes | only with `EXTERNAL_ISTIOD` | none |
| `serviceexports` writes, tokenreviews, SARs | `ENABLE_MCS_AUTO_EXPORT` (off), primary-remote proxy auth | none |

Peers can still read each other's Pods, Services and Istio config, so members of one group must sit at the same trust
level ([groups follow trust levels](#mesh-ca-openbao)).

#### The remote Secret informer (istiod 1.32.0): no knob keeps Secrets out and the peer in

From the 1.32.0 source (unchanged in 1.31.4 and on `release-1.32`):

- `PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` (istio/istio#59874, added for exactly this RBAC) crashes istiod
  (nil `*CredentialsController` per remote cluster, whose `HasSynced` `Cluster.Run` waits on: SIGSEGV once istiod has a
  remote secret). Fixed in istio/istio#62295 (nil-safe `HasSynced` and `Close`), **merged to `master` on 2026-11-03, not
  backported** (the bot refused its `cherrypick/release-1.31` and `cherrypick/release-1.32` labels, added by a non-org
  member); no 1.32.1 or 1.33 tag exists yet.
- With the controller on (default) and Secrets forbidden, its Secret informer never syncs; after
  `PILOT_REMOTE_CLUSTER_TIMEOUT` (30s) the peer is marked `timeout` and left out of the `RemoteClusters` collection the
  ambient index is built from: **the peer's services and workloads are not served**. istiod itself turns ready (the
  timeout counts as synced), which is why sidecar-mode reports on 1.29 (istio/istio#59845) called it harmless.
- No other knob helps: `PILOT_REMOTE_CLUSTER_TIMEOUT=0` blocks istiod's readiness, `ISTIO_WATCH_NAMESPACE` restricts
  every informer to one namespace, `PILOT_ENABLE_XDS_IDENTITY_CHECK=false` turns off XDS client authorisation, and RBAC
  cannot scope a cluster-wide list by field selector.

The choice is per installation (`installations/<inst>/addons/mesh/values.yaml`). **Decision: off in every installation,
`installations/local` included** (the opt-in is not approved): east-west discovery stays non-functional on istiod
1.32.0 (peers `timeout`, cross-cluster calls fail) until istio/istio#62295 ships. The mesh CA path does not depend on
it: every member's istiod and ztunnel get certificates from istio-csr, signed by the group intermediate in OpenBao,
which the live run proves.

| `reader.remoteCredentialsSecrets` | Effect |
|---|---|
| `false` (default, the B1 position) | peers read no Secret; cross-cluster discovery does not work on istiod 1.32.0 (`istioctl remote-clusters`: `timeout`) |
| `true` (**local/docker only**: the render fails for any other `cluster.provider`) | `ClusterRole platform-istio-reader-secrets` (list/watch on Secrets); peers are served. "No get" protects nothing: LIST returns every Secret's full `.data`, ServiceAccount-token Secrets included (the field selector is istiod's, not RBAC's). Blast radius: a compromised peer istiod of the group, or anyone holding the peer's `istio-remote-secret-<member>` or mgmt's `fleet/<member>-mesh-reader`, reads the member's API server key (`kube-system/k3s-serving`), the OpenChoreo agent identity, istio-csr/istiod serving keys and tenant Secrets for the 7-day certificate lifetime, on top of what a group peer can already do (mint any workload identity of the trust domain). Acceptable only for `installations/local` (dev1 + prod1 deliberately share a group on one laptop) |

Exit plan: once istio/istio#62295 is released (a 1.32 patch after an istio org member comments `/cherrypick
release-1.32`, or 1.33), set `PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` in addon mesh, remove
`reader.remoteCredentialsSecrets` and its ClusterRole, and update the negative unittest that forbids the flag. A forked
istiod with the two nil checks was rejected.

Unittests pin the rules and assert the negatives (default: no Secret rule; opt-in: list/watch only, separate objects,
fails the render outside docker; addon mesh never sets the flag). **VERIFY** on the live run: no istiod
restart/SIGSEGV; with the default, `istioctl remote-clusters` shows each peer `timeout`, istiod logs `failed to list
*v1.Secret ... forbidden` and `kubectl auth can-i --as platform:istio-reader list secrets -A` is `no`; with the opt-in,
each peer `synced`, no `forbidden`, and that `can-i` is `yes` (the exposure). Re-check this section on every Istio
upgrade.

### Removing a member (decommissioning)

Removing `mesh.group` (or the fleet file) revokes OpenBao issuance (`auth/mesh-<name>` and entity `mesh-<name>`). CRS
never deletes what it applied and Istio checks no revocation, so `istio-system/istio-remote-secret-<gone>` stays on the
remaining peers and `fleet/<gone>-mesh-reader` on `mgmt` (reader certs expire within 7d; workload/istiod certs within
24h/48h). Cleanup commands: [runbooks/scaling-and-capacity.md](runbooks/scaling-and-capacity.md#2-remove-decommission-a-workload-cluster).

## Verifying east-west with an OpenChoreo Component

Apps reach members as OpenChoreo objects, never as custom charts. The hello-world Component (docs/demo.md) is bound to
`development` on dev1 and, in the multicluster profile, to `production` on prod1; its cell namespaces carry
`istio.io/dataplane-mode=ambient`. Read-only checks:

```sh
kubectl --kubeconfig dev1.kubeconfig -n istio-system get gateway istio-eastwestgateway   # PROGRAMMED=True
istioctl --kubeconfig dev1.kubeconfig ztunnel-config workloads | grep hello-world        # prod1's pods, NETWORK prod1
```

prod1's hello-world pods listed on dev1 with network `prod1` prove discovery through the remote secret (on istiod 1.32.0
only with the [Reader RBAC](#reader-rbac-what-a-peer-may-read) opt-in). An end-to-end call needs a Service with the same
name and namespace on both members plus `istio.io/global=true`, which per-environment cell namespaces do not give; that
demo is #232.

## Reachability per provider

| | east-west gateway (Service type LoadBalancer, tcp 15008 + 15021 status) | peer API servers (tcp 6443) |
|---|---|---|
| local (CAPD) | klipper servicelb: `EXTERNAL-IP` = node container IP on docker network `kind`, which the other CAPD clusters reach directly (checked: servicelb hostPorts answer on both dev1/Cilium and prod1/flannel) | CAPD LB container IP on `kind` |
| AWS (CAPA + aws-ccm) | `values/provider-aws.yaml`: NLB (`aws-load-balancer-type: nlb`), internet-facing. CAPA's default node SG already admits NodePorts (30000-32767) for the NLB targets, so **no ClusterClass change**. `gateway.loadBalancerSourceRanges` (the peers' NAT gateway EIPs) is **required** outside docker: the render fails without it, so 15008/15021 are never open to 0.0.0.0/0. Also narrow CAPA's NodePort CIDRs (`AWSCluster.spec.network.nodePortIngressRuleCidrBlocks`). **VERIFY** NLB with aws-ccm and that CAPA keeps CCM-added SG rules | CAPA API ELB (`controlPlaneLoadBalancer.scheme` internet-facing by default); restrict 6443 via `controlPlaneLoadBalancer.ingressRules` to the peers' egress IPs (**VERIFY** CAPA's default ingress CIDRs) |
| Hetzner (CAPH + hcloud-ccm) | the template adds `load-balancer.hetzner.cloud/location: <region>` (hcloud-ccm needs a location or network zone). CAPH creates no firewall, so the LB reaches the node ports; `gateway.loadBalancerSourceRanges` is required here too. **VERIFY** that hcloud-ccm honours it | CAPH API LB (public) |

Only 15008 (HBONE) must be reachable between clusters for data; 15012/15017 (istiod xDS/webhook) don't cross clusters in
multi-primary, and API access is 6443 on the existing API load balancers. In real installations restrict both to the
peers' egress addresses.

**OpenBao on mgmt** (addon `openbao`, Gateway `openbao-gateway`, TLS passthrough on `mesh.ca.port`) exposes the whole
OpenBao API, including the unauthenticated `sys/health`, `sys/seal-status` and login endpoints. Locally k3d publishes
it on 127.0.0.1 only. Outside docker `gateway.loadBalancerSourceRanges` (the members' egress CIDRs,
`installations/<inst>/addons/openbao/values.yaml`) is **required** (the render fails without it); kgateway applies it to
the proxy Service through `GatewayParameters openbao-gateway`.

## Mixed CNIs (dev1 Cilium, prod1 flannel)

The mesh needs only node-level reachability between clusters, so the CNI doesn't matter. ztunnel runs inside each pod's
network namespace (istio-cni in-pod redirection) and dials the remote gateway's LoadBalancer IP; that traffic leaves
like any pod egress, SNATed to the node IP (Cilium iptables masquerade, since `bpf.masquerade: false` for ambient;
flannel's masquerade). The gateway's servicelb hostPort works under Cilium's kube-proxy replacement and under
kube-proxy (the OpenChoreo gateway uses the same mechanism on both clusters). On dev1 Cilium WireGuard encrypts
node-to-node traffic *inside* the cluster; between clusters HBONE mTLS is the encryption.

## Footprint (per member, requests)

| Component | CPU | Memory |
|---|---|---|
| east-west gateway (1 replica, `parametersRef`) | 50m | 64Mi (limit 256Mi) |
| istiod: extra informers for each peer | - | grows with the peers' object counts; estimate +50-100Mi for small clusters (**VERIFY**) |

## Turning it on for running clusters (dev1, prod1)

**On an existing local mgmt, publish port 8200 first.** Members reach OpenBao through the k3d load balancer
(`bootstrap/k3d-mgmt.yaml`: `127.0.0.1:8200:8200` on the serverlb), but k3d reads that file only at `k3d cluster create`;
a running `k3d-platform-mgmt-serverlb` keeps the ports it was created with. Add it in place (k3d recreates only the
load balancer container; `--port-add` is experimental in k3d v5.8):

```
k3d cluster edit platform-mgmt --port-add '127.0.0.1:8200:8200@loadbalancer'
docker port k3d-platform-mgmt-serverlb | grep 8200     # 8200/tcp -> 127.0.0.1:8200
```

or recreate everything (`task down && task up`, which also deletes the CAPD clusters). Without the port the Vault
issuer stays not Ready and istiod on dev1/prod1 waits for `istiod-tls` (the old istiod keeps serving). Fresh clusters
get the port from the config file.

Everything else is Argo CD, ESO, CAPI and the reconcile:

1. The Cluster labels change. ESO refreshes the Argo CD cluster secret (1m); the `mesh-<cluster>` Application
   re-renders with `values/mesh-member.yaml` (istio-csr + Vault Issuer; istiod: multi-network, CA off, gated on
   `istiod-tls`; ztunnel: new network/cluster ID/CA address and pod annotation `mesh.platform.koorikla.io/group`).
2. Meanwhile the reconcile configures `auth/mesh-<name>` and the CRS delivers the public certificates. The sync holds
   at wave -1 until the Issuer logs in to OpenBao, then applies istio-csr and istiod (wave 0); the new istiod starts
   once istio-csr issued `istiod-tls`, the old one serves until then.
3. ztunnel's DaemonSet carries `argocd.argoproj.io/sync-wave: "1"` (addons/mesh/values.yaml), so it applies only after
   the wave-0 resources, istiod included, are Healthy. The ztunnel rollout is the restart: new pods fetch workload
   certificates from istio-csr, chained to the group root, so in-mesh mTLS never mixes roots. Leaving or changing a
   group changes the pod annotation and rolls ztunnel too. If istiod is not Healthy within `progressDeadlineSeconds`
   (600s) the sync fails and Argo retries (no limit, backoff up to 5m) while ztunnel keeps the old config. Watch
   `kubectl -n argocd get application mesh-<cluster>`.

Fresh clusters follow the same order; ztunnel waits until istiod is up.

## Follow-ups and open checks

Per-environment trust domains + URI name constraints, root rotation runbook, baggage stripping at the north-south edge,
peer API 6443 restrictions on CAPA/CAPH: [#71](https://github.com/koorikla/platform/issues/71). Production unseal and
HA: [#31](https://github.com/koorikla/platform/issues/31). istiod's nil-unsafe
`PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false`: fixed on `master` (istio/istio#62295), not yet released; the Secret
opt-in goes with a 1.32 backport or 1.33 ([Reader RBAC](#reader-rbac-what-a-peer-may-read)). Values inferred but not
confirmed live (`grep -rn VERIFY docs/multicluster.md addons/openbao addons/mesh charts/cluster/templates/common/mesh-*`):
[#72](https://github.com/koorikla/platform/issues/72).
