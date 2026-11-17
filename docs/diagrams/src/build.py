#!/usr/bin/env python3
"""Generate docs/diagrams/*.svg.

Usage: python3 docs/diagrams/src/build.py [--check] [--out DIR] [--png DIR] [name ...]

Prints the issues found by svglib.Diagram.check() (overlaps, text overflow, arrows through text or boxes, more than
12 boxes, type floor, contrast, step numbers vs key, required components, animation and reduced-motion rules, size)
and the steps that differ from docs/diagrams/README.md. Exits non-zero when there is any.
  --check     write nothing; also fail when a committed SVG differs from what this script generates
  --out DIR   write the SVGs to DIR instead of docs/diagrams/
  --png DIR   also render every SVG with rsvg-convert (the static frame) for visual review
  --readme F  compare the step lists with F instead of docs/diagrams/README.md

Status must match main: built = on main and on by default (or selected by the fleet file, like Cilium), opt-in = on
main but off by default (catalog `default: false` or a values switch), planned = not on main (open PR or roadmap).
Source of truth: charts/platform/values.yaml `addons`, the addon values, README "Status".
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from svglib import Diagram  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
README = os.path.join(OUT, "README.md")


# ------------------------------------------------------------------------------------------ layout helpers
# Content spans x 28..932 (the text margin); zones start at 28, boxes inside a zone 16 px in (44..916).
CW4 = 158                                     # 4 columns of 158 px with 80 px gutters (room for a step badge)
COLS4 = [44 + i * (CW4 + 80) for i in range(4)]
H = 80                                        # standard box height (title + 2 lines)
PITCH = H + 80                                # row pitch: 80 px between rows


def ymid(y, h=H):
    return y + h / 2


# ------------------------------------------------------------------------------------------ architecture
def architecture() -> Diagram:
    d = Diagram("koorikla/platform · architecture",
                "Argo CD reads everything from Git; the management cluster turns it into clusters, addons and app "
                "releases, and the workload clusters run the apps.")
    c, w = COLS4, CW4
    Z1, R1 = 200, 264
    R2 = R1 + H + 80
    Z1b = R2 + H + 24
    Z2 = Z1b + 64
    CH = Z1b + 22                               # channel between the clusters: badges 4, 5, 6
    R3 = Z2 + 48
    d.box(c[0], 108, w, 52, "external", "Git", ["platform + app repos"])
    d.zone(28, Z1, 904, Z1b - Z1, "management cluster", "mgmt", label_at="tr")
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps engine"])
    d.box(c[3], R1, w, H, "mgmt", "Shared services", ["image registry,", "secrets, sign-in"], context=True)
    d.box(c[0], R2, w, H, "mgmt", "Cluster API", ["creates", "clusters"])
    d.box(c[2], R2, c[3] + w - c[2], H, "mgmt", "OpenChoreo", ["developer platform: builds, releases, telemetry"])
    d.zone(28, Z2, 904, R3 + H + 24 - Z2, "workload clusters", "workload", label_at="tr")
    d.box(c[0], R3, w, H, "workload", "k3s nodes", ["servers and", "workers"])
    d.box(c[1], R3, w, H, "workload", "Addons", ["network, mesh,", "Kyverno policy"])
    d.box(c[2], R3, w, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"], aka=("agent",))
    d.box(c[3], R3, w, H, "workload", "Apps", ["your teams'", "services"], step=8)
    xa = c[0] + w / 2
    d.arrow([(xa, R1), (xa, 160)], step=1, badge=(xa, R1 - 32))
    d.arrow([(xa, R1 + H), (xa, R2)], step=2)
    xo = c[2] + 40
    d.arrow([(c[0] + w, R1 + 24), (xo, R1 + 24), (xo, R2)], step=3, badge=(xo, R1 + H + 40))
    d.arrow([(xa, R2 + H), (xa, R3)], step=4, badge=(xa, CH))
    x5 = c[1] + w / 2
    d.arrow([(c[0] + w, R1 + 56), (x5, R1 + 56), (x5, R3)], step=5, badge=(x5, CH))
    x6 = c[2] + w / 2 + 40
    d.arrow([(x6, R3), (x6, R2 + H)], step=6, badge=(x6, CH), label="dials out", label_pos=(x6 + 20, CH + 5),
            label_anchor="start")
    d.arrow([(c[2] + w, ymid(R3)), (c[3], ymid(R3))], step=7, badge_at=0.4)
    d.require("Git", "Argo CD", "Cluster API", "OpenChoreo", "cluster-agent", "Apps", "Addons", "Shared services")
    d.key("Argo CD reads Git: fleet files, the addon catalog, teams and app repos",
          "Argo CD turns each fleet file into a cluster for Cluster API to build",
          "Argo CD hands each app's release to OpenChoreo",
          "Cluster API creates the cluster's k3s nodes on docker, AWS or Hetzner",
          "Argo CD installs the addons on every cluster whose labels match",
          "The cluster-agent dials out to OpenChoreo and pulls the app releases",
          "The agent deploys the apps",
          "Apps start only after Kyverno, one of the addons, admits them: signed images, safe settings")
    return d


# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    d = Diagram("Security · from build to runtime",
                "A signed supply chain, admission that verifies it, and runtime detection with an automatic "
                "response. Identity, secrets and keys underneath: see the trust view.")
    X = [204, 476, 748]
    BW = 168
    Y = [120, 280, 440]
    for y, label, sub in ((Y[0], "supply chain", ["every image", "is signed"]),
                          (Y[1], "admission", ["only verified", "images start"]),
                          (Y[2], "runtime", ["detect and", "respond"])):
        d.lane(28, y + 22, label, sub)
    d.box(X[0], Y[0], BW, H, "mgmt", "Build", ["builds and", "scans images"])
    d.box(X[1], Y[0], BW, H, "mgmt", "cosign", ["signing", "tool"])
    d.box(X[2], Y[0], BW, H, "mgmt", "Registry", ["stores images", "and signatures"])
    d.box(X[0], Y[1], BW, H, "workload", "Kyverno", ["admission", "policy"])
    d.box(X[1], Y[1], BW, H, "workload", "App pods", ["your", "services"])
    d.box(X[0], Y[2], BW, H, "workload", "Falco", ["runtime", "detection"])
    d.box(X[1], Y[2], BW, H, "workload", "Falco Talon", ["automatic", "response"])
    d.box(X[2], Y[2], BW, H, "mgmt", "Response workflow", ["escalation on the", "management cluster"])
    xk = X[0] + BW / 2
    xr = X[2] + BW / 2
    d.arrow([(X[0] + BW, ymid(Y[0])), (X[1], ymid(Y[0]))], step=1, badge_at=0.4)
    d.arrow([(X[1] + BW, ymid(Y[0])), (X[2], ymid(Y[0]))], step=2, badge_at=0.4)
    c0 = Y[0] + H + 40
    d.arrow([(xk, Y[1]), (xk, c0), (xr, c0), (xr, Y[0] + H)], step=3)
    d.arrow([(X[0] + BW, ymid(Y[1])), (X[1], ymid(Y[1]))], step=4, badge_at=0.4)
    c1 = Y[1] + H + 40
    d.arrow([(xk, Y[2]), (xk, c1), (X[1] + 64, c1), (X[1] + 64, Y[1] + H)], step=5)
    d.arrow([(X[0] + BW, ymid(Y[2])), (X[1], ymid(Y[2]))], step=6, badge_at=0.4)
    c2 = Y[2] + H + 40
    d.arrow([(xk, Y[2] + H), (xk, c2), (xr, c2), (xr, Y[2] + H)], step=7)
    d.require("Kyverno", "cosign", "Registry", "Falco", "Falco Talon", "Response workflow", "App pods", "Build")
    d.key("The build scans the image for known vulnerabilities, records what is inside it and hands it to cosign",
          "cosign signs the image and its build record and stores both next to it in the registry",
          "Kyverno fetches the signature from the registry before any pod starts",
          "Kyverno admits only signed images with safe pod settings: it blocks in production and warns in dev and "
          "staging",
          "Falco watches what every pod does at runtime, on every node",
          "Falco alerts Falco Talon, which stops or labels the offending pod",
          "Falco escalates critical alerts to the response workflow on the management cluster")
    return d


# ----------------------------------------------------------------------------------------------- network
def network() -> Diagram:
    d = Diagram("Network · a request in, the agents out",
                "A request comes in through kgateway and the mesh; separately, the agent and the collectors dial out "
                "to the management cluster. Kyverno adds every app to the mesh before traffic arrives.")
    ZX = 204
    X = [228, 484, 740]
    BW = 176
    Z = 112
    RA = 180
    RB = RA + H + 72
    HB = 64
    DIV = RB + HB + 32
    RC = DIV + 56
    Zb = RC + H + 24
    Z2 = Zb + 64
    RD = Z2 + 48
    gap = (Zb + Z2) / 2
    d.box(28, RA, 112, H, "external", "Client", ["opens the", "app URL"])
    d.zone(ZX, Z, 932 - ZX, Zb - Z, "workload cluster", "workload")
    d.zone(ZX, Z2, 932 - ZX, RD + H + 24 - Z2, "management cluster", "mgmt", label_at="tr")
    d.lane(X[0] + 200, Z + 24, "a request in", color="#cbd5e1")
    d.divider(ZX + 16, 916, DIV)
    d.lane(X[0], DIV + 32, "the agents out", color="#cbd5e1")
    d.box(X[0], RA, BW, H, "workload", "kgateway", ["front door", "of the cluster"])
    d.box(X[1], RA, BW, H, "workload", "Service mesh", ["Istio ambient:", "encrypted hops"])
    d.box(X[2], RA, BW, H, "workload", "App pods", ["your", "services"])
    d.box(X[0], RB, X[2] + BW - X[0], HB, "workload", "Cluster network (Cilium or flannel)",
          ["chosen per cluster when it is created"], aka=("cluster network",))
    d.box(X[0], RC, BW, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"])
    d.box(X[1], RC, BW, H, "workload", "Collectors", ["logs, metrics,", "traces"])
    d.box(X[0], RD, BW, H, "mgmt", "cluster-gateway", ["entry point", "for agents"])
    d.box(X[1], RD, BW, H, "mgmt", "Observability plane", ["stores all", "telemetry"])
    d.arrow([(140, ymid(RA)), (X[0], ymid(RA))], step=1, badge=(176, ymid(RA)))
    d.arrow([(X[0] + BW, ymid(RA)), (X[1], ymid(RA))], step=2, badge_at=0.4)
    d.arrow([(X[1] + BW, ymid(RA)), (X[2], ymid(RA))], step=3, badge_at=0.4)
    xm = X[1] + BW / 2
    d.arrow([(xm, RA + H), (xm, RB)], step=4, badge_at=0.42)
    xa = X[0] + BW / 2
    d.arrow([(xa, RC + H), (xa, RD)], step=5, badge=(xa, gap), label="dials out", label_pos=(xa + 20, gap + 5),
            label_anchor="start")
    d.arrow([(xm, RC + H), (xm, RD)], step=6, badge=(xm, gap), label="dials out", label_pos=(xm + 20, gap + 5),
            label_anchor="start")
    d.require("kgateway", "Service mesh", "Cluster network (Cilium or flannel)", "cluster-gateway", "cluster-agent",
              "Collectors", "App pods")
    d.key("A client opens the app URL; kgateway takes the request",
          "kgateway routes it into the service mesh",
          "The service mesh delivers it to the app pods and encrypts every hop between pods",
          "The service mesh rides the cluster network: Cilium or flannel, chosen per cluster",
          "Separately, the cluster-agent dials out to the management cluster; cluster-gateway accepts only that "
          "cluster's certificate",
          "The collectors dial out too and ship logs, metrics and traces to the observability plane")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · one place to query every signal",
                "Collectors on every workload cluster ship to OpenChoreo's observability plane on the management "
                "cluster; Backstage, the promotion gate and the AI agents query it through one API.",
                reading="columns")
    K, KW = 44, 192
    T, TW = 364, 120
    O, OW = 568, 120
    U, UW = 784, 132
    R = [200, 336, 472]
    m = [ymid(y) for y in R]
    zb = R[2] + H + 24
    d.zone(28, 128, 224, zb - 128, "workload cluster", "workload")
    d.zone(348, 128, 584, zb - 128, "management cluster", "mgmt")
    d.lane(T, R[0] - 20, "observability plane", color="#cbd5e1")
    d.lane(U, R[0] - 20, "consumers", color="#cbd5e1")
    d.box(K, R[0], KW, H, "workload", "Fluent Bit", ["log", "collector"])
    d.box(K, R[1], KW, H, "workload", "OpenTelemetry", ["trace and event", "collector"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["metrics", "collector"])
    d.box(T, R[0], TW, R[1] + H - R[0], "mgmt", "OpenSearch", ["logs, traces", "and events"])
    d.box(T, R[2], TW, H, "mgmt", "Prometheus", ["metrics"])
    d.box(O, R[1], OW, H, "mgmt", "Observer API", ["one query API,", "one login"])
    d.box(U, R[0], UW, H, "mgmt", "Backstage", ["developer", "portal"])
    d.box(U, R[1], UW, H, "mgmt", "Promotion gate", ["release", "checks"])
    d.box(U, R[2], UW, H, "mgmt", "AI agents", ["root cause,", "cost reports"], status="optin")
    xb = 300                                   # badge column between the zones
    d.arrow([(K + KW, m[0]), (T, m[0])], step=1, badge=(xb, m[0]))
    xj = 324                                   # step 2 forks after its badge: traces and events up, metrics down
    d.arrow([(K + KW, m[1]), (xj, m[1])], step=2, head=False, badge=(xb - 4, m[1]))
    d.arrow([(xj, m[1]), (T, m[1])], step=2, badge=False)
    d.arrow([(xj, m[1]), (xj, R[2] + 24), (T, R[2] + 24)], step=2, badge=False)
    d.junction(xj, m[1])
    d.arrow([(K + KW, R[2] + 56), (T, R[2] + 56)], step=3, badge=(xb, R[2] + 56))
    xi = T + TW + 24                           # step 4 forks after its badge: the observer API queries both stores
    d.arrow([(O, m[1]), (xi, m[1])], step=4, head=False, badge=(O - 30, m[1]))
    d.arrow([(xi, m[1]), (T + TW, m[1])], step=4, badge=False)
    d.arrow([(xi, m[1]), (xi, m[2]), (T + TW, m[2])], step=4, badge=False)
    d.junction(xi, m[1])
    xo = O + OW + 56                           # step 5 joins before its badge: three consumers query the API
    d.arrow([(U, m[1]), (O + OW, m[1])], step=5, badge=(O + OW + 38, m[1]))
    d.arrow([(U, m[0]), (xo, m[0]), (xo, m[1])], step=5, badge=False, head=False)
    d.arrow([(U, m[2]), (xo, m[2]), (xo, m[1])], step=5, badge=False, head=False)
    d.junction(xo, m[1])
    d.require("OpenTelemetry", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "Observer API",
              "Backstage", "Promotion gate", "AI agents")
    d.key("Fluent Bit ships container logs, security alerts included, to OpenSearch",
          "The OpenTelemetry collector sends app traces and cluster events to OpenSearch and app metrics to "
          "Prometheus",
          "The Prometheus agent collects container and cluster metrics and sends them to Prometheus",
          "The observer API queries both stores; one login covers all of them",
          "Backstage, the promotion gate and the opt-in AI agents query the observer API")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image, promoted through environments by pull requests; production is gated twice, "
                "at promotion and at admission.")
    c, w = COLS4, CW4
    R0 = 120
    R1 = R0 + PITCH
    ch = R1 + H + 56
    R2 = ch + 48
    d.box(c[0], R0, w, H, "external", "App repo", ["your code and", "deploy/ folder"])
    d.box(c[1], R0, c[2] + w - c[1], H, "mgmt", "Build & sign",
          ["OpenChoreo workflow plane (or GitHub Actions)", "scan, inventory, signature"])
    d.box(c[3], R0, w, H, "mgmt", "Registry", ["signed", "images"])
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(c[1], R1, w, H, "mgmt", "Release", ["immutable", "snapshot"])
    d.box(c[2], R1, w, H, "workload", "Development", ["first", "environment"])
    d.box(c[3], R1, w, H, "mgmt", "Promotion gate", ["health checks,", "pull requests"])
    d.box(c[1], R2, w, H, "workload", "Staging", ["second", "environment"])
    d.box(c[2], R2, w, H, "workload", "Production", ["admission", "checked"], step=8)
    d.arrow([(c[0] + w, ymid(R0)), (c[1], ymid(R0))], step=1, badge_at=0.4)
    d.arrow([(c[2] + w, ymid(R0)), (c[3], ymid(R0))], step=2, badge_at=0.4)
    xa = c[0] + w / 2
    d.arrow([(xa, R1), (xa, R0 + H)], step=3)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=4, badge_at=0.4)
    d.arrow([(c[1] + w, ymid(R1)), (c[2], ymid(R1))], step=5, badge_at=0.4)
    d.arrow([(c[3], ymid(R1)), (c[2] + w, ymid(R1))], step=6, badge_at=0.4)
    xg = c[3] + w / 2                         # step 7 forks after its badge: staging and production pull requests
    d.arrow([(xg, R1 + H), (xg, ch)], step=7, head=False, badge=(xg, R1 + H + 30))
    d.arrow([(xg, ch), (c[1] + w / 2, ch), (c[1] + w / 2, R2)], step=7, badge=False)
    d.arrow([(c[2] + w / 2, ch), (c[2] + w / 2, R2)], step=7, badge=False)
    d.junction(xg, ch)
    d.junction(c[2] + w / 2, ch)
    d.require("App repo", "Build & sign", "Registry", "Argo CD", "Release", "Promotion gate", "Development",
              "Staging", "Production")
    d.key("A push to the app repo starts a build on the OpenChoreo workflow plane, or GitHub Actions",
          "Build & sign scans and signs the image, pushes it to the registry and commits the new version to deploy/",
          "Argo CD reads the deploy/ folder of the app repo",
          "Argo CD applies it to OpenChoreo, which snapshots an immutable release",
          "The release deploys to development automatically",
          "The promotion gate checks development: readiness, smoke tests, alerts, change freezes",
          "The promotion gate opens the pull requests that promote the release: staging first, production only "
          "with code-owner approval",
          "Production admits only signed images pinned by digest: Kyverno blocks the rest")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    d = Diagram("Cluster lifecycle · add, upgrade, remove = edit one file",
                "A fleet file becomes a Cluster API cluster, an Argo CD cluster secret and an OpenChoreo data plane; "
                "deleting it removes all three.")
    AX, AW = 44, 144
    A, B, CW = 288, 500, 132
    ZR = 648
    WZ = ZR + 96
    WX, WW = WZ + 16, 932 - 16 - WZ - 16
    L = [264, 264 + H + 72, 264 + 2 * (H + 72), 264 + 3 * (H + 72)]
    m = [ymid(y) for y in L]
    ZB = L[3] + H + 24
    d.box(AX, 100, 240, 56, "external", "Fleet file", ["`clusters/dev1.yaml`"])
    d.zone(28, 200, ZR - 28, ZB - 200, "management cluster", "mgmt", label_at="tr")
    d.zone(WZ, 200, 932 - WZ, ZB - 200, "new cluster", "workload", label_at="tr")
    d.box(AX, L[0], AW, L[3] + H - L[0], "mgmt", "Argo CD",
          ["renders one chart", "per fleet file:", "", "the cluster,", "its secrets,", "its identity,", "its data plane"])
    d.box(A, L[0], CW, H, "mgmt", "Cluster API", ["creates and", "upgrades nodes"])
    d.box(WX, L[0], WW, H, "workload", "k3s nodes", ["servers +", "workers"])
    d.box(A, L[1], CW, H, "mgmt", "Cluster secret", ["access + labels", "for Argo CD"])
    d.box(B, L[1], CW, H, "mgmt", "Addon sets", ["pick clusters", "by label"])
    d.box(WX, L[1], WW, H, "workload", "Addons", ["network, mesh,", "policy, …"])
    d.box(A, L[2], CW, H, "mgmt", "Agent identity", ["a CA of its own", "per cluster"])
    d.box(WX, L[2], WW, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"])
    d.box(B, L[3], CW, H, "mgmt", "Data plane", ["OpenChoreo's", "record"])
    xf = AX + AW / 2
    xz = (ZR + WZ) / 2                          # badge column between the zones
    d.arrow([(xf, 156), (xf, L[0])], step=1, badge=(xf, L[0] - 42))
    xj = A - 40                                 # step 2 forks after its badge: Argo CD renders all four
    d.arrow([(AX + AW, m[0]), (xj, m[0])], step=2, head=False, badge=(AX + AW + 30, m[0]))
    d.arrow([(xj, m[0]), (A, m[0])], step=2, badge=False)
    d.arrow([(xj, m[0]), (xj, m[1]), (A, m[1])], step=2, badge=False)
    d.arrow([(xj, m[1]), (xj, m[2]), (A, m[2])], step=2, badge=False)
    d.arrow([(xj, m[2]), (xj, m[3]), (B, m[3])], step=2, badge=False)
    for y in m[:3]:
        d.junction(xj, y)
    d.arrow([(A + CW, m[0]), (WX, m[0])], step=3, badge=(xz, m[0]))
    d.arrow([(A + CW / 2, L[0] + H), (A + CW / 2, L[1])], step=4, badge_at=0.42)
    d.arrow([(A + CW, m[1]), (B, m[1])], step=5, badge_at=0.4)
    d.arrow([(B + CW, m[1]), (WX, m[1])], step=6, badge=(xz, m[1]))
    d.arrow([(A + CW, m[2]), (WX, m[2])], step=7, badge=(xz, m[2]))
    xg = WX + WW / 2
    d.arrow([(xg, L[2] + H), (xg, m[3]), (B + CW, m[3])], step=8, badge=(xz, m[3]), label="dials out",
            label_pos=(xz, m[3] + 32))
    d.require("Fleet file", "Argo CD", "Cluster API", "k3s nodes", "Cluster secret", "Addon sets", "Addons",
              "Agent identity", "Data plane", "cluster-agent")
    d.key("The fleet file clusters/<name>.yaml is synced by Argo CD (ApplicationSet fleet → Application "
          "cluster-<name>)",
          "Argo CD renders charts/cluster: the Cluster API cluster, its secrets, the agent identity and the "
          "OpenChoreo data plane",
          "Cluster API creates the machines and installs k3s",
          "Cluster API's kubeconfig becomes an Argo CD cluster secret with the fleet labels (ESO)",
          "The cluster secret's labels select the addon sets (ApplicationSets) that apply",
          "The addon sets install every selected addon on the new cluster",
          "The agent identity (its certificate) is delivered to the cluster; the CA key never leaves the "
          "management cluster",
          "The cluster-agent dials out; the data plane tells the gateway to accept only this cluster's CA")
    d.note("Upgrade: bump kubernetesVersion in the fleet file; Cluster API replaces the nodes one at a time. "
           "Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.")
    return d


# ------------------------------------------------------------------------------------ trust & certificates
def trust() -> Diagram:
    d = Diagram("Trust & certificates · who signs what, and how it renews",
                "Two certificate chains, both rooted on the management cluster: a CA per cluster for the OpenChoreo "
                "agent, and OpenBao's mesh CA per group of clusters. No private CA key leaves the management cluster.")
    C1, W1 = 44, 220
    C2, W2 = 336, 220
    ZR = 572
    WZ = ZR + 96
    WX, WW = WZ + 16, 932 - 16 - WZ - 16
    Z = 112
    RA1 = 184
    RA2 = RA1 + H + 64
    DIV = RA2 + H + 36
    RB1 = DIV + 76
    RB2 = RB1 + H + 80
    ZB = RB2 + H + 24
    xz = (ZR + WZ) / 2
    d.zone(28, Z, ZR - 28, ZB - Z, "management cluster", "mgmt")
    d.zone(WZ, Z, 932 - WZ, ZB - Z, "workload cluster", "workload")
    d.divider(44, 916, DIV)
    d.lane(44, Z + 52, "agent identity", color="#cbd5e1")
    d.lane(44, DIV + 34, "service mesh CA", color="#cbd5e1")
    d.box(C1, RA1, W1, H, "mgmt", "cert-manager", ["one CA", "per cluster"], step=1)
    d.box(C2, RA2, W2, H, "mgmt", "cluster-gateway", ["entry point", "for agents"])
    d.box(WX, RA1, WW, H, "workload", "cluster-agent", ["OpenChoreo's agent", "on the cluster"])
    d.box(C1, RB1, C2 + W2 - C1, H, "mgmt", "OpenBao", ["mesh certificate authority,", "one per group of clusters"],
          status="optin", step=5)
    d.box(WX, RB1, WW, H, "workload", "istio-csr", ["requests mesh", "certificates"], status="optin")
    d.box(WX, RB2, WW, H, "workload", "Mesh proxies", ["ztunnel and", "gateways"])
    d.arrow([(C1 + W1, ymid(RA1)), (WX, ymid(RA1))], step=2, badge=(xz, ymid(RA1)))
    xc = C1 + W1 / 2
    d.arrow([(xc, RA1 + H), (xc, ymid(RA2)), (C2, ymid(RA2))], step=3)
    xa = WX + WW / 2
    d.arrow([(xa, RA1 + H), (xa, ymid(RA2)), (C2 + W2, ymid(RA2))], step=4, badge=(xz, ymid(RA2)),
            label="dials out", label_pos=(xz, ymid(RA2) + 32))
    d.arrow([(WX, ymid(RB1)), (C2 + W2, ymid(RB1))], step=6, badge=(xz, ymid(RB1)), label="dials out",
            label_pos=(xz, ymid(RB1) + 32))
    d.arrow([(xa, RB2), (xa, RB1 + H)], step=7)
    d.require("cert-manager", "cluster-agent", "cluster-gateway", "OpenBao", "istio-csr", "Mesh proxies")
    d.key("cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it a month "
          "before it expires",
          "cert-manager delivers the certificate to the cluster; the CA's private key stays on the management cluster",
          "cert-manager gives cluster-gateway that cluster's CA, the only one it accepts for that cluster",
          "The cluster-agent dials out with its certificate and restarts by itself when the certificate renews",
          "OpenBao (opt-in) creates a root and an intermediate CA for each group of clusters; the keys never leave it",
          "istio-csr (opt-in) dials out to OpenBao, logs in with its service account and gets mesh certificates signed",
          "The mesh proxies get short-lived certificates from istio-csr: 24 hours, renewed at half-life")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · the restore order",
                "Git rebuilds everything declarative; the violet boxes hold state it cannot recreate. The numbers "
                "are the restore order after losing the management cluster.")
    M1, M2, MW = 44, 348, 224
    ZR = 588
    OZ = ZR + 96
    OX, OW = OZ + 16, 932 - 16 - OZ - 16
    R = [176, 312, 448, 656]
    zb = R[2] + H + 24
    d.zone(28, 128, ZR - 28, zb - 128, "management cluster", "mgmt")
    d.zone(28, zb + 40, ZR - 28, R[3] + H + 24 - zb - 40, "workload cluster", "workload")
    d.zone(OZ, 128, 932 - OZ, R[3] + H + 24 - 128, "outside", "external")
    d.box(M1, R[0], M2 + MW - M1, H, "data", "Cluster state (etcd)",
          ["clusters, access and CA keys:", "a snapshot every 12 hours"], step=1, aka=("etcd",))
    d.box(OX, R[0], OW, H, "external", "Secret backend", ["AWS or Vault", "secret store"], step=2)
    d.box(M1, R[1], MW, H, "data", "Thunder", ["users and", "sign-in clients"], step=3)
    d.box(M2, R[1], MW, H, "data", "OpenBao", ["cold copy", "of its data"], status="optin")
    d.box(M1, R[2], MW, H, "data", "Harbor", ["pushed", "images"], step=5)
    d.box(M2, R[2], MW, H, "mgmt", "Argo CD", ["re-applies", "everything else"])
    d.box(OX, R[2], OW, H, "external", "Git", ["everything", "declarative"])
    d.box(M2, R[3], MW, H, "data", "Databases", ["continuous", "backups"], status="optin")
    d.box(OX, R[3], OW, H, "external", "Object storage", ["database", "backups"])
    xz = (ZR + OZ) / 2
    xs = OX + OW / 2
    d.arrow([(M2 + MW, ymid(R[1])), (xs, ymid(R[1])), (xs, R[0] + H)], step=4, badge=(xz, ymid(R[1])))
    d.arrow([(M2 + MW, ymid(R[2])), (OX, ymid(R[2]))], step=6, badge=(xz, ymid(R[2])))
    d.arrow([(M2 + MW, ymid(R[3])), (OX, ymid(R[3]))], step=7, badge=(xz, ymid(R[3])))
    d.legend_label("data", "holds state: restore it")
    d.legend_label("mgmt", "management cluster: rebuilt from Git")
    d.legend_label("external", "outside: where backups live")
    d.require("Git", "Secret backend", "Cluster state (etcd)", "OpenBao", "Thunder", "Harbor", "Databases")
    d.key("Restore the management cluster's etcd from its latest snapshot: Cluster API keeps its clusters and the "
          "CA keys come back",
          "The secret backend lives outside the clusters; on a laptop, re-seed it with task secrets",
          "Restore Thunder's volumes: users, sign-in clients, signing keys",
          "OpenBao (opt-in) restores a cold copy of its data and fetches its unseal key from the secret backend",
          "Harbor's images come back from its volumes or from new builds; telemetry starts empty",
          "Argo CD re-syncs everything else from Git",
          "The databases (opt-in) restore themselves from object storage if a workload cluster is lost too")
    return d


# -------------------------------------------------------------------------------------------- upgrade flow
def upgrade() -> Diagram:
    d = Diagram("Upgrade flow · every upgrade is a pull request",
                "Renovate proposes, CI proves, Argo CD rolls out dev before prod; Kubernetes versions roll through "
                "Cluster API.")
    c, w = COLS4, CW4
    R0 = 120
    R1 = R0 + H + 96
    y0 = R0 + H + 48
    y1 = R1 + H + 36
    y2 = R1 + H + 80
    d.box(c[0], R0, w, H, "external", "Renovate", ["proposes", "version bumps"])
    d.box(c[1], R0, w, H, "external", "Pull request", ["one bump", "per PR"])
    d.box(c[2], R0, w, H, "external", "CI", ["renders and", "tests everything"])
    d.box(c[3], R0, w, H, "external", "Main branch", ["reviewed,", "merged"], aka=("main",))
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(c[1], R1, w, H, "workload", "Dev clusters", ["follow main", "first"], step=6)
    d.box(c[2], R1, w, H, "workload", "Prod clusters", ["follow a", "verified commit"])
    d.box(c[3], R1, w, H, "mgmt", "Cluster API", ["replaces servers", "one at a time"])
    for i in range(3):
        d.arrow([(c[i] + w, ymid(R0)), (c[i + 1], ymid(R0))], step=i + 1, badge_at=0.4)
    d.arrow([(c[0] + w / 2, R1), (c[0] + w / 2, y0), (c[3] + w / 2, y0), (c[3] + w / 2, R0 + H)], step=4)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=5, badge_at=0.4)
    d.arrow([(c[0] + 100, R1 + H), (c[0] + 100, y1), (c[2] + w / 2, y1), (c[2] + w / 2, R1 + H)], step=7)
    d.arrow([(c[0] + 40, R1 + H), (c[0] + 40, y2), (c[3] + w / 2, y2), (c[3] + w / 2, R1 + H)], step=8,
            badge=(c[3] - 40, y2))
    d.require("Renovate", "Pull request", "CI", "Main branch", "Argo CD", "Dev clusters", "Prod clusters",
              "Cluster API")
    d.key("Renovate opens a pull request: a Helm chart, a k3s release, an image or a tool version",
          "The pull request runs CI: every chart rendered and tested on Linux, macOS and Windows, x86 and arm",
          "CI gates the merge: once it passes and a maintainer approves, the pull request is merged into main",
          "Argo CD reads main for every cluster that follows it",
          "Argo CD syncs the dev clusters first, each app in a fixed order",
          "Dev clusters are verified: every app synced and healthy",
          "Argo CD syncs the prod clusters only after a second pull request moves them to the verified commit",
          "Argo CD hands a Kubernetes version bump to Cluster API, which replaces servers one at a time, dev "
          "before prod")
    return d


DIAGRAMS = {
    "architecture": architecture,
    "security": security,
    "network": network,
    "observability": observability,
    "sdlc": sdlc,
    "cluster-lifecycle": cluster_lifecycle,
    "trust": trust,
    "backup": backup,
    "upgrade": upgrade,
}


# ------------------------------------------------------------------------------------------ docs steps
def readme_steps(text: str) -> dict[str, list[str]]:
    """Numbered lists under headings that link `<name>.svg` in docs/diagrams/README.md (backticks ignored)."""
    out: dict[str, list[str]] = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"#{2,4} .*\(([\w-]+)\.svg\)", line)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        if line.startswith("#"):
            cur = None
            continue
        m = re.match(r"(\d+)\. (.*)", line)
        if cur and m:
            out[cur].append(m.group(2).replace("`", "").strip())
    return out


def main(argv):
    def opt(flag):
        nonlocal argv
        if flag in argv:
            i = argv.index(flag)
            v = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]
            return v
        return None

    check_only = "--check" in argv
    argv = [a for a in argv if a != "--check"]
    png_dir = opt("--png")
    out_dir = opt("--out") or OUT
    readme = opt("--readme") or README
    names = argv or list(DIAGRAMS)
    docs = {}
    if os.path.exists(readme):
        with open(readme, encoding="utf-8") as f:
            docs = readme_steps(f.read())
    bad = 0
    for n in names:
        d = DIAGRAMS[n]()
        svg = d.svg()
        issues = d.check()
        want = [d.steps[i] for i in sorted(d.steps)]
        if docs.get(n) != want:
            issues.append(f"steps differ from docs/diagrams/README.md (section linking {n}.svg): "
                          f"docs={docs.get(n)} svg={want}")
        path = os.path.join(out_dir, f"{n}.svg")
        if check_only:
            try:
                with open(path, encoding="utf-8", newline="") as f:
                    cur = f.read().replace("\r\n", "\n")
            except FileNotFoundError:
                cur = None
            if cur != svg:
                issues.append(f"{n}.svg is not up to date: run python3 docs/diagrams/src/build.py")
        else:
            os.makedirs(out_dir, exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(svg)
        print(f"{n}.svg  {len(svg.encode()) / 1024:.1f} KB  {d.w}x{d.h}  boxes: {len(d.r_boxes)}  "
              f"steps: {len(d.steps)}  issues: {len(issues)}")
        for s in issues:
            print("   -", s)
        bad += len(issues)
        if png_dir and not check_only:
            os.makedirs(png_dir, exist_ok=True)
            subprocess.run(["rsvg-convert", "-w", str(d.w), "-o", os.path.join(png_dir, f"{n}.png"), path],
                           check=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
