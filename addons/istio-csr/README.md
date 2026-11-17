# istio-csr

## Purpose

Wrapper chart for `cert-manager-istio-csr` (`v0.19.1`) on multicluster mesh members. Replaces `istiod`'s internal CA so workload and `istiod` certificates are signed by the shared mesh CA in OpenBao on `mgmt` via a cert-manager Vault `Issuer` and audience-bound ServiceAccount JWT auth.

## Where it runs

- **Roles / providers:** `roles: [workload]`, all providers (`namespace: istio-system`).
- **Catalog label:** `addons.platform.koorikla.io/istio-csr` (`default: false`, set to `"true"` by `charts/cluster` when `mesh.group` is set).

## Key values

- `mesh.{group,ca.host,ca.port}`: mesh group (`clusterLabelParameters`) and `mgmt` OpenBao endpoint.
- `issuer.{name,serviceAccount,role,caSecret}`: Vault `Issuer` (`openbao-mesh`) authenticating with `istio-csr-openbao` and `openbao-ca`.
- `rootCA.{secret,key}`: pins `mesh-root-ca` (`root-cert.pem`) delivered from `mgmt` via CAPI `ClusterResourceSet`.
- `admission.{enabled,requesters,certificates}`: ValidatingAdmissionPolicy restricting `openbao-mesh` `CertificateRequest`s.

## Day-2 notes

- Mesh CA rotation and Istio upgrades: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#2-openbao-mesh-ca-openbao--istio-csr) and [upgrades](../../docs/runbooks/upgrades.md#5-istio-ambient-istio-ambient-istio-csr-istio-eastwest).

## Links

- [Multicluster mesh](../../docs/multicluster.md)
