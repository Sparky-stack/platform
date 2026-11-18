"""Sync-wave order of one rendered charts/cluster app (hack/tests/test_cluster_sync_order.sh, #192).

Argo CD (gitops-engine sync_context.go) applies a sync wave, then waits while any resource of that wave is still
Progressing BEFORE it looks at resources that failed to apply, and it only starts the next wave once every resource of
this one is Healthy (a Degraded one fails the operation, which is retried). Only the final wave, when it holds no hook,
succeeds without waiting for health. Two ways to hang a cluster app for good, both seen live:
  - a resource stays Progressing until another object exists, and that object's apply failed in the same wave (CAPI
    webhook down): Certificate <name>-mesh-reader waited for CAPI's <name>-cca while Cluster/<name> had failed;
  - a resource waits on something that comes in a LATER wave, or on another app, in a non-final wave: a
    ClusterResourceSet matching no cluster (dev1's remote secret for its peers, with dev1 the only mesh member) never
    reports ResourcesApplied, and one whose payload Secret is templated in a later wave stays Degraded.

Rules checked here:
  1. every consumer comes in a strictly later wave than what it consumes. Edges:
       Certificate                 -> its Issuer (issuerRef)
       Issuer ca.secretName S      -> producer of S
       ExternalSecret remoteRef S  -> producer of S (store mgmt-fleet: secrets of this app's namespace)
       ClusterResourceSet          -> producers of its resources[] (ExternalSecret target, ConfigMap) and, when it
                                      selects exactly this cluster, the Cluster (it applies into that cluster)
     Producers: Certificate spec.secretName; ExternalSecret target name; ConfigMap; Cluster <name> -> CAPI's
     <name>-kubeconfig and <name>-cca.
  2. a ClusterResourceSet that selects other clusters than this one is in the final wave: its health is other apps'.
Input: one compact JSON document per line. Output: "ok <n> edges" or FAIL lines (exit 1).
"""
import json
import sys

docs = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
docs = [d for d in docs if isinstance(d, dict) and d.get("kind")]


def wave(d):
    return int(((d.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))


def ref(d):
    return "%s/%s (wave %d)" % (d["kind"], d["metadata"]["name"], wave(d))


producers = {}   # (kind, name) -> producing document; kind Secret or ConfigMap
clusters = []
for d in docs:
    spec = d.get("spec") or {}
    if d["kind"] == "Certificate" and spec.get("secretName"):
        producers[("Secret", spec["secretName"])] = d
    elif d["kind"] == "ExternalSecret":
        producers[("Secret", (spec.get("target") or {}).get("name") or d["metadata"]["name"])] = d
    elif d["kind"] == "ConfigMap":
        producers[("ConfigMap", d["metadata"]["name"])] = d
    elif d["kind"] == "Cluster" and d.get("apiVersion", "").startswith("cluster.x-k8s.io/"):
        clusters.append(d)
        for suffix in ("kubeconfig", "cca"):
            producers[("Secret", "%s-%s" % (d["metadata"]["name"], suffix))] = d
issuers = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Issuer"}
last = max([wave(d) for d in docs] or [0])

edges = []   # (consumer, producer)


def edge(c, p):
    if p is not None and p is not c and (c, p) not in edges:
        edges.append((c, p))


fails = []
for d in docs:
    spec = d.get("spec") or {}
    if d["kind"] == "Certificate":
        iref = spec.get("issuerRef") or {}
        if iref.get("kind", "Issuer") == "Issuer":
            edge(d, issuers.get(iref.get("name")))
    elif d["kind"] == "Issuer":
        edge(d, producers.get(("Secret", (spec.get("ca") or {}).get("secretName"))))
    elif d["kind"] == "ExternalSecret" and (spec.get("secretStoreRef") or {}).get("name") == "mgmt-fleet":
        for item in spec.get("data") or []:
            edge(d, producers.get(("Secret", (item.get("remoteRef") or {}).get("key"))))
    elif d["kind"] == "ClusterResourceSet":
        for r in spec.get("resources") or []:
            edge(d, producers.get((r.get("kind"), r.get("name"))))
        sel = spec.get("clusterSelector") or {}
        own = [c for c in clusters
               if sel.get("matchLabels") == {"platform.koorikla.io/name": c["metadata"]["name"]}
               and not sel.get("matchExpressions")]
        for c in own:
            edge(d, c)
        if not own and wave(d) != last:
            fails.append("FAIL %s selects other clusters than this one: must be in the final wave (%d)" % (ref(d), last))

fails += ["FAIL %s consumes %s: must be in a later sync wave" % (ref(c), ref(p)) for c, p in edges if wave(c) <= wave(p)]
print("\n".join(fails) if fails else "ok %d edges" % len(edges))
sys.exit(1 if fails else 0)
