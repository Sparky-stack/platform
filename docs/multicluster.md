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
    mesh-root-ca: true          # mesh root CAs + PKI admission guards on mgmt
mesh:
  groups: [local]               # one root CA per group
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
| `PILOT_DISABLE_SELF_SIGNED_CA` | stable flag | yes, on members |
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
| `addons.platform.koorikla.io/istio-eastwest: "true"` (`"false"` without a group) | selects addon `istio-eastwest` and the example; istiod env `AMBIENT_ENABLE_MULTI_NETWORK`, `AMBIENT_ENABLE_BAGGAGE`, `PILOT_DISABLE_SELF_SIGNED_CA` |

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
| mgmt, `cert-manager` | per group: `Issuer mesh-root-selfsigned` → `Certificate mesh-root-<group>` → `ClusterIssuer mesh-root-<group>`; ValidatingAdmissionPolicies `platform-mesh-*` | addon `mesh-root-ca` (mgmt, opt-in) |
| mgmt, `fleet` | `Certificate <name>-mesh-ca` (intermediate); `ExternalSecret` + `ClusterResourceSet <name>-mesh` (cacerts, network label) | `charts/cluster` `templates/mesh-pki.yaml`, `mesh-crs.yaml` |
| mgmt, `fleet` | `Issuer <name>-client-ca` (over `<name>-cca`), `Certificate <name>-mesh-reader`, `ExternalSecret` + `ClusterResourceSet <name>-mesh-remote-secret` | `charts/cluster` `templates/mesh-remote-secret.yaml` |
| member, `istio-system` | `Gateway istio-eastwestgateway` (+ params ConfigMap), `ClusterRole`/`ClusterRoleBinding`/`Role`/`RoleBinding platform-istio-reader` | addon `istio-eastwest` |
| member, `istio-system` | istiod/ztunnel multicluster values | addon `istio-ambient` (catalog parameters) |
| member, `istio-system` | `Secret cacerts`, label on the namespace, `Secret istio-remote-secret-<peer>` per peer | CAPI ClusterResourceSets (from mgmt) |
| member, `eastwest-demo` | example | `examples/eastwest` via ApplicationSet `example-eastwest` |

## Trust: one root per mesh group on mgmt, a short-lived intermediate per cluster
Every member of a group must chain to the same root so that a dev1 workload certificate verifies in prod1.

- **Roots, one per group**: installation.yaml lists the groups (`mesh.groups: [local]`); addon `mesh-root-ca` on mgmt
  renders, per group, a cert-manager self-signed CA `mesh-root-<group>` (RSA 4096, 10y, `rotationPolicy: Never`) and
  a `ClusterIssuer mesh-root-<group>`. A fleet file's `mesh.group` must be listed (charts/cluster fails otherwise).
  **Root keys never leave mgmt** and live in cert-manager's cluster resource namespace (`cert-manager`), which no
  ClusterSecretStore reaches (`mgmt-fleet` reads only `fleet`; contract test). A group is therefore a cryptographic
  boundary, not just a discovery boundary: a key stolen from a member of group A cannot mint an identity that group B
  accepts. All groups still use the trust domain `cluster.local` (per-environment trust domains: "Next steps").
- **Groups follow trust levels.** Clusters of different environments or trust levels never share a group. `local`
  (dev1 + prod1 on one laptop) is the deliberate exception for the demo; real installations use e.g. `dev` and
  `prod` groups, so a development cluster's intermediate is worthless in production.
- **Intermediate**: `Certificate <name>-mesh-ca` in `fleet` (isCA, RSA 4096, **14 days, renewed after 7**; usages cert
  sign, crl sign, digital signature), issued by `ClusterIssuer mesh-root-<group>`. 14 days still survives a week-long
  mgmt outage. ESO (store `mgmt-fleet`) templates it into a ClusterResourceSet payload: `Secret istio-system/cacerts`
  of type `kubernetes.io/tls` (`tls.crt` = intermediate, `tls.key`, `ca.crt` = group root; istiod 1.32 reads this
  format as a plugged-in CA and builds the chain from `tls.crt` + `ca.crt`). The same payload sets the namespace label
  `topology.istio.io/network=<name>`. CRS strategy `Reconcile` re-applies a renewal; istiod watches its `cacerts`
  files and reloads a renewed intermediate without a restart (**VERIFY** on the first renewal; the root does not
  change, so trust is never interrupted).
- **No silent fallback**: on members istiod runs with `PILOT_DISABLE_SELF_SIGNED_CA=true`. Without `cacerts` it
  refuses to start and Kubernetes restarts it until the CRS has delivered the CA. It never mints a private root that
  would split the mesh.
- **No revocation.** Istio checks no CRL or OCSP. A leaked intermediate stays valid until its `notAfter` (at most
  14 days), whatever happens on mgmt: `rotationPolicy: Always` gives the *next* certificate a new key but does not
  invalidate the old one, and deleting the fleet file only stops renewal. The only faster cut is rotating the group's
  root (below). Same for the 7-day reader client certs: Kubernetes cannot revoke client certificates.

### Admission guards on mgmt
cert-manager's internal approver approves every CertificateRequest, and a CA issuer signs whatever it is asked. Two
signers here are sensitive: the `<name>-client-ca` Issuers (the k3s client CA of a workload cluster, whose API server
accepts anything they sign, `O=system:masters` included) and the mesh root ClusterIssuers (referencable from any
namespace). Addon `mesh-root-ca` ships ValidatingAdmissionPolicies (`admissionregistration.k8s.io/v1`, Deny) that
admit exactly what charts/cluster renders:

| Policy | Admits |
|---|---|
| `platform-mesh-reader-certificates` | Certificates for a `*-client-ca` issuer: in `fleet`, `CN=platform:istio-reader`, no subject (no O/OU = no groups), no SANs, not a CA, usages client auth + digital signature, duration set and <= 168h |
| `platform-mesh-intermediate-certificates` | Certificates for a `mesh-root-*` ClusterIssuer: `fleet/<x>-mesh-ca` only, applied by Argo CD's application controller (git is the only path), isCA, CA usages, no SANs, duration <= 336h |
| `platform-mesh-certificaterequests` | CertificateRequests for either: created by cert-manager's controller only (so they come from an admitted Certificate; CEL cannot parse the CSR), in `fleet`, same isCA/usages/duration profile |
| `platform-mesh-issuers` | a `<x>-cca` Secret may back only `Issuer fleet/<x>-client-ca`; a mesh root Secret only its own ClusterIssuer; no issuer may wrap a `<x>-mesh-ca` intermediate |

`hack/tests/test_mesh_admission.sh` evaluates the CEL offline with the kyverno CLI (pinned in mise.toml): the rendered
Certificates/Issuers of every mesh member pass, and the negative cases (system:masters, other CNs, sub-CAs, long
durations, SANs, other namespaces, hand-made requests, rogue issuers, non-Argo intermediates) are denied.

### The invariant-4 question (pending user approval)
istiod is the workload CA, so it needs a CA *private key*: the member's intermediate key sits in its `istio-system/
cacerts`. AGENTS.md invariant 4 says CA private keys never leave mgmt; the proposed exception is worded as narrowly as
possible and is **pending the user's decision**:
- only `istio-system/cacerts` on opt-in mesh members, holding that cluster's own intermediate (never a root key);
- only while peers cannot read Secrets (`platform-istio-reader`, "Reader RBAC" below), each group has its own root,
  intermediates live <= 14 days, and the admission guards above are in place.

**Tracked replacement (removes the exception)**: istio-csr on each member, with istiod's CA turned off, forwarding CSRs
to a signer on mgmt that the workload clusters can reach: OpenBao/Vault PKI with per-cluster Kubernetes auth, or AWS
Private CA on AWS. Then no CA key sits on a workload cluster. Moving there changes only the delivery (`cacerts` ->
istio-csr issuer config); the rest of this document stays valid. Backlog: README roadmap.

Root rotation (also the emergency answer to a leaked intermediate) is a planned procedure, not a renewal: add the new
root next to the old one in every member's `ca.crt` (a trust bundle), re-issue the group's intermediates from the new
root, then drop the old one.

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
   (read-only discovery, no Secrets; "Reader RBAC" below).
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
reader user, every peer could read this cluster's `istio-system/cacerts` (intermediate CA key), the OpenChoreo agent
identity and every tenant Secret. So the reader is bound to the platform's own roles instead (addon `istio-eastwest`
`templates/reader-rbac.yaml`), derived from what istiod 1.32.0 actually reads on a remote cluster:

| istiod 1.32.0 source | Remote reads | Granted |
|---|---|---|
| `pkg/kube/multicluster/cluster.go` (ambient KRT collections) | namespaces, pods, services, nodes, endpointslices, Gateway API gateways | `ClusterRole platform-istio-reader` get/list/watch |
| `serviceregistry/kube/controller` | the same + endpoints, MCS serviceimports, CRDs (delayed informers) | same |
| `PILOT_ENABLE_CROSS_CLUSTER_WORKLOAD_ENTRY` (default on) | networking.istio.io workloadentries | Istio config groups, read-only |
| remote mesh watcher (`controller/multicluster.go`) | ConfigMap `istio-system/istio` (trust domain), by field selector | `Role platform-istio-reader`, `resourceNames: [istio]` |
| remote credentials controller | Secrets (gateway TLS) - only needed when a gateway's istiod is in another cluster (primary-remote) | **none**: istio-ambient sets `PILOT_ENABLE_REMOTE_CREDENTIALS_CONTROLLER=false` |
| leader election / namespace controller on remotes | only with `EXTERNAL_ISTIOD` | none |
| `serviceexports` writes, tokenreviews, SARs | `ENABLE_MCS_AUTO_EXPORT` (off), primary-remote proxy auth | none |

Unittests pin the rules and assert the negatives. **VERIFY** on the first live run: `istioctl remote-clusters` shows
each peer `synced` (not `timeout`: a forbidden informer would never sync and istiod gives up after
`PILOT_REMOTE_CLUSTER_TIMEOUT`, 30s), istiod logs show no `forbidden` for the reader user, and `kubectl auth can-i
--as platform:istio-reader get secrets -A` is `no` on each member. Re-check this table on every Istio upgrade.

Peers can still read Pods, Services and Istio config of each other, so members of one group must sit at the same
trust level (see "Trust").

Peers must reach each member's API endpoint: locally the CAPD load balancer container on docker network `kind`, on AWS
the CAPA API ELB, on Hetzner the API load balancer.

### Removing a member (decommissioning)
CRS never deletes what it applied, and Istio checks no revocation, so decommissioning is explicit:
1. Remove `mesh.group` from the fleet file (or delete the fleet file). The Certificates `<name>-mesh-ca` /
   `<name>-mesh-reader`, Issuer `<name>-client-ca`, ExternalSecrets and ClusterResourceSets go with the cluster
   chart, so nothing is renewed any more.
2. On every remaining member delete `istio-system/istio-remote-secret-<gone>` (CRS leaves it behind; istiod logs a
   failing remote cluster until then). Its reader cert stops authenticating within 7 days in any case.
3. On mgmt delete the leftover Secrets `fleet/<gone>-mesh-ca` and `fleet/<gone>-mesh-reader` (cert-manager does not
   delete a Certificate's Secret with it).
4. A leaked intermediate stays valid until its `notAfter` (<= 14 days). If the gone cluster may have been compromised,
   rotate the group's root (above) instead of waiting.
**VERIFY** whether istiod drops the gone cluster's endpoints at once (it should: the remote watch fails).

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
Adding `mesh.group` to live clusters is handled entirely by Argo CD and CAPI; there is no manual step. Order of events:
1. The Cluster labels change. ESO refreshes the Argo CD cluster secret (1m), and the istio-ambient Application
   re-renders: istiod gets the new env (multi-network, no self-signed CA), ztunnel the new network/cluster ID and the
   pod annotation `mesh.platform.koorikla.io/group`.
2. In parallel, mgmt issues the intermediate and the CRS delivers `cacerts`. The new istiod pod starts only once
   `cacerts` exists (`PILOT_DISABLE_SELF_SIGNED_CA`). Its log shows `Using kubernetes.io/tls secret type for signing
   ca files`. The old istiod keeps serving until then.
3. ztunnel's DaemonSet carries `argocd.argoproj.io/sync-wave: "1"` (addons/istio-ambient/values.yaml), so Argo CD
   applies it only after the wave-0 resources, istiod included, are Healthy - i.e. after istiod runs on the plugged-in
   CA. The ztunnel rollout (its pod template changed in step 1) is the restart: the new pods fetch workload
   certificates chained to the group root, so in-mesh mTLS (OpenChoreo cell namespaces too) never mixes roots. Leaving
   or changing a group changes the pod annotation, so that rollout happens as well.
   Caveat: if `cacerts` takes longer than istiod's `progressDeadlineSeconds` (600s), the sync fails and Argo retries
   (limit 10, backoff up to 5m); ztunnel stays on the old config until istiod is Healthy. Watch
   `kubectl -n argocd get application istio-ambient-<cluster>`; nothing needs to be run by hand.
Fresh clusters get `cacerts` before istiod first starts, so the same ordering simply delays ztunnel until istiod is up.

## Next steps (deferred)
- **Per-environment trust domains + name constraints.** All groups use `cluster.local`, so
  `cluster.local/ns/eastwest-demo/sa/client` from dev1 and from prod1 look the same to an AuthorizationPolicy.
  Next: a trust domain per environment/group (`meshConfig.trustDomain`, peers via `trustDomainAliases`) and URI name
  constraints on each intermediate (cert-manager `nameConstraints`, behind the `NameConstraints` feature gate).
  Deferred because it changes every principal in existing policies, and whether ztunnel enforces URI name
  constraints is unverified (**VERIFY** before relying on it). Per-group roots already stop cross-group forgery.
- **Baggage at the north-south edge.** `AMBIENT_ENABLE_BAGGAGE` carries peer metadata (cluster, namespace, workload)
  across networks. kgateway (north-south) should strip `baggage` on egress and on requests from outside, so internal
  topology never leaks and outside callers cannot inject metadata. Deferred to the kgateway policy work (needs a
  route/listener policy on the data-plane Gateway; not part of the mesh addons).
- **Peer API 6443 on CAPA/CAPH.** Restrict the control-plane load balancers to the peers' egress IPs
  (`AWSCluster.spec.controlPlaneLoadBalancer.ingressRules`, CAPH firewall) - ClusterClass variables, separate change.
- **Image signatures.** The example images are digest-pinned but unsigned and the repo has no ImageValidatingPolicy
  yet: repo-wide supply-chain gap (README roadmap).
- **istio-csr + external signer** to retire the invariant-4 exception ("Trust").

## VERIFY on the first live run
`grep -rn VERIFY docs/multicluster.md addons/istio-eastwest addons/mesh-root-ca addons/istio-ambient charts/cluster/templates/mesh-*`
- `istio-east-west` GatewayClass appears with `AMBIENT_ENABLE_MULTI_NETWORK`, and `parametersRef` sizing applies to
  the generated Deployment.
- cert-manager CA issuer accepts the CAPI secret `<name>-cca` (type `cluster.x-k8s.io/secret`, keys `tls.crt`/`tls.key`).
- Peers sync with `platform-istio-reader` only (`istioctl remote-clusters`: synced; no `forbidden` in istiod logs).
- The `platform-mesh-*` admission policies admit Argo CD's Certificates and cert-manager's CertificateRequests
  (`kubectl get validatingadmissionpolicy`; Certificates Ready), and deny a hand-made reader cert with a subject.
- ztunnel rolls only after istiod is Healthy (Argo sync wave 1) when a running cluster joins.
- ESO v2 template output: the JSON kubeconfig (checked offline with ESO's function map) is accepted by istiod.
- CRS `Reconcile` adds the network label to an existing `istio-system` Namespace.
- istiod reloads a renewed `cacerts` without a restart.
- Cross-cluster calls through klipper servicelb on both CNIs; `istioctl ztunnel-config workloads` shows prod1's echo
  with network `prod1` on dev1.
- AWS NLB and SG behaviour, Hetzner LB location annotation.
