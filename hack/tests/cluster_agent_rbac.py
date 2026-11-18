#!/usr/bin/env python3
"""RBAC of OpenChoreo's workflow-plane cluster-agent (#33, hack/tests/test_cluster_agent_rbac.sh).

Input: JSON documents, one per line (yq -o=json -I=0), of every manifest rendered for mgmt that can grant the agent
anything. Argument: <namespace>/<serviceaccount> of the agent. Prints one `VIOLATION: ...` line per broken invariant and
`GRANT <scope> <apiGroups> <resources> <verbs>` for every rule the agent gets; exit code 0 either way.
"""
import json
import sys

ns, sa = sys.argv[1].split("/", 1)
docs = [json.loads(line) for line in sys.stdin if line.strip() and line.strip() != "null"]
roles = {}
for d in docs:
    if d.get("kind") == "ClusterRole":
        roles[("ClusterRole", "", d["metadata"]["name"])] = d
    elif d.get("kind") == "Role":
        roles[("Role", d["metadata"].get("namespace", ""), d["metadata"]["name"])] = d

WRITE = {"create", "update", "patch", "delete", "deletecollection", "*"}
FORBIDDEN_VERBS = {"escalate", "bind", "impersonate"}
STORE_KINDS = {"clustersecretstores", "secretstores", "pushsecrets", "clusterexternalsecrets", "clusterpushsecrets"}
# The only cluster-wide grant: create the run namespace (the admission policy limits the name).
CLUSTER_ALLOWED = {("", "namespaces"): {"get", "create"}}
RUN_PREFIX = "workflows-"


def j(v):
    return json.dumps(sorted(v) if isinstance(v, set) else v)


def subject_is_agent(s):
    return s.get("kind") == "ServiceAccount" and s.get("name") == sa and s.get("namespace") == ns


out = []
for b in docs:
    if b.get("kind") not in ("ClusterRoleBinding", "RoleBinding"):
        continue
    if not any(subject_is_agent(s) for s in b.get("subjects") or []):
        continue
    bns = b["metadata"].get("namespace", "") if b["kind"] == "RoleBinding" else ""
    ref = b["roleRef"]
    key = (ref["kind"], "" if ref["kind"] == "ClusterRole" else bns, ref["name"])
    role = roles.get(key)
    where = f'{b["kind"]} {(bns + "/") if bns else ""}{b["metadata"]["name"]} -> {ref["kind"]} {ref["name"]}'
    if role is None:
        out.append(f"VIOLATION: {where}: role not rendered here (built-in or foreign role, e.g. cluster-admin)")
        continue
    if role.get("aggregationRule"):
        out.append(f"VIOLATION: {where}: aggregated ClusterRole (grants whatever is labelled into it)")
    scope = "cluster" if b["kind"] == "ClusterRoleBinding" else f"namespace:{bns}"
    if bns and not bns.startswith(RUN_PREFIX):
        out.append(f"VIOLATION: {where}: namespaced grant outside the run namespaces {RUN_PREFIX}*")
    for r in role.get("rules") or []:
        groups = r.get("apiGroups") or []
        res = r.get("resources") or []
        verbs = set(r.get("verbs") or [])
        out.append(f"GRANT {scope} {','.join(groups) or '-'} {','.join(res) or '-'} {','.join(sorted(verbs))}")
        if r.get("nonResourceURLs"):
            out.append(f"VIOLATION: {where}: nonResourceURLs {j(r['nonResourceURLs'])}")
        if "*" in groups or "*" in res or "*" in verbs:
            out.append(f"VIOLATION: {where}: wildcard in {j(groups)} {j(res)} {j(verbs)}")
        if verbs & FORBIDDEN_VERBS:
            out.append(f"VIOLATION: {where}: RBAC escalation verbs {j(verbs & FORBIDDEN_VERBS)}")
        for g in groups:
            for x in res:
                base = x.split("/")[0]
                if base in STORE_KINDS and g in ("external-secrets.io", "*"):
                    out.append(f"VIOLATION: {where}: secret store / push access ({x})")
                if base == "secrets" and g in ("", "*"):
                    if scope == "cluster" and verbs & WRITE:
                        out.append(f"VIOLATION: {where}: cluster-wide write verbs on secrets {j(verbs & WRITE)}")
                    elif scope == "cluster":
                        out.append(f"VIOLATION: {where}: cluster-wide read of secrets {j(verbs)}")
                    else:
                        out.append(f"VIOLATION: {where}: secrets in {bns} {j(verbs)} (runs get credentials from ESO)")
                if scope == "cluster":
                    allowed = CLUSTER_ALLOWED.get((g, x), set())
                    if not verbs <= allowed:
                        out.append(f"VIOLATION: {where}: cluster-wide {g or 'core'}/{x} {j(verbs - allowed)} (only namespaces get/create)")
print("\n".join(out))
