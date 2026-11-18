---
title: Istio Ambient Port 15008 in Cell Policies and Telemetry DNS on *.localhost
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [mesh, observability, openchoreo]
confidence: high
---

# Istio Ambient Port 15008 in Cell Policies and Telemetry DNS on *.localhost

## Symptom
1. Enabling Istio ambient `STRICT` mTLS in OpenChoreo cell namespaces causes ingress requests from `kgateway` (or peer pods) to time out (#53).
2. Enrolling the `telemetry` namespace into the ambient mesh causes Prometheus / OTel shippers to fail resolving `*.localhost` ingest endpoints or fail scraping `PodMonitor` targets inside `STRICT` cells (#53, #104, #209).

## Cause
- **HBONE port 15008 dropped by cell NetworkPolicy:** OpenChoreo's `ProjectReleaseBinding` generates per-component `NetworkPolicy` rules that only open the component's declared application port. In Istio ambient mode, `ztunnel` tunnels all in-mesh traffic over **TCP port 15008 (HBONE)**, which standard Kubernetes `NetworkPolicy` evaluates on the destination pod.
- **ztunnel DNS capture on `*.localhost`:** When `telemetry` is enrolled in ambient mesh with `ISTIO_META_DNS_CAPTURE`, `ztunnel` intercepts `*.localhost` queries meant for k3d/HostAliases ingress (`opensearch.observability.localhost`), breaking telemetry shipping (#208).

## Fix
- Enroll `kgateway` ingress in the ambient mesh and add a supplementary `NetworkPolicy` in cell namespaces allowing ingress on TCP port `15008` alongside `STRICT` `PeerAuthentication` (PR #206; see #210 for Strimzi operator policies).
- Keep the `telemetry` namespace **out** of the ambient mesh (`addons/telemetry`, PR #208; see #209 for `PodMonitor` scraping into `STRICT` cells).

## Where enforced
- `addons/istio-ambient`, `addons/telemetry`, `addons/kyverno-policies`, and `hack/tests/test_mesh_admission.sh`.

## Links
- Issues #53, #104, #209, #210; PRs #206, #208
- Authoritative docs: [docs/networking.md](../../docs/networking.md), [docs/observability.md](../../docs/observability.md)
- Related wiki: [OpenBao as local mesh CA with pluggable cloud CA](../decisions/openbao-mesh-ca-and-pluggable-cloud-ca.md), [OpenSearch JVM processors in k3d](opensearch-jvm-processors-in-k3d.md)
