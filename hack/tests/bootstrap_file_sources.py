#!/usr/bin/env python3
"""Check that every Secret a cluster's bootstrap files reference exists before the Cluster is applied.

Usage: bootstrap_file_sources.py <clusterclasses.jsonl> <cluster.jsonl>
Both files hold one JSON document per line (yq -o=json -I=0); in the ClusterClass documents every
jsonPatches[].valueFrom.template is also present parsed as valueFrom.parsed (yq from_yaml).

cluster-api-k3s v0.5.0 resolves KThreesConfig files[].contentFrom.secret once, at bootstrap, and its controller watches
only KThreesConfigs: a Secret that appears later is picked up on backoff/resync only (minutes). So for each topology
Cluster, every contentFrom Secret of its class that is enabled for the Cluster's variables must be rendered by the same
chart as an ExternalSecret in namespace fleet, carry the referenced key, and sit in an earlier Argo sync wave than the
Cluster. Prints one line per check; exit 1 on any failure. Stdlib only (hack/lib/portable.sh: Python >= 3.8).
"""
import json
import re
import sys

CLUSTER_NAME = re.compile(r"\{\{\s*\.builtin\.cluster\.name\s*\}\}")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return [d for d in (json.loads(line) for line in fh if line.strip()) if d]


def lookup(ctx, path):
    cur = ctx
    for part in path.strip(".").split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(f"variable .{path} not set")
        cur = cur[part]
    return cur


def cond(expr, ctx):
    """Go template condition subset used by the classes: .a | and .a .b ... | eq .a "v"."""
    toks = re.findall(r'"[^"]*"|\S+', expr.strip())
    if len(toks) == 1 and toks[0].startswith("."):
        return bool(lookup(ctx, toks[0]))
    if toks[0] == "and" and all(t.startswith(".") for t in toks[1:]):
        return all(lookup(ctx, t) for t in toks[1:])
    if toks[0] == "eq" and len(toks) == 3 and toks[1].startswith(".") and toks[2].startswith('"'):
        return str(lookup(ctx, toks[1])) == toks[2].strip('"')
    raise ValueError(f"unsupported enabledIf condition: {expr!r}")


def enabled(enabled_if, ctx):
    if not enabled_if:
        return True
    m = re.fullmatch(r"\s*\{\{-?\s*if\s+(.+?)\s*-?\}\}\s*true\s*\{\{-?\s*end\s*-?\}\}\s*", enabled_if)
    if m:
        return cond(m.group(1), ctx)
    m = re.fullmatch(r"\s*\{\{-?\s*(\.[\w.]+)\s*-?\}\}\s*", enabled_if)
    if m:
        return str(lookup(ctx, m.group(1))).lower() == "true"
    raise ValueError(f"unsupported enabledIf: {enabled_if!r}")


def content_from(node):
    """Yield (secret name, key) for every files[] entry with contentFrom.secret below node."""
    if isinstance(node, dict):
        secret = (node.get("contentFrom") or {}).get("secret")
        if secret:
            yield secret["name"], secret["key"]
        for v in node.values():
            yield from content_from(v)
    elif isinstance(node, list):
        for v in node:
            yield from content_from(v)


def wave(doc):
    return int(((doc.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))


def refs(cc):
    """(patch name, enabledIf, secret name template, key) for every contentFrom a ClusterClass patch adds."""
    out = []
    for p in cc["spec"].get("patches", []):
        for d in p.get("definitions", []):
            for jp in d.get("jsonPatches", []):
                val = jp.get("value", (jp.get("valueFrom") or {}).get("parsed"))
                for name, key in content_from(val):
                    out.append((p["name"], p.get("enabledIf", ""), name, key))
    return out


def main():
    cc_docs, cl_docs = load(sys.argv[1]), load(sys.argv[2])
    by = {(d["kind"], d["metadata"]["name"]): d for d in cc_docs}
    failures = checks = 0
    for cl in (d for d in cl_docs if d["kind"] == "Cluster"):
        name, topo = cl["metadata"]["name"], cl["spec"]["topology"]
        cc = by[("ClusterClass", topo["classRef"]["name"])]
        spec = cc["spec"]
        ctx = {v["name"]: v["schema"]["openAPIV3Schema"]["default"]
               for v in spec.get("variables", []) if "default" in v["schema"]["openAPIV3Schema"]}
        ctx.update({v["name"]: v["value"] for v in topo.get("variables", [])})
        ctx["builtin"] = {"cluster": {"name": name, "namespace": cl["metadata"]["namespace"]}}
        found = refs(cc)
        # base templates of the class (control plane + worker bootstrap) are always in effect
        base = [spec["controlPlane"]["templateRef"]] + [
            md["bootstrap"]["templateRef"] for md in spec.get("workers", {}).get("machineDeployments", [])]
        for ref in base:
            for sname, key in content_from(by[(ref["kind"], ref["name"])]["spec"]):
                found.append(("<base " + ref["name"] + ">", "", sname, key))
        sources = {}
        for d in cl_docs:
            if d["kind"] == "ExternalSecret" and d["metadata"].get("namespace") == "fleet":
                sources[d["spec"]["target"].get("name", d["metadata"]["name"])] = d
        for patch, enabled_if, tmpl, key in dict.fromkeys(found):   # control plane + worker definitions repeat
            if not enabled(enabled_if, ctx):
                continue
            checks += 1
            secret = CLUSTER_NAME.sub(name, tmpl)
            where = f"{name}: {patch} -> Secret fleet/{secret} key {key}"
            es = sources.get(secret)
            if es is None:
                print(f"  FAIL {where}: no ExternalSecret renders it"); failures += 1; continue
            keys = set((es["spec"]["target"].get("template") or {}).get("data", {}))
            if key not in keys:
                print(f"  FAIL {where}: ExternalSecret {es['metadata']['name']} has no key {key}"); failures += 1
            if wave(es) >= wave(cl):
                print(f"  FAIL {where}: ExternalSecret sync wave {wave(es)} is not before the Cluster's ({wave(cl)})")
                failures += 1
            else:
                print(f"  ok   {where} (wave {wave(es)} < {wave(cl)})")
    print(f"  {checks} reference(s) checked, {failures} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
