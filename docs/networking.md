# Networking and admission policy

Workload clusters run four pieces: **Cilium 1.20.4** (CNI, kube-proxy replacement, WireGuard, Hubble), **Istio 1.32.0
ambient** (mTLS without sidecars, via ztunnel + istio-cni), **kgateway v2.3.1** (Gateway API v1.5.1, north-south
ingress for OpenChoreo) and **Kyverno 1.20** (admission policy). mgmt keeps k3d's flannel and runs Kyverno, but not
Cilium or Istio.

| Concern | Component | Addon (catalog) | Clusters |
|---|---|---|---|
| Pod network, Services (no kube-proxy), NetworkPolicy, node-to-node encryption, flow visibility | Cilium | `cilium` (`kube-system`, opt-in by label, set from `cni`) | workload, `cni: cilium` |
| Gateway API CRDs (standard channel) | Gateway API v1.5.1 | `gateway-api-crds` | all |
| North-south ingress (`GatewayClass kgateway`, OpenChoreo's `gateway-default`) | kgateway | `kgateway` | all |
| East-west mTLS, L4 authz, optional L7 waypoints | Istio ambient (base, istiod, istio-cni, ztunnel) | `istio-ambient` (`istio-system`) | workload |
| Cluster-to-cluster (multi-network ambient, east-west gateways, mesh CA in OpenBao) | Istio ambient multicluster | `istio-eastwest` + `istio-csr`, mesh CA `openbao` on mgmt (opt-in, docs/multicluster.md) | fleet files with `mesh.group` |
| Admission: PSS baseline audit, ambient enrollment | Kyverno + policies | `kyverno`, `kyverno-policies` (`kyverno`) | all (enrollment: workload) |
| Runtime detection / response | Falco + Talon | `falco` | all (docs/observability.md) |

## CNI is fixed when the cluster is created
The fleet file key `cni: cilium | flannel` (default `cilium`, `charts/cluster/values.yaml`) picks the pod network when
the cluster is created. It flows to three places:

1. **ClusterClass variable `cni`** (`addons/clusterclasses`, all three classes). The control-plane template carries the
   k3s drop-in `/etc/rancher/k3s/config.yaml.d/10-cni.yaml`. k3s merges it over the `config.yaml` that the bootstrap
   provider writes. A drop-in is needed because the `KThreesServerConfig` API has no field for these flags.
   - `cilium`: `flannel-backend: none`, `disable-network-policy: true`, `disable-kube-proxy: true`.
   - `flannel` (patch `cni-flannel`): `flannel-backend: vxlan` (docker, aws) or `wireguard-native` (hetzner).

   Agents need no drop-in: k3s agents take the flannel backend, kube-proxy and network-policy settings from the
   servers. On AWS, the class replaces CAPA's Calico security-group rules with the CNI's node-to-node ports:
   - Cilium: VXLAN udp/8472, WireGuard udp/51871, health tcp/4240 + ICMP, Hubble peer tcp/4244.
   - flannel: udp/8472.

   On Hetzner, CAPH creates no firewall. With `cilium`, pod traffic uses Cilium's VXLAN overlay + WireGuard (see
   "Cilium" below); with `flannel`, k3s' `wireguard-native` backend.
2. **Labels** on the CAPI `Cluster` and the Argo CD cluster secret (both use the `capi.labels` helper):
   `platform.koorikla.io/cni: <cni>` and `addons.platform.koorikla.io/cilium: "true"|"false"`. The cilium addon has
   catalog `default: false` and is selected by that label, so it lands exactly on `cni: cilium` clusters. Setting
   `addons.cilium` in a fleet file is redundant; a value that contradicts `cni` fails the render.
3. **Value layer** `addons/<addon>/values/cni-<cni>.yaml`, plus `cluster.cni` in every addon Application (mgmt's
   secret says `flannel`). `istio-ambient` uses this to pick its CNI directories (below).

GKE (`provider: gcp-gke`) takes only `cni: gke`: GKE's own VPC-native networking, no Cilium addon (CAPG v1.13.1
cannot request Dataplane V2; [providers.md](providers.md#gke-capg---untested-example)).

**You can't change `cni` on a live cluster: rebuild it instead.** Changing the variable would roll the control plane
onto a different CNI while pods keep addresses and policies from the old one. Delete the fleet file, let CAPI remove
the cluster, then add it back with the new `cni`.

### Bootstrap order without a CNI
k3s starts with no CNI, so nodes stay `NotReady` until Cilium runs. Bootstrap still completes:
- **KThreesControlPlane** initializes as soon as the API answers. It reads `k3s-serving` and doesn't wait for node
  readiness. So the kubeconfig secret, the Argo CD cluster secret (ESO) and the addon Applications all appear while
  nodes are still `NotReady`.
- **Cilium** reaches the API server without kube-proxy or cluster DNS: it dials the endpoint directly (next section).
  It runs `hostNetwork` and tolerates every taint, including the cloud provider's `uninitialized` taint, so the CCMs
  and Cilium don't wait for each other. Once its agent writes the CNI config, the node turns `Ready`.
- **Every other addon** retries (Argo CD backoff up to 5m) until pods can be scheduled.
- **Scaling**: KCP's scale-up preflight requires `MachineAgentHealthy` (node `Ready`) on the existing control-plane
  machines (cluster-api-k3s `scale.go`). Control-plane machines 2 and 3 are therefore created only after Cilium has
  made machine 1 `Ready`. This delays scale-up but can't deadlock. MachineDeployments don't wait for it.

## Cilium (`addons/cilium`)
- **kube-proxy replacement** (`kubeProxyReplacement: true`). Without kube-proxy the agent can't use the `kubernetes`
  Service VIP, so `k8sServiceHost`/`k8sServicePort` must be the cluster's real API endpoint. That endpoint is the
  `server` of the Argo CD cluster secret, which is the CAPI kubeconfig endpoint: the CAPD load balancer container,
  the AWS ELB DNS name, or the Hetzner LB IP. Every node can reach it and the API certificate covers it. The catalog
  field `clusterServerParameters` passes it to the chart:
  ```yaml
  cilium: { ..., clusterServerParameters: { cilium.k8sServiceHost: host, cilium.k8sServicePort: port } }
  ```
  `charts/platform/templates/appset-addons.yaml` turns this into ApplicationSet goTemplate expressions (sprig
  `urlParse`, available in Argo CD templates):
  ```
  host: {{ (urlParse .server).hostname }}
  port: {{ $h := (urlParse .server).host }}{{ if regexMatch ":[0-9]+$" $h }}{{ regexFind "[0-9]+$" $h }}{{ else }}443{{ end }}
  url:  {{ .server }}
  ```
  The chart fails to render when the host is empty. k3s' `127.0.0.1:6444` load balancer can't be used: it runs only
  on agents. k3s sets `DisableLoadBalancer` on nodes that run the API server.
- **CNI directories**: Cilium's defaults (`/etc/cni/net.d`, `/opt/cni/bin`). k3s points its containerd at
  `/var/lib/rancher/k3s/...` only when it runs flannel: `pkg/executor/embed/embed.go` sets `CNIConfDir`/`CNIBinDir`
  inside the flannel branch. With `flannel-backend: none`, containerd keeps its built-in defaults.
- **IPAM `cluster-pool`**: pool `10.42.0.0/16` (= `Cluster.spec.clusterNetwork.pods`), a /24 per node, on every
  provider. AWS ENI IPAM is not used (it needs instance-type IP limits, IAM and more SG rules), and nothing programs
  hcloud routes.
- **Routing: VXLAN tunnel** on every provider. No VPC route tables or hcloud network routes, and the same behaviour
  locally and in the clouds. Native routing is a possible later optimisation per provider.
- **Encryption: WireGuard** for all pod traffic between nodes, mesh or not (udp/51871). Needs the kernel's wireguard
  module (on CAPD: the docker host's kernel).
- **Hubble**: relay on, UI off. Metrics on: `dns, drop, tcp, flow, port-distribution, icmp, httpV2`. TLS comes from
  the certgen CronJob, so Helm generates no random certs and Argo CD shows no diff. The chart's ServiceMonitors stay
  off (this CNI app syncs before the Prometheus Operator CRDs exist); addon telemetry scrapes `hubble-metrics` instead
  (docs/observability.md "HTTP metrics").
- **L7 HTTP visibility** (`l7Visibility`, CiliumClusterwideNetworkPolicy `openchoreo-http-visibility`), **off**: on dev1
  the redirected connections into ambient pods hung at Cilium's proxy and cut the apps off ([#104](https://github.com/koorikla/platform/issues/104)). When on: an allow-all
  `http: [{}]` rule on port 8080 of every pod with an `openchoreo.dev/component` label, with `enableDefaultDeny: false`
  on both directions, so it never denies anything. Hubble only emits `hubble_http_*` for traffic Cilium's L7 proxy
  parses, and that takes an L7 rule. Only list ports that serve HTTP on every component pod: the proxy rejects other
  protocols on a listed port (Cilium rejects L7 rules without a port). It sees plaintext only: since the gateway is in
  the mesh ([Strict mTLS in cell namespaces](#strict-mtls-in-cell-namespaces)) all traffic into component pods is
  HBONE on 15008 and stays opaque, so this would no longer yield HTTP metrics (the gateway's own Envoy metrics do).
- **Gateway API, Ingress, standalone Envoy: off.** kgateway owns north-south Gateway API; Istio owns waypoints.
- **Istio ambient compatibility** (from Istio's Cilium prerequisites):
  - `cni.exclusive: false`: Cilium must not delete istio-cni's chained config.
  - `socketLB.hostNamespaceOnly: true`: socket LB inside pod namespaces would bypass ztunnel's redirection.
  - `bpf.masquerade: false`: BPF masquerading breaks ambient's link-local `169.254.7.127` health-probe SNAT.
  - With default-deny `CiliumNetworkPolicy`, also allow ingress from `169.254.7.127/32` and HBONE `15008/tcp` between
    ambient pods.
  - Any NetworkPolicy that restricts ingress ports must also open HBONE `15008/tcp` from the same peers: ztunnel
    tunnels every mesh connection to the destination pod's 15008, so the CNI never sees the app port. For OpenChoreo's
    per-component policies the platform generates that rule
    ([Strict mTLS in cell namespaces](#strict-mtls-in-cell-namespaces)).
- **CAPD / kindest/node**: no extra mounts. The node image's entrypoint makes `/` shared, and Cilium's privileged init
  containers mount bpffs and cgroup2 themselves, as on kind. dev1 and prod1 share the host kernel, but socket LB is
  scoped per cgroup namespace and CAPD node containers use private cgroupns.

## Istio ambient (`addons/istio-ambient`)
- Charts `base`, `istiod`, `cni`, `ztunnel` 1.32.0 from upstream's OCI registry `oci://ghcr.io/istio/release/charts`
  (same tarballs as `https://blob.istio.io/istio-release/charts`; the GCS bucket and `gcr.io/istio-release` stop at
  1.30.x and go away on 2026-12-16, see Istio's
  [GCP retirement post](https://istio.io/latest/blog/2026/retirement-of-gcp/)). Helm cannot pin dependency digests, so
  `Chart.yaml` lists each tarball's sha256 (annotation `platform.koorikla.io/dependency-digests`, = the OCI layer
  digest) and `hack/deps.sh` refuses other bytes; a version bump updates them in the same PR. istiod, cni and ztunnel use `profile: ambient`; images are `docker.io/istio/*`.
- **CNI directories follow `cni`**:
  - Cilium clusters: istio-cni uses the standard `/etc/cni/net.d` + `/opt/cni/bin` and chains into Cilium's conflist.
  - flannel clusters: `values/cni-flannel.yaml` sets `global.platform: k3s`
    (`/var/lib/rancher/k3s/agent/etc/cni/net.d`, `/var/lib/rancher/k3s/data/cni`).
- `base` installs only `*.istio.io` CRDs. Gateway API CRDs come from `gateway-api-crds`. istiod uses them for its own
  GatewayClasses (`istio`, `istio-waypoint`) and ignores `gatewayClassName: kgateway`.
- Workloads join the mesh through the label `istio.io/dataplane-mode=ambient` on their namespace or on the pod (the pod
  label wins). A pod can opt out with `istio.io/dataplane-mode=none`. Enrollment happens live: running pods join
  without restarts.

### Ambient enrollment of OpenChoreo namespaces
On the data plane, OpenChoreo creates one cell namespace per project x environment (e.g.
`dp-default-demo-development-ad621210`). The renderedrelease controller renders it from the `ClusterProjectType`
(`cell-namespace` resource) and labels it:

```
openchoreo.dev/managed-by=renderedrelease-controller  openchoreo.dev/project=demo  openchoreo.dev/environment=development
openchoreo.dev/namespace=default  openchoreo.dev/rendered-release-resource-id=cell-namespace  (+ uids, release names)
```

OpenChoreo can set extra namespace labels declaratively, but only per binding
(`ProjectReleaseBinding.spec.environmentConfigs.namespaceLabels`, defined by the `default` ClusterProjectType), so
every tenant would have to repeat it. The platform default is a Kyverno `MutatingPolicy` instead
(`addons/kyverno-policies/templates/ambient-enrollment.yaml`):
- It matches Namespace CREATE/UPDATE with `managed-by=renderedrelease-controller` and both `project` and
  `environment` labels present. That covers the namespaces of any project type, not only the `cell-namespace`
  resource id.
- It adds `istio.io/dataplane-mode=ambient` unless the label is already set. Setting `none` through
  `namespaceLabels` opts a single environment out.
- It re-applies on every UPDATE, so the controller can't drop the label when it re-renders the namespace. Dropping
  the label would unenroll the pods.
- `mutateExisting` labels namespaces that already existed before the policy, through the background controller. The
  addon aggregates the RBAC this needs.
- `failurePolicy: Ignore`: a Kyverno outage only delays enrollment; it never blocks OpenChoreo.
- Platform namespaces are excluded twice: by Kyverno's webhook `namespaceSelector` and by a `matchConditions` name
  list. The platform's own mesh members are enrolled by their addons instead (next section).

### Strict mTLS in cell namespaces
Every ambient cell namespace refuses plaintext: Kyverno generates a `PeerAuthentication` `default` with
`mtls.mode: STRICT` into it ([#53](https://github.com/koorikla/platform/issues/53)). That only works because every
in-cluster client of cell pods is itself in the mesh:

| Client | Reaches in the cells | Enrolled by |
|---|---|---|
| data-plane gateway `gateway-default` (kgateway Envoy, `openchoreo-data-plane`) | component endpoints (ingress) | pod label through `Gateway.spec.infrastructure.labels` (addon `openchoreo-data-plane`) |
| CNPG / Strimzi / KEDA operators (`cnpg-system`, `strimzi`, `keda`) | instance, broker and scaler endpoints | namespace label (each addon, `namespace.ambient`) |

The gateway follows upstream's ambient ingress setup (kgateway docs "Ingress" for ambient: put the proxy in the mesh,
ztunnel carries its upstream connections as HBONE). Only the proxy pod is labelled, so the cluster-agent next to it
stays out. kgateway's own ambient settings (`KGW_ENABLE_ISTIO_INTEGRATION`, waypoint routing) are for DestinationRules
and waypoints and aren't needed for L4 mTLS. The mesh clients carry no `PeerAuthentication`: they keep accepting
plaintext from outside the mesh (the cloud LB / klipper into the gateway, the Prometheus agent's scrape of the
gateway, kube-apiserver into operator webhooks). `hack/tests/test_gitops_contracts.sh` fails if one of them leaves
the mesh while STRICT is on.

`addons/kyverno-policies/templates/cell-mesh.yaml`, two `GeneratingPolicy`s on the same cell selector as the
enrollment (synchronized: an edited or deleted object is restored, generated for existing cells too):
- `openchoreo-cell-hbone`: NetworkPolicy `platform-mesh-hbone` admitting `15008/tcp` to pods with an
  `openchoreo.dev/component` label, from the peers OpenChoreo's per-component NetworkPolicy admits: pods of the same
  namespace and `openchoreo.dev/system-component` pods anywhere (the gateway). OpenChoreo's policy opens only the
  endpoint ports, and ambient tunnels every mesh connection to 15008, so without it the CNI drops ingress (and
  pod-to-pod traffic inside a cell). The peer set is unchanged, so a staging pod still can't reach production; inside
  the tunnel the CNI no longer checks the endpoint port.
- `openchoreo-cell-mtls`: the `PeerAuthentication` (STRICT, or PERMISSIVE for an opted-out cell), off with
  `ambientEnrollment.mtls.strict: false`.

Unaffected: kubelet probes (ambient SNATs them to `169.254.7.127`, which ztunnel exempts), cAdvisor and
kube-state-metrics (node / API level), Falco (syscalls), the cluster-agent (API server only), the promotion gate
(queries the gateway's Envoy metrics in the observability plane), and traffic between pods of one cell.

**Exceptions.** A client outside the mesh that must reach a cell pod directly (a VM, a non-mesh namespace, an
operator not listed above) is refused. That includes the Prometheus agent (addon `telemetry`), which stays outside
(its namespace pins `istio.io/dataplane-mode: none`): ztunnel's DNS proxy (`AMBIENT_DNS_CAPTURE`, Istio's default)
answers `*.localhost` names with loopback, so enrolled, the agent and the collectors lost the local installation's
ingest hosts (`*.observability.openchoreo.localhost`, seen live). PodMonitors whose targets sit in a STRICT cell
(CloudNativePG's per-cluster `:9187`) are therefore refused; the platform's own metrics (cAdvisor,
kube-state-metrics, the gateway's Envoy) are unaffected. The same DNS behaviour applies to any ambient pod that
calls a `*.localhost` host. Either enroll the client, or keep one environment `PERMISSIVE` with the
namespace label `platform.koorikla.io/mtls=permissive` through
`ProjectReleaseBinding.spec.environmentConfigs.namespaceLabels`: the generated `PeerAuthentication` switches to
`PERMISSIVE` (a mode, not a selector: Kyverno never deletes a synchronized object whose trigger stops matching, but
re-renders it on every namespace update). A cell created with `istio.io/dataplane-mode=none` is out of the mesh and
gets neither object.

A Kubernetes-native MutatingAdmissionPolicy was considered and rejected. It can't label namespaces that already
exist, and in Kubernetes 1.35 it is beta and off by default (needs a feature gate on k3s). Kyverno was wanted anyway.

## Gateway API versions
`gateway-api-crds` installs Gateway API **v1.5.1, standard channel** (envoyproxy gateway-crds-helm 1.8.2). That
covers all three consumers:
- kgateway 2.3.1: `Gateway`, `HTTPRoute`, `GatewayClass`, `ReferenceGrant`.
- Istio 1.32 ambient waypoints: a `Gateway` with `gatewayClassName: istio-waypoint`, standard channel.
- Cilium: Gateway API is off, so no version constraint.

No upgrade or experimental channel is needed.

## Kyverno (`addons/kyverno`, `addons/kyverno-policies`)
- Official chart 3.10.0 (Kyverno 1.20.0) on mgmt and workload clusters, catalog `default: true`. Engine and policies
  are separate addons. The policies app fails its first syncs until the engine's CRDs exist; Argo CD's retry then
  picks it up. Policy objects carry `SkipDryRunOnMissingResource=true`.
- One replica per controller (admission, background, cleanup, reports). HA installations override the replicas in
  `installations/<inst>/addons/kyverno/values.yaml`.
- **Kyverno can't block bootstrap.** Its webhook `namespaceSelector` excludes every platform namespace, and the
  engine's resource filters skip them too. The excluded namespaces: `kube-system`, `kyverno`, `argocd`,
  `cert-manager`, `external-secrets`, the CAPI provider namespaces, `fleet`, `openchoreo-*`, `thunder`,
  `kgateway-system`, `istio-system`, `cilium`, `falco`, `telemetry`, `obi`, `agentgateway-system`, and the secret
  namespaces. Not `harbor`, `external-dns` and the opt-in data-service operators `keda`, `strimzi`, `cnpg-system`
  ([data-services.md](data-services.md)): their pods meet Pod Security (baseline / restricted), so they are policed
  like workloads.
  `hack/tests/test_gitops_contracts.sh` checks that `kyverno-policies` uses the same list and that every other catalog
  namespace is on it.
- **Baseline**: upstream `kyverno-policies` Pod Security Standards **baseline**, as CEL `ValidatingPolicy`s with
  `validationActions: [Audit]`, `failurePolicy: Ignore` and platform namespaces excluded. Violations show up in
  PolicyReports; nothing is denied. Moving a single policy to Enforce is a per-installation values change
  (`validationFailureActionByPolicy`).
- **Supply-chain gate** (`templates/image-verification.yaml`): per environment an `ImageValidatingPolicy` (cosign
  keyless signature + SBOM/SLSA/vuln attestations of `ghcr.io/koorikla/*`, platform key for workflow-plane images) and
  a trusted-registry `ValidatingPolicy`, Audit in development/staging cell namespaces, Deny (fail closed, digest
  required) in production. [supply-chain.md](supply-chain.md).
- Server-side apply is required (and on for all generated Applications): the Kyverno CRDs exceed the client-side
  last-applied annotation limit.
- **Coexistence with Falco**: the two don't overlap. Kyverno decides at admission (API requests). Falco watches
  syscalls at runtime, and Talon acts on running pods in `dp-*` namespaces (label, terminate). Talon's pod patches pass
  the audit-only baseline. If policies ever move to Enforce, keep `falco` excluded and don't enforce on the labels
  Talon writes. Falco runs privileged in its own excluded namespace, so the baseline never reports it.

## Footprint per workload cluster (requests; 1 node)
| Component | CPU | Memory | Scales with |
|---|---|---|---|
| cilium-agent | 100m | 128Mi (limit 512Mi) | per node |
| cilium-operator (1) + hubble-relay | 75m | 128Mi | per cluster |
| ztunnel + istio-cni | 75m | 192Mi | per node |
| istiod | 50m | 128Mi | per cluster |
| Kyverno (4 controllers) | 125m | 320Mi | per cluster |
| **Total** | **~425m** | **~900Mi** | +175m / +320Mi per extra node |

Measured on dev1 (single node, idle, `kubectl top`, #52): cilium-agent 232Mi, cilium-operator 40Mi, hubble-relay
25Mi, ztunnel 11Mi, istio-cni 24Mi, istiod 55Mi, Kyverno 343Mi (admission 178Mi): ~730Mi, below the requests.

Values inferred but not yet confirmed live (`grep -rn VERIFY addons/cilium addons/istio-ambient addons/kyverno* addons/clusterclasses`):
[#52](https://github.com/koorikla/platform/issues/52).
