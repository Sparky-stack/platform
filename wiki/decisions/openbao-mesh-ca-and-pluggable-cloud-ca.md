---
title: OpenBao as Local Mesh CA with Pluggable Cloud CA
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [mesh, secrets, argocd]
confidence: high
---

# OpenBao as Local Mesh CA with Pluggable Cloud CA

## Context
Invariant 4 in [docs/conventions.md](../../docs/conventions.md#invariants) requires that CA private keys never leave the management cluster (`mgmt`). Istio multicluster ambient mesh needs a shared root/intermediate CA across workload clusters (`dev1`, `prod1`), and the platform must stay portable to cloud environments where teams use managed PKI.

## Decision
- Run **OpenBao** (the open-source Vault fork) on `mgmt` (`addons/openbao`) as the local mesh PKI (`pki-mesh-<group>-root` and `pki-mesh-<group>-int`), generating and keeping all CA private keys inside OpenBao.
- Workload clusters run **cert-manager** + **istio-csr** (`addons/mesh`, on mesh members); `istio-csr` authenticates to `mgmt` OpenBao using a per-cluster Kubernetes/JWT identity and requests workload/istiod certificates via a standard cert-manager `Issuer` (`openbao-mesh`).
- Keep the CA backend **pluggable**: in cloud deployments, the same cert-manager `Issuer` contract on workload clusters can point at AWS Private CA, Google CAS, Azure Key Vault, or an existing enterprise Vault/OpenBao without changing Istio or OpenChoreo templates.

## Alternatives rejected
- **Distributing `cacerts` private keys to workload clusters:** Violates Invariant 4; compromise of one workload cluster compromises the entire mesh trust domain.
- **Hardcoding OpenBao as the only supported PKI:** Forces cloud adopters to operate stateful OpenBao HA even when a cloud-managed CA is already mandated.

## Consequences
- Mesh members only receive public root CAs (`openbao-ca`, `mesh-root-ca`) via CAPI `ClusterResourceSet` (or ESO `PushSecret` for `provider: byo`).
- OpenBao policy changes on an already-initialized local cluster require a reconciler job ([OpenBao policy reconciler](../gotchas/openbao-policies-init-and-reconciler.md)).

## Links
- Date: 2026-11-16 (Issues #18, #19; PRs #4, #117, #186)
- Authoritative docs: [docs/multicluster.md](../../docs/multicluster.md), [docs/portability.md](../../docs/portability.md)
- Related wiki: [OpenBao policies only at init + reconciler](../gotchas/openbao-policies-init-and-reconciler.md), [Istio ambient port 15008 and telemetry DNS](../gotchas/istio-ambient-port-15008-and-telemetry-dns.md)
