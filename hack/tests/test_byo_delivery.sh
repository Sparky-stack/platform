#!/usr/bin/env bash
# provider byo (#173, docs/providers.md "Bring your own cluster (byo)"): a cluster registered without CAPI gets every
# object a CAPI cluster receives through ClusterResourceSets, by ESO PushSecret instead, and nothing more private.
# For every fleet file of every installation (enabled or *.disabled), charts/cluster is rendered twice - as the file says
# and as its twin of the other kind (CAPI <-> byo) - and compared:
#   1. the byo render has no CAPI object (cluster.x-k8s.io, ClusterResourceSet, KThrees*, node registry config)
#   2. every object inside a CRS payload of the CAPI render (Secret / ConfigMap by namespace + name, its type and data
#      keys; Namespaces excepted: the owning addons create them on byo) reaches the byo cluster:
#        Secret      a PushSecret to <namespace>/<name> whose source has the same type and keys
#        ConfigMap   a PushSecret to platform-delivery/<x> + an addon ExternalSecret (provider-byo values, store
#                    `delivery`, generic target ConfigMap) that rebuilds <namespace>/<name> with the same keys from <x>
#      and nothing is pushed that the CAPI render does not deliver. Mesh payloads are compared without mesh.group on
#      both sides: byo mesh members are #174 (charts/cluster refuses mesh.group on byo)
#   3. invariant 4: no PushSecret pushes a CA's Secret (a Certificate with isCA) or anything read from another
#      cluster's identity; every pushed Secret is either an ExternalSecret target of this render or a non-CA
#      cert-manager Certificate of this cluster
# A new CRS payload without its byo delivery, or a PushSecret of a CA key, fails here.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh
unset RENDERED_DIR   # twins are rendered under the names of real clusters: never reuse the suite's renders

docs_json() { yq ea -o=json -I=0 '[.]' "$1"; }

CAPI_TWIN=(--set provider=docker --set kubernetesVersion=v1.35.10+k3s1 --set capi.providers.docker=true --set cni=flannel)
BYO_TWIN=(--set provider=byo --set kubernetesVersion= --set controlPlane=null --set workers=null --set providerSpec=null
  --set mesh.group= --set addons.cilium=false)

checked=0
for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  prender="$TMP/platform-$inst.yaml"
  render_platform "$inst" "$prender"
  # The byo halves of the addons: the ConfigMaps rebuilt from platform-delivery, and the shared gateway CA payload
  render_layered_addon "$inst" openchoreo-data-plane "$TMP/dp-$inst.yaml" "$prender" workload sample byo development local flannel https://192.0.2.10:6443
  render_layered_addon "$inst" kyverno "$TMP/ky-$inst.yaml" "$prender" workload sample byo development local flannel https://192.0.2.10:6443
  render_layered_addon "$inst" openchoreo-control-plane "$TMP/cp-$inst.yaml" "$prender" mgmt mgmt docker mgmt local flannel https://kubernetes.default.svc
  cat "$TMP/dp-$inst.yaml" "$TMP/ky-$inst.yaml" > "$TMP/byo-addons-$inst.yaml"
  docs_json "$TMP/byo-addons-$inst.yaml" > "$TMP/byo-addons-$inst.json"
  docs_json "$TMP/cp-$inst.yaml" > "$TMP/cp-$inst.json"

  for cf in "$inst_dir"/clusters/*.yaml "$inst_dir"/clusters/*.yaml.disabled; do
    [[ -f "$cf" ]] || continue
    c=$(yq -r '.name' "$cf")
    base=(helm template "cluster-$c" charts/cluster --namespace fleet --values "$inst_dir/installation.yaml" --values "$cf")
    if [[ "$(yq -r '.provider // "docker"' "$cf")" == byo ]]; then
      "${base[@]}" > "$TMP/byo.yaml"
      "${base[@]}" "${CAPI_TWIN[@]}" > "$TMP/capi.yaml"
    else
      "${base[@]}" --set mesh.group= > "$TMP/capi.yaml"   # like for like: byo has no mesh membership yet (#174)
      "${base[@]}" "${BYO_TWIN[@]}" > "$TMP/byo.yaml"
    fi
    docs_json "$TMP/capi.yaml" > "$TMP/capi.json"
    docs_json "$TMP/byo.yaml" > "$TMP/byo.json"
    out=$(py - "$TMP/capi.json" "$TMP/byo.json" "$TMP/cp-$inst.json" "$TMP/byo-addons-$inst.json" "$c" <<'PY'
import json, re, sys
capi, byo, cp, addons = (json.load(open(p)) or [] for p in sys.argv[1:5])
name = sys.argv[5]
capi = [d for d in capi if d]; byo = [d for d in byo if d]; cp = [d for d in cp if d]; addons = [d for d in addons if d]
problems = []

def payload_objects(text):
    """objects in a CRS payload (an ESO template of multi-document YAML): kind, namespace, name, type, data keys"""
    objs = []
    for doc in re.split(r"(?m)^---\s*$", text):
        if not re.search(r"(?m)^kind:", doc):
            continue
        g = lambda pat: (re.search(pat, doc, re.M) or [None, None])[1]
        keys, in_data = set(), False
        for line in doc.splitlines():
            if re.match(r"^data:\s*$", line):
                in_data = True; continue
            if in_data:
                m = re.match(r"^  ([A-Za-z0-9._-]+):", line)
                if m: keys.add(m.group(1))
                elif re.match(r"^\S", line): in_data = False
        if re.search(r"(?m)^\s*\{\{-? range \$k", doc):
            keys = None   # dynamic keys (dataFrom extract)
        objs.append(dict(kind=g(r"^kind:\s*(\S+)"), ns=g(r"^  namespace:\s*(\S+)"), name=g(r"^  name:\s*(\S+)"),
                         type=g(r"^type:\s*(\S+)"), keys=keys))
    return objs

def es_by_target(docs):
    return {d["spec"]["target"]["name"]: d for d in docs if d.get("kind") == "ExternalSecret" and d["metadata"].get("namespace") == "fleet"}

# 1. no CAPI objects on byo
for d in byo:
    api, kind = d.get("apiVersion", ""), d.get("kind")
    if "cluster.x-k8s.io" in api:
        problems.append("byo renders CAPI object %s/%s" % (kind, d["metadata"]["name"]))
    if kind == "ExternalSecret" and d["metadata"]["name"].endswith("-registries"):
        problems.append("byo renders node registry config %s" % d["metadata"]["name"])

# 2. what CAPI delivers
capi_es = es_by_target(capi + cp)
want = {}
for d in capi:
    if d.get("kind") != "ClusterResourceSet":
        continue
    sel = d["spec"]["clusterSelector"]
    if (sel.get("matchLabels") or {}).get("platform.koorikla.io/name") != name:
        continue   # mesh remote secrets go to peers, not to this cluster
    for r in d["spec"]["resources"]:
        src = capi_es.get(r["name"])
        if not src:
            problems.append("CRS %s lists %s %s, not found as an ExternalSecret payload" % (d["metadata"]["name"], r["kind"], r["name"]))
            continue
        for text in (src["spec"]["target"].get("template", {}).get("data") or {}).values():
            for o in payload_objects(text):
                if o["kind"] != "Namespace":
                    want[(o["kind"], o["ns"], o["name"])] = o

# what byo pushes
byo_es = es_by_target(byo)
certs = {d["spec"]["secretName"]: d for d in byo if d.get("kind") == "Certificate"}
cm_rebuilt = {}
for d in addons:
    t = d.get("spec", {}).get("target", {})
    if d.get("kind") == "ExternalSecret" and (t.get("manifest") or {}).get("kind") == "ConfigMap" \
            and d["spec"]["secretStoreRef"]["name"] == "delivery":
        srcs = {x["remoteRef"]["key"] for x in d["spec"]["data"]}
        for s in srcs:
            cm_rebuilt[s] = (d["metadata"]["namespace"], t["name"], {x["secretKey"] for x in d["spec"]["data"]})

def source_shape(src):
    if src in byo_es:
        es = byo_es[src]
        tpl = es["spec"]["target"].get("template") or {}
        if es["spec"].get("dataFrom"):
            return tpl.get("type", "Opaque"), None
        keys = set((tpl.get("data") or {}).keys()) or {x["secretKey"] for x in es["spec"].get("data", [])}
        return tpl.get("type", "Opaque"), keys
    if src in certs:
        if certs[src]["spec"].get("isCA"):
            problems.append("invariant 4: PushSecret source %s is a CA's Secret" % src)
        return "kubernetes.io/tls", {"tls.crt", "tls.key", "ca.crt"}
    problems.append("PushSecret source %s is neither an ExternalSecret target nor a cert-manager Secret of this render" % src)
    return None, None

got = {}
for d in byo:
    if d.get("kind") != "PushSecret":
        continue
    src = d["spec"]["selector"]["secret"]["name"]
    if re.search(r"-(agent-ca|cca|ca-key)$", src) or "selfsigned" in src:
        problems.append("invariant 4: PushSecret %s pushes %s" % (d["metadata"]["name"], src))
    stype, keys = source_shape(src)
    for e in d["spec"]["data"]:
        rns = e["metadata"]["spec"]["remoteNamespace"]; rname = e["match"]["remoteRef"]["remoteKey"]
        if e["match"].get("secretKey") or e["match"]["remoteRef"].get("property"):
            problems.append("PushSecret %s pushes single keys: push whole Secrets" % d["metadata"]["name"])
        if rns == "platform-delivery":
            if rname not in cm_rebuilt:
                problems.append("platform-delivery/%s is pushed but no addon rebuilds a ConfigMap from it" % rname)
                continue
            cns, cname, ckeys = cm_rebuilt[rname]
            if keys is not None and keys != ckeys:
                problems.append("ConfigMap %s/%s rebuilt from keys %s, pushed %s" % (cns, cname, sorted(ckeys), sorted(keys)))
            got[("ConfigMap", cns, cname)] = dict(type=None, keys=ckeys)
        else:
            got[("Secret", rns, rname)] = dict(type=stype, keys=keys)

for k, o in sorted(want.items()):
    if k not in got:
        problems.append("CAPI delivers %s %s/%s, byo does not" % k)
        continue
    g = got[k]
    if k[0] == "Secret" and o["type"] and g["type"] and o["type"] != g["type"]:
        problems.append("%s %s/%s: type %s on CAPI, %s on byo" % (k + (o["type"], g["type"])))
    if o["keys"] is not None and g["keys"] is not None and o["keys"] != g["keys"]:
        problems.append("%s %s/%s: keys %s on CAPI, %s on byo" % (k + (sorted(o["keys"]), sorted(g["keys"]))))
for k in sorted(set(got) - set(want)):
    problems.append("byo pushes %s %s/%s, which CAPI clusters do not get" % k)
if not want:
    problems.append("no CRS payload found for %s (test would prove nothing)" % name)
print("\n".join(problems) if problems else "OK %d" % len(want))
PY
)
    if [[ "$out" == OK* ]]; then
      assert_eq ok ok "$inst/$c: byo delivers what CAPI delivers (${out#OK } objects)"
    else
      assert_eq "$out" "" "$inst/$c: byo delivery == CAPI delivery"
    fi
    checked=$((checked + 1))
  done
done
assert_match "$checked" '^[1-9][0-9]*$' "at least one fleet file checked"
finish
