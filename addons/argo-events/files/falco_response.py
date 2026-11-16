#!/usr/bin/env python3
# Falco escalation response (addon argo-events, WorkflowTemplate falco-response; docs/observability.md "Falco response").
#
# Steps (argv[1]):
#   enrich  event (env EVENT, falcosidekick JSON) + the cluster it came from (env CLUSTER: the Sensor trigger of the
#           per-cluster webhook endpoint whose token authenticated the sender) -> context JSON on stdout: cluster, org
#           namespace, project, component, environment, data plane, workload, from OpenChoreo control-plane objects on
#           mgmt (RenderedRelease status lists every resource it applied to a data plane; Environment ->
#           ClusterDataPlane). Read-only RBAC. Skips events whose `cluster` field (falcosidekick customfield) or whose
#           namespace's data plane is another cluster: a cluster can only escalate about its own workloads.
#   record  Kubernetes Event on the OpenChoreo Component (org namespace) so the escalation is visible next to it.
#   rca     POST the OpenChoreo RCA agent's analyze endpoint (only when the agent is enabled).
#   notify  POST a compact JSON notification to NOTIFY_URL (only when configured).
# Containment is not done here: Talon already acted on the data plane (label/terminate, optional NetworkPolicy
# isolation), and mgmt holds no data-plane write credentials for workflows by design.
# Stdlib only.
import datetime as dt
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
PRIORITIES = ["emergency", "alert", "critical", "error", "warning", "notice", "informational", "debug"]


def env(name, default=""):
    return os.environ.get(name, default).strip()


def kube(method, path, body=None):
    host = "https://%s:%s" % (env("KUBERNETES_SERVICE_HOST"), env("KUBERNETES_SERVICE_PORT", "443"))
    with open(SA + "/token") as f:
        token = f.read().strip()
    ctx = ssl.create_default_context(cafile=SA + "/ca.crt")
    req = urllib.request.Request(host + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                          "Accept": "application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
        return json.loads(resp.read() or b"{}")


def post(url, body, headers=None):
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, method="POST", data=json.dumps(body).encode(), headers=hdrs)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, resp.read()[:500].decode(errors="replace")


def severe_enough(priority, minimum):
    p, m = priority.lower(), minimum.lower()
    return p in PRIORITIES and m in PRIORITIES and PRIORITIES.index(p) <= PRIORITIES.index(m)


def match_workload(renderedreleases, namespace, pod):
    """(RenderedRelease, resource) whose applied workload owns the pod (name prefix), or (None, None)."""
    best = (None, None, -1)
    for rr in renderedreleases:
        for r in (rr.get("status") or {}).get("resources") or []:
            if r.get("namespace") != namespace:
                continue
            name = r.get("name", "")
            if r.get("kind") in ("Deployment", "StatefulSet", "CronJob", "Job", "DaemonSet") \
                    and pod.startswith(name + "-") and len(name) > best[2]:
                best = (rr, r, len(name))
    return best[0], best[1]


def enrich(event, cluster=""):
    fields = event.get("output_fields") or {}
    ns, pod = fields.get("k8s.ns.name") or "", fields.get("k8s.pod.name") or ""
    claimed = fields.get("cluster") or ""
    ctx = {
        "cluster": cluster, "uuid": event.get("uuid", ""), "rule": event.get("rule", ""), "priority": event.get("priority", ""),
        "time": event.get("time", ""), "output": event.get("output", ""), "hostname": event.get("hostname", ""),
        "tags": event.get("tags") or [], "dataPlaneNamespace": ns, "pod": pod,
        "container": fields.get("container.name", ""), "image": fields.get("container.image.repository", ""),
        "process": fields.get("proc.cmdline") or fields.get("proc.name") or "",
        "namespace": "", "project": "", "component": "", "environment": "", "dataPlane": "", "workload": "",
    }
    if not cluster:
        ctx["skipped"] = "no authenticated cluster (Workflow parameter cluster is empty)"
        return ctx
    if claimed and claimed != cluster:
        ctx["skipped"] = "event names cluster %s but arrived on the endpoint of cluster %s" % (claimed, cluster)
        return ctx
    if not severe_enough(ctx["priority"], env("MINIMUM_PRIORITY", "critical")):
        ctx["skipped"] = "priority below %s" % env("MINIMUM_PRIORITY", "critical")
        return ctx
    if not ns.startswith("dp-"):
        ctx["skipped"] = "not an OpenChoreo app namespace"
        return ctx
    org = env("ORG_NAMESPACE", "default")
    rrs = kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/renderedreleases" % org).get("items") or []
    rr, res = match_workload(rrs, ns, pod)
    if rr and res:
        owner = rr["spec"].get("owner") or {}
        ctx.update(namespace=org, project=owner.get("projectName", ""), component=owner.get("componentName", ""),
                   environment=rr["spec"].get("environmentName", ""), workload="%s/%s" % (res["kind"], res["name"]))
        try:
            envobj = kube("GET", "/apis/openchoreo.dev/v1alpha1/namespaces/%s/environments/%s" % (org, ctx["environment"]))
            ctx["dataPlane"] = ((envobj.get("spec") or {}).get("dataPlaneRef") or {}).get("name", "")
        except urllib.error.HTTPError:
            pass
        # ClusterDataPlane name == cluster name (docs/conventions.md invariant 1)
        if ctx["dataPlane"] and ctx["dataPlane"] != cluster:
            ctx["skipped"] = "namespace %s runs on data plane %s, but the event came from cluster %s" % (
                ns, ctx["dataPlane"], cluster)
    return ctx


def record(ctx):
    if not ctx.get("component"):
        print("no component resolved: no Event recorded")
        return
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")   # MicroTime
    name = ("falco-%s" % ctx["uuid"])[:253] if ctx.get("uuid") else "falco-%d" % int(dt.datetime.now().timestamp())
    body = {
        "apiVersion": "events.k8s.io/v1", "kind": "Event",
        "metadata": {"name": name, "namespace": ctx["namespace"]},
        "eventTime": now,
        "reportingController": "platform.koorikla.io/falco-response", "reportingInstance": env("WORKFLOW_NAME", "falco-response"),
        "action": "Escalated", "reason": "FalcoCritical", "type": "Warning",
        "regarding": {"apiVersion": "openchoreo.dev/v1alpha1", "kind": "Component", "namespace": ctx["namespace"],
                      "name": ctx["component"]},
        "note": ("%s (%s) cluster=%s env=%s pod=%s/%s: %s" % (
            ctx["rule"], ctx["priority"], ctx.get("cluster", ""), ctx["environment"], ctx["dataPlaneNamespace"],
            ctx["pod"], ctx["output"]))[:1024],
    }
    try:
        kube("POST", "/apis/events.k8s.io/v1/namespaces/%s/events" % ctx["namespace"], body)
        print("recorded Event %s/%s on Component %s" % (ctx["namespace"], name, ctx["component"]))
    except urllib.error.HTTPError as e:
        if e.code != 409:   # 409: already recorded (same uuid) - idempotent
            raise


def rca(ctx):
    if not ctx.get("component"):
        print("no component resolved: RCA skipped")
        return
    body = {
        "namespace": ctx["namespace"], "project": ctx["project"], "component": ctx["component"],
        "environment": ctx["environment"],
        "alert": {"id": "falco-%s" % ctx["uuid"], "value": 1, "timestamp": ctx["time"],
                  "rule": {"name": ctx["rule"], "description": ctx["output"][:500], "severity": "critical"}},
        "meta": {"source": "falco", "cluster": ctx.get("cluster", ""),
                 "pod": ctx["pod"], "dataPlaneNamespace": ctx["dataPlaneNamespace"],
                 "dataPlane": ctx["dataPlane"], "tags": ctx["tags"], "process": ctx["process"]},
    }
    status, text = post(env("RCA_URL"), body)
    print("RCA agent: HTTP %d %s" % (status, text))


def notify(ctx):
    headers = {"Authorization": "Bearer " + env("NOTIFY_TOKEN")} if env("NOTIFY_TOKEN") else {}
    status, _ = post(env("NOTIFY_URL"), {"source": "falco", **ctx}, headers)
    print("notification: HTTP %d" % status)


def main():
    step = sys.argv[1]
    if step == "enrich":
        print(json.dumps(enrich(json.loads(env("EVENT") or "{}"), env("CLUSTER"))))
        return
    ctx = json.loads(env("CONTEXT") or "{}")
    if ctx.get("skipped"):
        print("skipped: %s" % ctx["skipped"])
        return
    {"record": record, "rca": rca, "notify": notify}[step](ctx)


if __name__ == "__main__":
    main()
