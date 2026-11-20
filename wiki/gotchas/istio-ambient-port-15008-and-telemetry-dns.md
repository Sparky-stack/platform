---
title: Istio Ambient Port 15008 in Cell Policies and Telemetry DNS on *.localhost
created: 2026-11-18
updated: 2026-11-20
type: gotcha
tags: [mesh, observability, openchoreo]
confidence: high
---

# Istio Ambient Port 15008 in Cell Policies and Telemetry DNS on *.localhost

## Symptom
1. Enabling Istio ambient `STRICT` mTLS in OpenChoreo cell namespaces causes ingress requests from `kgateway` (or peer pods) to time out (#53).
2. With probes on cell components (#251), pods in ambient cells CrashLoop: `Startup probe failed: Get "http://<pod-ip>:8080/healthz": context deadline exceeded`, then `Container main failed startup probe, will be restarted`. `cilium-dbg monitor --type drop` in the node's cilium pod shows `drop (Policy denied) ... identity world->...: 169.254.7.127:<port> -> <pod-ip>:8080 tcp SYN`.
3. Enrolling the `telemetry` namespace into the ambient mesh causes Prometheus / OTel shippers to fail resolving `*.localhost` ingest endpoints or fail scraping `PodMonitor` targets inside `STRICT` cells (#53, #104, #209).

## Cause
- **HBONE port 15008 dropped by cell NetworkPolicy:** OpenChoreo's `ProjectReleaseBinding` generates per-component `NetworkPolicy` rules that only open the component's declared application port. In Istio ambient mode, `ztunnel` tunnels all in-mesh traffic over **TCP port 15008 (HBONE)**, which standard Kubernetes `NetworkPolicy` evaluates on the destination pod.
- **Kubelet probes SNATed to `169.254.7.127`:** istio-cni rewrites the source of every kubelet probe into an enrolled pod to the link-local `169.254.7.127` (IPv6 `fd16:9254:7127:1337:ffff:ffff:ffff:ffff`) so ztunnel can exempt it from mTLS. Cilium classifies that source as `world`, not `host`, so OpenChoreo's per-component policy (app port only from the cell and system components) drops it. ztunnel's exemption doesn't help: the CNI drops the SYN first. Istio docs: "Ambient and Kubernetes NetworkPolicy" > "Ambient, health probes, and Kubernetes NetworkPolicy".
- **ztunnel DNS capture on `*.localhost`:** When `telemetry` is enrolled in ambient mesh with `ISTIO_META_DNS_CAPTURE`, `ztunnel` intercepts `*.localhost` queries meant for k3d/HostAliases ingress (`opensearch.observability.localhost`), breaking telemetry shipping (#208).

## Fix
- Enroll `kgateway` ingress in the ambient mesh and add a supplementary `NetworkPolicy` in cell namespaces allowing ingress on TCP port `15008` alongside `STRICT` `PeerAuthentication` (PR #206; see #210 for Strimzi operator policies).
- The same platform `NetworkPolicy` `platform-mesh-hbone` carries a second rule: ingress on any port from `169.254.7.127/32` and the IPv6 equivalent, scoped to the pods OpenChoreo isolates (`openchoreo.dev/component`). Selecting all pods (`podSelector: {}`) would newly isolate pods no other policy selects. Any other policy that isolates an ambient pod needs the same rule.
- Keep the `telemetry` namespace **out** of the ambient mesh (`addons/telemetry`, PR #208). Scraping into `STRICT` cells (#209): enroll only the Prometheus agent pod (prometheus-operator `--labels=istio.io/dataplane-mode=ambient,openchoreo.dev/system-component=prometheus-agent`; the upstream PrometheusAgent has no podMetadata) and turn off ambient DNS capture on docker clusters (addon mesh `values/provider-docker.yaml`). The per-pod `ambient.istio.io/dns-capture: "false"` annotation would be narrower, but nothing can set it on the agent pod. Both pieces are needed: outside the mesh STRICT resets the scrape, and without the peer label the CNI drops HBONE 15008.
- STRICT is authentication, not authorization (#324): any mesh workload (another cell, or a pod carrying the `openchoreo.dev/system-component` label the CNI trusts) still got in. Each cell now gets AuthorizationPolicy `platform-cell-peers` (ALLOW, no selector: deny-by-default for every pod, databases included) admitting the cell's own namespace plus `ambientEnrollment.mtls.platformPeers`. Read the real principals from ztunnel's `istio_tcp_connections_opened_total{reporter="destination"}` (`kubectl get --raw /api/v1/namespaces/istio-system/pods/<ztunnel>:15020/proxy/metrics`), not from guesses: on dev1 they were the gateway, the Prometheus agent, `cnpg-system/sa/cnpg` and same-cell pods. A permissive (opted-out) cell needs an allow-all rule: plaintext has no identity, so any principal/namespace rule refuses it.
- Testing `*.localhost` from a pod with curl proves nothing: curl resolves `*.localhost` to loopback itself (RFC 6761). Use `nslookup`, then curl the IP with a `Host:` header.

## Where enforced
- `addons/mesh`, `addons/telemetry`, `addons/kyverno-policies`, and `hack/tests/test_mesh_admission.sh`; probe rule: `addons/kyverno-policies/templates/cell-mesh.yaml`, `hack/tests/test_kyverno_policies.sh` (structural check of the generated policy), helm-unittest `addons/kyverno-policies/tests/kyverno_policies_test.yaml`.

## Links
- Issues #53, #104, #209, #210, #251, #324; PRs #206, #208, #264
- Authoritative docs: [docs/networking.md](../../docs/networking.md), [docs/observability.md](../../docs/observability.md)
- Related wiki: [OpenBao as local mesh CA with pluggable cloud CA](../decisions/openbao-mesh-ca-and-pluggable-cloud-ca.md), [OpenSearch JVM processors in k3d](opensearch-jvm-processors-in-k3d.md)
