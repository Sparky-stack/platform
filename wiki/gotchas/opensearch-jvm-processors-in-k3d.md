---
title: OpenSearch ActiveProcessorCount OOMKill in k3d
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [observability, bootstrap]
confidence: high
---

# OpenSearch ActiveProcessorCount OOMKill in k3d

## Symptom
On the local `k3d` management cluster, `opensearch-cluster-master-0` in `openchoreo-observability-plane` is `OOMKilled` (exit code 137) roughly every 45 minutes under normal log/trace ingest, and the Prometheus agent on workload clusters OOMs at its chart-default 256Mi limit (#49, #83).

## Cause
- Inside nested Docker/k3d containers without explicit JVM processor pinning, OpenSearch's JVM detects the host machine's full logical core count (e.g. 16-32 threads) rather than the pod's CPU limit (`1` core). It sizes Netty arenas, indexing thread pools, and off-heap buffers for dozens of cores, blowing past the container memory cgroup limit alongside the 512Mi heap.
- Similarly, the upstream telemetry Prometheus agent defaults to a 256Mi memory limit, which is too small once CAPI, Istio, and OpenChoreo metrics series are scraped (#83).

## Fix
- Pin `-XX:ActiveProcessorCount=1` (matching the container CPU limit) in OpenSearch's `OPENSEARCH_JAVA_OPTS` in `addons/openchoreo-observability-plane/values.yaml` (PR #205).
- Raise the local Prometheus agent memory limit in `addons/telemetry` (#83, PR #105).

## Where enforced
- `addons/openchoreo-observability-plane/values.yaml` and `addons/telemetry/values.yaml`.

## Links
- Issues #49, #83; PRs #105, #205
- Authoritative docs: [docs/observability.md](../../docs/observability.md), [docs/runbooks/observability-first-look.md](../../docs/runbooks/observability-first-look.md)
- Related wiki: [Istio ambient port 15008 and telemetry DNS](istio-ambient-port-15008-and-telemetry-dns.md), [Local platform lab scope](../decisions/local-lab-scope-byo-and-cloud-examples.md)
