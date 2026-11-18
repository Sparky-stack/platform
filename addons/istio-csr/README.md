# istio-csr

## Purpose

Wrapper chart for `cert-manager-istio-csr` (`v0.19.1`) on multicluster mesh members. Replaces `istiod`'s internal CA so workload and `istiod` certificates are signed by the shared mesh CA in OpenBao on `mgmt` via a cert-manager Vault `Issuer` and audience-bound ServiceAccount JWT auth.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`).
- **Catalog label:** `addons.platform.koorikla.io/istio-csr` (`default: false`, set to `"true"` by `charts/cluster` when `mesh.group` is set).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admission.certificates[0] | string | `"istiod"` |  |
| admission.enabled | bool | `true` | ValidatingAdmissionPolicy (`admission.{enabled,requesters,certificates}`) restricting `openbao-mesh` `CertificateRequest`s. |
| admission.requesters[0] | string | `"system:serviceaccount:istio-system:cert-manager-istio-csr"` |  |
| admission.requesters[1] | string | `"system:serviceaccount:cert-manager:cert-manager"` |  |
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
| installation.name | string | `"local"` |  |
| issuer.caSecret | string | `"openbao-ca"` |  |
| issuer.certManagerServiceAccount.name | string | `"cert-manager"` |  |
| issuer.certManagerServiceAccount.namespace | string | `"cert-manager"` |  |
| issuer.name | string | `"openbao-mesh"` | Vault `Issuer` (`issuer.{name,serviceAccount,role,caSecret}`) authenticating with `istio-csr-openbao` and `openbao-ca`. |
| issuer.role | string | `"istio-csr"` |  |
| issuer.serviceAccount | string | `"istio-csr-openbao"` |  |
| mesh.ca.host | string | `"openbao.openchoreo.localhost"` |  |
| mesh.ca.port | int | `8200` |  |
| mesh.group | string | `""` | Mesh group (`clusterLabelParameters`) and `mgmt` OpenBao endpoint (`mesh.ca.{host,port}`). |
| rootCA.key | string | `"root-cert.pem"` |  |
| rootCA.secret | string | `"mesh-root-ca"` | Pins `mesh-root-ca` (`root-cert.pem`) delivered from `mgmt` via CAPI `ClusterResourceSet`. |

## Day-2 notes

- Mesh CA rotation and Istio upgrades: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#2-openbao-mesh-ca-openbao--istio-csr) and [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Multicluster mesh](../../docs/multicluster.md)