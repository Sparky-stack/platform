# Cluster API providers

How workload clusters are built: Cluster API (CAPI) with the **k3s** bootstrap + control plane provider on one of three
infrastructure providers. Docker (CAPD) is the tested local path; AWS (CAPA) and Hetzner (CAPH) are rendered and
schema-checked only. Design context: [architecture.md](architecture.md); names and labels: [conventions.md](conventions.md).

## What runs where

| Piece | Path | Installs |
|---|---|---|
| Operator | `addons/capi-operator` | cluster-api-operator chart 0.30.0 (needs cert-manager, its own addon) |
| Providers | `addons/capi-providers` | operator CRs: core, k3s bootstrap + control plane, `docker` \| `aws` \| `hetzner` per `installation.yaml` `capi.providers` |
| Classes | `addons/clusterclasses` | namespace `fleet`, ClusterClasses `k3s-docker` (if CAPD), `k3s-aws`, `k3s-hetzner` (if enabled) + their templates |
| Clusters | `charts/cluster` (`templates/capi-*.yaml`) | one topology `Cluster` per fleet file + its node registry auth secret |
| Cloud CCMs | `addons/aws-ccm`, `addons/hcloud-ccm` | AWS / Hetzner cloud-controller-manager on workload clusters of that provider |

### Versions

| Component | Version | Built on CAPI | Contract | API versions used |
|---|---|---|---|---|
| CAPI core | v1.13.8 | - | v1beta2 | `cluster.x-k8s.io/v1beta2` (Cluster, ClusterClass) |
| cluster-api-k3s | v0.5.0 | 1.13.8 | v1beta1 (metadata.yaml) | `bootstrap.cluster.x-k8s.io/v1beta2` KThreesConfigTemplate, `controlplane.cluster.x-k8s.io/v1beta2` KThreesControlPlaneTemplate |
| CAPD | v1.13.8 | - | v1beta2 | `infrastructure.cluster.x-k8s.io/v1beta2` DockerClusterTemplate, DockerMachineTemplate |
| CAPA | v2.13.1 | 1.13.4 | v1beta2 | `infrastructure.cluster.x-k8s.io/v1beta2` AWSClusterTemplate, AWSMachineTemplate |
| CAPH | v1.1.12 | 1.13.4 | v1beta1 | `infrastructure.cluster.x-k8s.io/v1beta1` HetznerClusterTemplate, HCloudMachineTemplate |
| k3s (workload) | v1.35.10+k3s1 | | | Kubernetes 1.35: CAPI 1.13 supports workload 1.30-1.37, OpenChoreo 1.3.3 needs >= 1.32 |
| kindest/node (CAPD node OS) | v1.35.8 | | | only the OS; k3s is installed at boot |

Core 1.13 accepts v1beta1-contract providers (`GetCompatibleVersions`: v1beta2 is "temporarily compatible" with v1beta1).
k3s is not in clusterctl's built-in provider list, so its operator CRs carry
`fetchConfig.url: https://github.com/k3s-io/cluster-api-k3s/releases/<version>/{bootstrap,control-plane}-components.yaml`.
cluster-api-k3s v0.5.0's own e2e runs k3s 1.33/1.34; 1.35 is the newest line that is supported by every other piece
and still well inside k3s' maintained window - **VERIFY** on the first boot, then bump `kubernetesVersion` per fleet file.

### Feature gates
- `ClusterTopology` is alpha and **off by default** in core 1.13 -> set to `true` on the CoreProvider (and on CAPD,
  which shares core's gate set, as the upstream quickstart does). ClusterClasses do nothing without it.
- `ClusterResourceSet` (used for the OpenChoreo agent identity) is **GA in 1.13**: the controller always runs and the
  gate no longer exists. Do not list it: an unknown gate in `--feature-gates` makes the manager exit at startup.
- CAPA has its own gates (EKS, MachinePool, ...) and CAPH has no `--feature-gates` flag; neither gets ClusterTopology.

## Adding a cluster

One file: `installations/<inst>/clusters/<name>.yaml` (schema and defaults: `charts/cluster/values.yaml`). The `fleet`
ApplicationSet renders `charts/cluster` with `installation.yaml` + this file. The chart fails rendering (so Argo shows
the error) on: missing/invalid `name`, missing or non-k3s `kubernetesVersion`, unknown `provider`, a provider that the
installation does not enable, a cloud provider without `region`, non-boolean `addons.*`, workers without `name`.

| Fleet file | Becomes |
|---|---|
| `name` | `Cluster/<name>` in `fleet` (DNS label, max 32 chars - it prefixes machine/LB names) |
| `provider` | `topology.classRef.name: k3s-<provider>` |
| `kubernetesVersion` | `topology.version` (k3s release, `vX.Y.Z+k3sN`) |
| `controlPlane.replicas` | control plane replicas (1 or 3; k3s embedded etcd) |
| `controlPlane.machineType` | variable `controlPlaneMachineType` (aws, hetzner; ignored on docker) |
| `workers[]` `{name, replicas, machineType, failureDomain}` | machineDeployments of class `default-worker`; `machineType` -> per-MD override of `workerMachineType` |
| `region` | label; variable `region` (aws, hetzner) |
| `providerSpec.*` | ClusterClass variables as-is, last (can override generated ones) |
| `secrets.nodeRegistryAuth.enabled` (installation) | variable `registryAuth` + `ExternalSecret/<name>-registries` |
| `environment`, `addons`, `addonsRevision` | labels / annotation (conventions.md) |

ClusterClass variables:

| Class | Variable | Default | Notes |
|---|---|---|---|
| all | `registryAuth` | false | write `/etc/rancher/k3s/registries.yaml` from `Secret/<name>-registries` |
| k3s-docker | `kindImage` | `kindest/node:v1.35.8` | node container image |
| k3s-aws | `region` | (required) | |
| | `ami` | (required) | Ubuntu 24.04 (or any cloud-init AMI) in `region` |
| | `sshKeyName` | `""` | EC2 key pair; `""` = none (omitting it would make CAPA use key `default`) |
| | `controlPlaneMachineType`, `workerMachineType` | t3.large | |
| k3s-hetzner | `region` | (required) | fsn1, nbg1, hel1, ash, hil, sin |
| | `networkZone` | eu-central | must contain `region` |
| | `sshKey` | `""` | name of an SSH key in the Hetzner project |
| | `image` | ubuntu-24.04 | |
| | `controlPlaneMachineType`, `workerMachineType` | cpx31 | |

Removing the file deletes the cluster (Argo prune -> CAPI deletes machines and cloud resources).

### Template changes roll clusters
Machine templates are immutable, and CAPI changes a ClusterClass template by "new template + new reference". The
clusterclasses chart suffixes every template name with a hash of its spec, so a spec change in git renders a new name,
the ClusterClass follows, the topology controller rolls every cluster of that class (control plane first), and Argo
prunes the old template. Expect a rolling replacement of nodes after any edit to a template spec; a change to a
ClusterClass variable value in a fleet file rolls only that cluster.

### Node registry auth (private GHCR)
`charts/cluster/templates/capi-registries.yaml` renders `ExternalSecret/<name>-registries` (ns `fleet`) from the
`platform` store key `platform-ghcr` (`username`, `token`) into a k3s `registries.yaml`:
`configs."ghcr.io".auth.{username,password}`. Each class adds `files[].contentFrom.secret` (supported by
cluster-api-k3s v0.5.0: resolved by the bootstrap controller in the KThreesConfig's namespace, retried until the Secret
exists) on control plane and workers. Caveat: bootstrap data is rendered once per Machine, so a rotated token only
reaches new nodes - roll the machines (CAPI `rollout.after` on the topology control plane / machine deployments) or
use a long-lived read-only token. **VERIFY**

## Docker (CAPD) - local, tested path

- Prerequisites: mgmt is the k3d cluster `platform-mgmt` on Docker network `kind`, docker.sock mounted (bootstrap/).
  `installation.yaml`: `capi.providers.docker: true`. No secrets beyond `platform-ghcr` (node registry auth).
- Nodes are `kindest/node` containers; the bootstrap runs `curl get.k3s.io | sh` with the topology version. Lessons
  carried over from the predecessor lab: `preK3sCommands` wait until get.k3s.io answers (kindest DNS is not ready when
  CAPD starts the bootstrap, and a failed download "succeeds"), and workers get a `k3s-agent` `Type=exec` drop-in
  (with `Type=notify` the agent waits for CAPD to clear the uninitialized taint, which CAPD only does after the
  bootstrap returns: ~5 min deadlock). traefik is disabled on every class (kgateway is the ingress).
- Node identity: kubelet `--cloud-provider=external` + k3s CCM disabled (provider defaults); CAPD acts as the cloud
  provider: sets the Node's `providerID` and removes `node.cloudprovider.kubernetes.io/uninitialized`.
  klipper servicelb stays on, so `Service type=LoadBalancer` gets the node IP on the `kind` network.

### Which API server address lands in `<name>-kubeconfig`
CAPD runs an haproxy load balancer container `<name>-lb` on network `kind` and sets
`DockerCluster.spec.controlPlaneEndpoint.host` to **that container's IP on `kind`**, port 6443
(`dockercluster_backend.go`: host = LB container IPv4, only if empty). The k3s control plane provider writes the
kubeconfig for `https://<lb-ip>:6443` and adds the same address to the k3s TLS SANs. The LB also publishes 6443 on a
random host port on `0.0.0.0`, which nothing here uses.

- mgmt pods (CAPI controllers, Argo CD, ESO) run on the k3d node container, which is attached to `kind`: they reach the
  LB IP directly. This is what makes the Argo cluster secret built from `<name>-kubeconfig` work unmodified.
- The Linux host reaches container IPs on `kind` directly, so `clusterctl get kubeconfig dev1` works as-is from the
  host. On macOS / Docker Desktop it does not (rewrite the server to `127.0.0.1:<published port>` for host use).
- Caveat: the endpoint is recorded once. If Docker re-addresses the LB container (e.g. the network is recreated after a
  host reboot), the stored endpoint goes stale; recreate the cluster. **VERIFY** behaviour across a Docker restart.

## AWS (CAPA) - rendered only, untested

Prerequisites (once per account):
1. `clusterawsadm bootstrap iam create-cloudformation-stack` (creates the instance profiles
   `control-plane.cluster-api-provider-aws.sigs.k8s.io` / `nodes.cluster-api-provider-aws.sigs.k8s.io`; the control
   plane policy covers the AWS cloud-controller-manager).
2. Secret key `capi-aws` in the installation's `platform` store with property `AWS_B64ENCODED_CREDENTIALS`
   (`clusterawsadm bootstrap credentials encode-as-profile`). The capi-providers addon turns it into
   `capa-system/capa-variables`, the InfrastructureProvider's `configSecret`. On an EKS mgmt with IRSA/Pod Identity set
   `infrastructure.aws.credentialsFromStore: false` (empty credentials, CAPA uses its pod identity - **VERIFY**).
3. `installation.yaml`: `capi.providers.aws: true`; catalog entry `aws-ccm` (below).

Class `k3s-aws`: plain Ubuntu AMI (variable `ami`, no CAPA image lookup - those are kubeadm images), k3s installed at
boot, `cloudInit.insecureSkipSecretsManager: true` (plain AMIs lack CAPA's secrets-manager boot helper, so user data
incl. the k3s join token is readable via IMDS on the instance), classic ELB with a TCP health check (k3s' ECDSA cert
breaks the ELB SSL check), CNI ingress rule for flannel VXLAN (udp/8472) instead of CAPA's Calico defaults, servicelb
and traefik disabled.

Node identity / providerID: kubelet `--cloud-provider=external`, k3s CCM disabled, node name =
`{{ ds.meta_data.local_hostname }}` (cloud-init jinja; k3s bootstrap user data carries `## template: jinja`), i.e. the
EC2 private DNS name the AWS CCM expects. `addons/aws-ccm` (Argo CD, as soon as the cluster secret exists) sets
`providerID aws:///<az>/<instance-id>`, node addresses, clears the uninitialized taint, and serves
`Service type=LoadBalancer`. Its nodeSelector is overridden to `node-role.kubernetes.io/control-plane: "true"` (k3s'
label value; the chart default `""` never matches on k3s).

CSI (optional): aws-ebs-csi-driver as another workload addon with `providers: [aws]` (node instance profile needs the
EBS policy). Not included.

## Hetzner Cloud (CAPH) - rendered only, untested

Prerequisites:
1. Hetzner Cloud project + API token (read/write) as key `capi-hetzner`, property `hcloud`, in the `platform` store
   (Vault/OpenBao in `hetzner-example`). `addons/clusterclasses` renders `fleet/hetzner` from it; every HetznerCluster
   references it (`hetznerSecretRef: {name: hetzner, key: {hcloudToken: hcloud}}`).
2. Optional SSH key uploaded to the project (variable `sshKey`).
3. `installation.yaml`: `capi.providers.hetzner: true`; catalog entry `hcloud-ccm` (below).

Class `k3s-hetzner`: control plane behind a CAPH load balancer (`lb11`), private hcloud network (`networkZone`),
spread placement groups for control plane and workers, Ubuntu 24.04 image, k3s installed at boot, servicelb and traefik
disabled, flannel backend `wireguard-native` (k3s config drop-in `/etc/rancher/k3s/config.yaml.d/10-platform.yaml`):
pod traffic between nodes is encrypted and does not depend on hcloud routes (needs udp/51820 between nodes if you add a
Hetzner firewall). **VERIFY**

Node identity / providerID: kubelet `--cloud-provider=external`, k3s CCM disabled. CAPH names servers after the
Machine, the node name is the hostname, and the hcloud CCM matches them by name and sets `providerID hcloud://<id>`
(CAPH's upstream ClusterClass relies on the same; no kubelet `provider-id`). Credentials need no plumbing: CAPH writes
`kube-system/hcloud` (keys `token`, `hcloud`, `network`, `apiserver-host/port`) into each workload cluster once its API
answers (`reconcileWorkloadClusterSecrets`), and that is the hcloud CCM chart's default secret. `addons/hcloud-ccm`
runs with `networking.enabled: false` (no route controller; flannel does pod networking).

CSI (optional): hcloud-csi as another workload addon with `providers: [hetzner]`, reading the same `kube-system/hcloud`
secret. Not included.

## Catalog entries (charts/platform/values.yaml)

```yaml
aws-ccm:    { namespace: kube-system, roles: [workload], default: true, providers: [aws] }
hcloud-ccm: { namespace: kube-system, roles: [workload], default: true, providers: [hetzner] }
```

## Argo CD notes
- Provider CRs, ClusterClasses, templates and ExternalSecrets carry `SkipDryRunOnMissingResource=true`: their CRDs are
  installed by the operator/ESO in the same sync wave cascade; Argo retries until they exist.
- The cluster-api-operator CRDs are ~228 KB each, close to the 256 KB client-side-apply annotation limit: sync
  `capi-operator` with `ServerSideApply=true`. CAPI webhooks default many Cluster/ClusterClass fields: use server-side
  diff (or ignoreDifferences) for the `cluster-*` and `clusterclasses` Applications.

## Untested / VERIFY
`grep -rn VERIFY addons/capi-* addons/clusterclasses addons/*-ccm charts/cluster installations/*-example docs/providers.md`.
Highlights: k3s v1.35.10+k3s1 + kindest/node v1.35.8 on CAPD; registry-token rotation; everything AWS and Hetzner
(ELB type, flannel backends, CCM wiring, empty CAPA credentials with pod identity, ESO vs CAPH on the `hetzner` secret
labels, AMI IDs, example domains and secret-store shapes).
