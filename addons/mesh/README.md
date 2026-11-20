# mesh

## Purpose

Umbrella chart for the Istio Ambient service mesh (`1.32.0`: `base`, `istiod`, `cni`, `ztunnel`), plus `cert-manager-istio-csr` (`v0.19.1`, Vault `Issuer` to OpenBao on `mgmt` and admission policies) and the multi-network east-west `Gateway` (`istio-eastwestgateway`) + `platform:istio-reader` discovery RBAC on multicluster mesh members (`values/mesh-member.yaml`).

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`; layers `values/cni-flannel.yaml` on flannel, `values/provider-gcp-gke.yaml` on GKE, `values/provider-aws.yaml` on AWS, `values/provider-docker.yaml` on docker (no ambient DNS capture: `*.localhost` hosts, #209), and `values/mesh-member.yaml` on mesh members).
- **Catalog label:** `addons.platform.koorikla.io/mesh` (`default: true`, opt-out with `"false"`); `mesh.csr.enabled` and `mesh.eastwest.enabled` turn on via `values/mesh-member.yaml` when `mesh.platform.koorikla.io/group` is set.

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admission.certificates[0] | string | `"istiod"` |  |
| admission.enabled | bool | `true` | ValidatingAdmissionPolicy (`admission.{enabled,requesters,certificates}`) restricting `openbao-mesh` `CertificateRequest`s. |
| admission.requesters[0] | string | `"system:serviceaccount:istio-system:cert-manager-istio-csr"` |  |
| admission.requesters[1] | string | `"system:serviceaccount:cert-manager:cert-manager"` |  |
| ambient.probeSourceCIDRs[0] | string | `"169.254.7.127/32"` |  |
| ambient.probeSourceCIDRs[1] | string | `"fd16:9254:7127:1337:ffff:ffff:ffff:ffff/128"` |  |
| base | object | `{}` |  |
| cert-manager-istio-csr.app.certmanager.issuer.group | string | `"cert-manager.io"` |  |
| cert-manager-istio-csr.app.certmanager.issuer.kind | string | `"Issuer"` |  |
| cert-manager-istio-csr.app.certmanager.issuer.name | string | `"openbao-mesh"` |  |
| cert-manager-istio-csr.app.certmanager.namespace | string | `"istio-system"` |  |
| cert-manager-istio-csr.app.controller.leaderElectionNamespace | string | `"istio-system"` |  |
| cert-manager-istio-csr.app.istio.namespace | string | `"istio-system"` |  |
| cert-manager-istio-csr.app.istio.revisions[0] | string | `"default"` |  |
| cert-manager-istio-csr.app.server.caTrustedNodeAccounts | string | `"istio-system/ztunnel"` |  |
| cert-manager-istio-csr.app.server.clusterID | string | `"Kubernetes"` |  |
| cert-manager-istio-csr.app.server.maxCertificateDuration | string | `"24h"` |  |
| cert-manager-istio-csr.app.server.serving.certificateKeySize | int | `256` |  |
| cert-manager-istio-csr.app.server.serving.signatureAlgorithm | string | `"ECDSA"` |  |
| cert-manager-istio-csr.app.tls.certificateDNSNames[0] | string | `"cert-manager-istio-csr.istio-system.svc"` |  |
| cert-manager-istio-csr.app.tls.certificateDuration | string | `"24h"` |  |
| cert-manager-istio-csr.app.tls.istiodCertificateDuration | string | `"48h"` |  |
| cert-manager-istio-csr.app.tls.istiodCertificateEnable | bool | `true` |  |
| cert-manager-istio-csr.app.tls.istiodCertificateRenewBefore | string | `"24h"` |  |
| cert-manager-istio-csr.app.tls.istiodPrivateKeyAlgorithm | string | `"ECDSA"` |  |
| cert-manager-istio-csr.app.tls.istiodPrivateKeySize | int | `256` |  |
| cert-manager-istio-csr.app.tls.rootCAFile | string | `"/var/run/secrets/istio-csr/root/root-cert.pem"` |  |
| cert-manager-istio-csr.app.tls.trustDomain | string | `"cluster.local"` |  |
| cert-manager-istio-csr.image.digest | string | `"sha256:eb1b8beee32f7dd830c301b7d2e061f46f9250b0421457e78b1017de8ffb9d86"` |  |
| cert-manager-istio-csr.image.repository | string | `"quay.io/jetstack/cert-manager-istio-csr"` |  |
| cert-manager-istio-csr.image.tag | string | `"v0.19.1"` |  |
| cert-manager-istio-csr.resources.limits.memory | string | `"128Mi"` |  |
| cert-manager-istio-csr.resources.requests.cpu | string | `"10m"` |  |
| cert-manager-istio-csr.resources.requests.memory | string | `"48Mi"` |  |
| cert-manager-istio-csr.volumeMounts[0].mountPath | string | `"/var/run/secrets/istio-csr/root"` |  |
| cert-manager-istio-csr.volumeMounts[0].name | string | `"root-ca"` |  |
| cert-manager-istio-csr.volumeMounts[0].readOnly | bool | `true` |  |
| cert-manager-istio-csr.volumes[0].name | string | `"root-ca"` |  |
| cert-manager-istio-csr.volumes[0].secret.items[0].key | string | `"root-cert.pem"` |  |
| cert-manager-istio-csr.volumes[0].secret.items[0].path | string | `"root-cert.pem"` |  |
| cert-manager-istio-csr.volumes[0].secret.secretName | string | `"mesh-root-ca"` |  |
| cluster.name | string | `"sample"` |  |
| cluster.provider | string | `"docker"` |  |
| cluster.region | string | `"local"` |  |
| cni.cni.resources.limits.memory | string | `"256Mi"` |  |
| cni.cni.resources.requests.cpu | string | `"25m"` |  |
| cni.cni.resources.requests.memory | string | `"64Mi"` |  |
| cni.image | string | `"docker.io/istio/install-cni:1.32.0-distroless@sha256:bf8fa30fe56fc7209941af23999f1463071b9885c22ec81f5998645718698787"` |  |
| cni.profile | string | `"ambient"` |  |
| gateway.loadBalancerSourceRanges | list | `[]` |  |
| gateway.name | string | `"istio-eastwestgateway"` | East-west Gateway sizing (`gateway.{name,replicas,serviceAnnotations,loadBalancerSourceRanges}`) and required peer egress CIDR allowlist outside Docker. |
| gateway.replicas | int | `1` |  |
| gateway.resources.limits.memory | string | `"256Mi"` |  |
| gateway.resources.requests.cpu | string | `"50m"` |  |
| gateway.resources.requests.memory | string | `"64Mi"` |  |
| gateway.serviceAnnotations | object | `{}` |  |
| global.istioNamespace | string | `"istio-system"` | Istio namespace (`global.{multiCluster.clusterName,meshID,network}` are populated from cluster labels; `global.platform` is `k3s` in `values/cni-flannel.yaml` and `gke` in `values/provider-gcp-gke.yaml`). |
| global.proxy.image | string | `"docker.io/istio/proxyv2:1.32.0-distroless@sha256:9cd1f1cc261f3fe250ab483543e7256c39d5871eae5f1817c0809eff09e365d4"` |  |
| installation.name | string | `"local"` |  |
| issuer.caSecret | string | `"openbao-ca"` |  |
| issuer.certManagerServiceAccount.name | string | `"cert-manager"` |  |
| issuer.certManagerServiceAccount.namespace | string | `"cert-manager"` |  |
| issuer.name | string | `"openbao-mesh"` | Vault `Issuer` (`issuer.{name,serviceAccount,role,caSecret}`) authenticating with `istio-csr-openbao` and `openbao-ca`. |
| issuer.role | string | `"istio-csr"` |  |
| issuer.serviceAccount | string | `"istio-csr-openbao"` |  |
| istiod.env.AMBIENT_ENABLE_BAGGAGE | string | `"false"` |  |
| istiod.env.AMBIENT_ENABLE_MULTI_NETWORK | string | `"false"` |  |
| istiod.image | string | `"docker.io/istio/pilot:1.32.0-distroless@sha256:219ab7efcf1fd1f883086ad4a4a649c0e70bee3200423d6eef9f435103a79423"` |  |
| istiod.pilot.autoscaleEnabled | bool | `false` |  |
| istiod.pilot.resources.limits.memory | string | `"512Mi"` |  |
| istiod.pilot.resources.requests.cpu | string | `"50m"` |  |
| istiod.pilot.resources.requests.memory | string | `"128Mi"` |  |
| istiod.profile | string | `"ambient"` | `ambient` profile (with `cni.profile` and `ztunnel.profile`, distroless `1.32.0` images pinned by multi-arch index digest; `istiod.env.ENABLE_CA_SERVER` is `"false"` in `values/mesh-member.yaml`). |
| mesh.ca.host | string | `"openbao.openchoreo.localhost"` |  |
| mesh.ca.port | int | `8200` |  |
| mesh.csr.enabled | bool | `false` |  |
| mesh.eastwest.enabled | bool | `false` |  |
| mesh.group | string | `""` | Mesh group and `network` labels (`clusterLabelParameters`), `mgmt` OpenBao endpoint (`mesh.ca.{host,port}`), and multicluster member toggles (`mesh.csr.enabled`, `mesh.eastwest.enabled`, enabled in `values/mesh-member.yaml`). |
| mesh.network | string | `""` |  |
| reader.enabled | bool | `true` | Scoped discovery RBAC (`reader.{enabled,user,remoteCredentialsSecrets}`) for `platform:istio-reader`. |
| reader.remoteCredentialsSecrets | bool | `false` |  |
| reader.user | string | `"platform:istio-reader"` |  |
| rootCA.key | string | `"root-cert.pem"` |  |
| rootCA.secret | string | `"mesh-root-ca"` | Pins `mesh-root-ca` (`root-cert.pem`) delivered from `mgmt` via CAPI `ClusterResourceSet`. |
| ztunnel.annotations."argocd.argoproj.io/sync-wave" | string | `"1"` |  |
| ztunnel.image | string | `"docker.io/istio/ztunnel:1.32.0-distroless@sha256:953a77fc17379301de4b7c6697b1668471c9c1f6ff912c9c5b78f454ab362180"` |  |
| ztunnel.podAnnotations | object | `{}` |  |
| ztunnel.profile | string | `"ambient"` |  |
| ztunnel.resources.limits.memory | string | `"512Mi"` |  |
| ztunnel.resources.requests.cpu | string | `"50m"` |  |
| ztunnel.resources.requests.memory | string | `"128Mi"` |  |

## Day-2 notes

- Values are checked by `values.schema.json` (`cluster.name` and `mesh.group` DNS labels, `mesh.ca.host`/`mesh.ca.port` required, CIDRs; `helm` prints the failing path). Outside-docker rules (`gateway.loadBalancerSourceRanges` required, `reader.remoteCredentialsSecrets` refused) are in `templates/validate.yaml`.
- Mesh CA rotation, member decommissioning and Istio upgrades: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#2-openbao-mesh-ca-openbao--mesh), [scaling and capacity](../../docs/runbooks/scaling-and-capacity.md#2-remove-decommission-a-workload-cluster) and [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-mesh).

## Links

- [Networking](../../docs/networking.md)
- [Multicluster mesh](../../docs/multicluster.md)