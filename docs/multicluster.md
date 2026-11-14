# Cluster-to-cluster connectivity (Istio ambient multicluster)

Opt-in. Workloads in different workload clusters call each other's Services by their usual names
(`<svc>.<ns>.svc.cluster.local`), with mTLS and identity-based authorization. There is no flat pod network, no VPN
appliance and no route between pod CIDRs: each cluster exposes one **east-west gateway**, and Istio ambient carries
cross-cluster traffic through it. Locally `dev1` (Cilium) and `prod1` (flannel) form the mesh group `local`, with the
example service on `prod1` and its callers on `dev1`.

Everything is declarative. Two switches turn it on, and adding a third cluster to the group needs nothing else:

```yaml
# installations/<inst>/installation.yaml
mgmt:
  addons:
    mesh-root-ca: true          # shared mesh root CA on mgmt
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
| mgmt, `fleet` | `Issuer mesh-root-selfsigned` → `Certificate mesh-root-ca` → `Issuer mesh-root-ca` | addon `mesh-root-ca` (mgmt, opt-in) |
| mgmt, `fleet` | `Certificate <name>-mesh-ca` (intermediate); `ExternalSecret` + `ClusterResourceSet <name>-mesh` (cacerts, network label) | `charts/cluster` `templates/mesh-pki.yaml`, `mesh-crs.yaml` |
| mgmt, `fleet` | `Issuer <name>-client-ca` (over `<name>-cca`), `Certificate <name>-mesh-reader`, `ExternalSecret` + `ClusterResourceSet <name>-mesh-remote-secret` | `charts/cluster` `templates/mesh-remote-secret.yaml` |
| member, `istio-system` | `Gateway istio-eastwestgateway` (+ params ConfigMap), `ClusterRoleBinding platform-istio-reader` | addon `istio-eastwest` |
| member, `istio-system` | istiod/ztunnel multicluster values | addon `istio-ambient` (catalog parameters) |
| member, `istio-system` | `Secret cacerts`, label on the namespace, `Secret istio-remote-secret-<peer>` per peer | CAPI ClusterResourceSets (from mgmt) |
| member, `eastwest-demo` | example | `examples/eastwest` via ApplicationSet `example-eastwest` |

## Trust: one mesh root on mgmt, an intermediate per cluster
Every member must chain to the same root so that a dev1 workload certificate verifies in prod1.

- **Root**: addon `mesh-root-ca` on mgmt, a cert-manager self-signed CA (RSA 4096, 10y, `rotationPolicy: Never`).
  **Its private key never leaves mgmt.** One root per installation. Separate groups keep separate meshIDs and remote
  secrets, so they never discover each other. They do share the root and the trust domain `cluster.local`, though, so
  a group is a discovery boundary, not a cryptographic one. Per-group roots are a straightforward extension (one
  Issuer per group in `mesh-root-ca`).
- **Intermediate**: `Certificate <name>-mesh-ca` in `fleet` (isCA, RSA 4096, 90 days, renewed 30 days before expiry),
  issued by `Issuer mesh-root-ca`. ESO (store `mgmt-fleet`) templates it into a ClusterResourceSet payload:
  `Secret istio-system/cacerts` of type `kubernetes.io/tls` (`tls.crt` = intermediate, `tls.key`, `ca.crt` = root;
  istiod 1.32 reads this format as a plugged-in CA and builds the chain from `tls.crt` + `ca.crt`). The same payload
  sets the namespace label `topology.istio.io/network=<name>`. This is the delivery path the OpenChoreo agent identity
  uses: the CRS strategy is `Reconcile`, so a renewal is re-applied. istiod watches its `cacerts` files and reloads a
  renewed intermediate without a restart (**VERIFY** on the first renewal; the root does not change, so trust is
  never interrupted).
- **No silent fallback**: on members istiod runs with `PILOT_DISABLE_SELF_SIGNED_CA=true`. Without `cacerts` it
  refuses to start and Kubernetes restarts it until the CRS has delivered the CA. It never mints a private root that
  would split the mesh.

**Trade-off (a scoped exception to invariant 4).** istiod is the workload CA, so it needs a CA *private key*: the
intermediate's key sits in the workload cluster. That is inherent to istiod-as-CA. It is the cluster's own CA,
short-lived and rotated, but a stolen intermediate can mint any identity in the trust domain, and every peer would
accept it until the intermediate expires. Limits on the blast radius: the 90-day lifetime, deleting the fleet file
(deletes the Certificate, so no renewal), and rotating the root if it ever leaks. The alternative that keeps every CA
key on mgmt is **istio-csr + cert-manager**: istiod stops signing and forwards CSRs to a cert-manager issuer. It
needs a signer that the workload clusters can reach (Vault/OpenBao, AWS Private CA, or a cert-manager instance
exposed from mgmt) and one more component per cluster. This repo has no such network-reachable signer yet, so the
intermediate is the current design. Moving to istio-csr changes only the delivery (`cacerts` → istio-csr issuer
config); the rest of this document stays valid.

Root rotation is a planned procedure, not a renewal: add the new root next to the old one in every `ca.crt` (a trust
bundle), re-issue the intermediates from the new root, then drop the old one.

## Discovery: declarative remote secrets
Each istiod watches the other members' API servers (Services, EndpointSlices, Pods, Namespaces) through a remote
secret: `istio-system/istio-remote-secret-<peer>`, labelled `istio/multiCluster=true`, holding a kubeconfig. Here
**each cluster's own chart publishes its remote secret to every other member of its group**:

1. `Issuer <name>-client-ca`: a cert-manager CA issuer over `fleet/<name>-cca`, the k3s **client CA** that
   cluster-api-k3s generates and keeps on mgmt. That cluster's API server already trusts it for client
   authentication (the CAPI admin kubeconfig is signed by it). cert-manager only reads that Secret.
2. `Certificate <name>-mesh-reader`: client cert `CN=platform:istio-reader`, no organisation (so no groups), ECDSA,
   **7 days**, renewed after 4.
3. On the member, addon `istio-eastwest` binds user `platform:istio-reader` to the istiod chart's read-only
   `ClusterRole istio-reader-clusterrole-istio-system`.
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

Scope of the upstream reader ClusterRole: get/list/watch on core discovery objects, Istio config, Gateway API
`gateways`, and also `secrets` and `configmaps` cluster-wide, plus create/delete on MCS `serviceexports`. That is
upstream's minimum for a peer istiod. A tighter custom role is possible later; it would have to follow Istio's
remote-discovery needs on every upgrade.

Peers must reach each member's API endpoint: locally the CAPD load balancer container on docker network `kind`, on AWS
the CAPA API ELB, on Hetzner the API load balancer.

**Removing a member**: CRS never deletes what it applied. Deleting the fleet file stops renewal, so the peers'
`istio-remote-secret-<gone>` stops authenticating within 7 days, but it stays behind (istiod logs a failing remote
cluster). Delete it from the remaining members as part of decommissioning. **VERIFY** whether istiod drops the gone
cluster's endpoints at once (it should: the remote watch fails).

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
| AWS (CAPA + aws-ccm) | `values/provider-aws.yaml`: NLB (`aws-load-balancer-type: nlb`), internet-facing. CAPA's default node SG already admits NodePorts (30000-32767) for the NLB targets, so **no ClusterClass change**. Harden by setting `gateway.loadBalancerSourceRanges` to the peers' NAT gateway EIPs and narrowing CAPA's NodePort CIDRs (`AWSCluster.spec.network.nodePortIngressRuleCidrBlocks`). **VERIFY** NLB with aws-ccm and that CAPA keeps CCM-added SG rules | CAPA API ELB (`controlPlaneLoadBalancer.scheme` internet-facing by default); restrict 6443 via `controlPlaneLoadBalancer.ingressRules` to the peers' egress IPs (**VERIFY** CAPA's default ingress CIDRs) |
| Hetzner (CAPH + hcloud-ccm) | the template adds `load-balancer.hetzner.cloud/location: <region>` (hcloud-ccm needs a location or network zone). CAPH creates no firewall, so the LB reaches the node ports. **VERIFY** | CAPH API LB (public) |

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

## VERIFY on the first live run
`grep -rn VERIFY docs/multicluster.md addons/istio-eastwest addons/mesh-root-ca charts/cluster/templates/mesh-*`
- `istio-east-west` GatewayClass appears with `AMBIENT_ENABLE_MULTI_NETWORK`, and `parametersRef` sizing applies to
  the generated Deployment.
- cert-manager CA issuer accepts the CAPI secret `<name>-cca` (type `cluster.x-k8s.io/secret`, keys `tls.crt`/`tls.key`).
- ESO v2 template output: the JSON kubeconfig (checked offline with ESO's function map) is accepted by istiod.
- CRS `Reconcile` adds the network label to an existing `istio-system` Namespace.
- istiod reloads a renewed `cacerts` without a restart.
- Cross-cluster calls through klipper servicelb on both CNIs; `istioctl ztunnel-config workloads` shows prod1's echo
  with network `prod1` on dev1.
- AWS NLB and SG behaviour, Hetzner LB location annotation.
