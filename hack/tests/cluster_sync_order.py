"""Sync-wave order of one rendered charts/cluster app (hack/tests/test_cluster_sync_order.sh, #192).

Argo CD (gitops-engine sync_context.go) applies a sync wave, then waits while any resource of that wave is still
Progressing BEFORE it looks at resources that failed to apply. A resource that stays Progressing until another object
exists therefore hangs the operation forever when that object's apply fails in the same wave (a webhook briefly
unavailable): the operation neither fails nor retries. Live: Certificate <name>-mesh-reader (its Issuer needs
<name>-cca, which CAPI creates for the Cluster) waited while Cluster/<name> had failed on the CAPI webhook.

Rule checked here: every consumer comes in a strictly later wave than what it consumes, so a failed apply leaves no
waiting resource in its wave and the sync fails and retries. Edges:
  Certificate                 -> its Issuer (issuerRef)
  Issuer ca.secretName S      -> producer of S
  ExternalSecret remoteRef S  -> producer of S (store mgmt-fleet: secrets of this app's namespace)
Producers: Certificate spec.secretName; Cluster <name> -> CAPI's <name>-kubeconfig and <name>-cca.
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


producers = {}
for d in docs:
    spec = d.get("spec") or {}
    if d["kind"] == "Certificate" and spec.get("secretName"):
        producers[spec["secretName"]] = d
    if d["kind"] == "Cluster" and d.get("apiVersion", "").startswith("cluster.x-k8s.io/"):
        for suffix in ("kubeconfig", "cca"):
            producers["%s-%s" % (d["metadata"]["name"], suffix)] = d
issuers = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Issuer"}

edges = []   # (consumer, producer)
for d in docs:
    spec = d.get("spec") or {}
    if d["kind"] == "Certificate":
        iref = spec.get("issuerRef") or {}
        if iref.get("kind", "Issuer") == "Issuer" and iref.get("name") in issuers:
            edges.append((d, issuers[iref["name"]]))
    elif d["kind"] == "Issuer":
        s = (spec.get("ca") or {}).get("secretName")
        if s in producers:
            edges.append((d, producers[s]))
    elif d["kind"] == "ExternalSecret" and (spec.get("secretStoreRef") or {}).get("name") == "mgmt-fleet":
        for item in spec.get("data") or []:
            key = (item.get("remoteRef") or {}).get("key")
            if key in producers and (d, producers[key]) not in edges:
                edges.append((d, producers[key]))

fails = ["FAIL %s consumes %s: must be in a later sync wave" % (ref(c), ref(p)) for c, p in edges if wave(c) <= wave(p)]
print("\n".join(fails) if fails else "ok %d edges" % len(edges))
sys.exit(1 if fails else 0)
