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
    d.zone(28, Z2, 904, R3 + H + 64 - Z2, "k3s workload clusters", "workload", label_at="tr")
    d.box(c[1], R3, w, H, "workload", "Addons", ["network, mesh,", "Kyverno policy"])
    d.box(c[2], R3, w, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"], aka=("agent",))
    d.box(c[3], R3, w, H, "workload", "Apps", ["your teams'", "services"])
    xa = c[0] + w / 2
    d.arrow([(xa, R1), (xa, 160)], step=1, badge=(xa, R1 - 32))
    d.arrow([(xa, R1 + H), (xa, R2)], step=2)
    xo = c[2] + 40
    d.arrow([(c[0] + w, R1 + 24), (xo, R1 + 24), (xo, R2)], step=3, badge=(xo, R1 + H + 40))
    d.arrow([(xa, R2 + H), (xa, Z2)], step=4, badge=(xa, CH))          # creates the cluster itself: the zone
    x5 = c[1] + w / 2
    d.arrow([(c[0] + w, R1 + 56), (x5, R1 + 56), (x5, R3)], step=5, badge=(x5, CH))
    yb = Z2 + 24                                # step 5 also installs the cluster-agent
    d.arrow([(x5, yb), (c[2] + 40, yb), (c[2] + 40, R3)], step=5, badge=False)
    d.junction(x5, yb)
    x6 = c[2] + w / 2 + 40
    d.arrow([(x6, R3), (x6, R2 + H)], step=6, badge=(x6, CH), label="dials out", label_pos=(x6 + 20, CH + 5),
            label_anchor="start")
    d.arrow([(c[2] + w, ymid(R3)), (c[3], ymid(R3))], step=7, badge_at=0.4)
    yk = R3 + H + 36                            # step 8: Kyverno (an addon) admits the apps
    d.arrow([(c[1] + w / 2, R3 + H), (c[1] + w / 2, yk), (c[3] + w / 2, yk), (c[3] + w / 2, R3 + H)], step=8,
            badge=(c[3] + 24, yk))                    # disc 8 right of disc 7: admission follows the submit
    d.require("Git", "Argo CD", "Cluster API", "OpenChoreo", "cluster-agent", "Apps", "Addons", "Shared services")
    d.key("Argo CD reads Git: fleet files, the addon catalog, teams and app repos",
          "Argo CD turns each fleet file into a cluster for Cluster API to build",
          "Argo CD hands each app's release to OpenChoreo",
          "Cluster API creates each workload cluster's k3s nodes on docker, AWS or Hetzner",
          "Argo CD installs the addons and the cluster-agent on every cluster whose labels match",
          "The cluster-agent dials out to OpenChoreo and pulls the app releases",
          "The agent submits the apps to the cluster",
          "Kyverno, one of the addons, admits only apps with signed images and safe settings before they start")
    return d


# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    d = Diagram("Security · from build to runtime",
                "A signed supply chain, admission that verifies it, and runtime detection with an automatic "
                "response. Identity, secrets and keys underneath: see the trust view.")
    X = [72, 384, 696]
    BW = 192
    R0 = 120
    R1 = R0 + H + 80
    R2 = R1 + H + 80
    R3 = R2 + H + 80
    d.box(X[0], R0, BW, H, "mgmt", "Build & sign", ["scans and signs", "every image"], step=1, aka=("cosign",))
    d.box(X[1], R0, BW, H, "mgmt", "Registry", ["images and", "signatures"])
    d.box(X[2], R0, BW, H, "workload", "Admission control", ["checks signatures", "and pod settings"])
    d.box(X[0], R1, BW, H, "workload", "Detection", ["watches every pod", "at runtime"])
    d.box(X[2], R1, BW, R2 + H - R1, "workload", "App pods", ["your services"])
    d.box(X[1], R2, BW, H, "workload", "Auto-response", ["stops or labels", "offending pods"])
    d.box(X[1], R3, BW, H, "mgmt", "Incident workflow", ["finds the app,", "records the incident"])
    d.arrow([(X[0] + BW, ymid(R0)), (X[1], ymid(R0))], step=2, badge_at=0.5)
    d.arrow([(X[2], ymid(R0)), (X[1] + BW, ymid(R0))], step=3, badge_at=0.5)     # Kyverno reads the registry
    xa = X[2] + BW / 2
    d.arrow([(xa, R0 + H), (xa, R1)], step=4)
    d.arrow([(X[0] + BW, ymid(R1) - 12), (X[2], ymid(R1) - 12)], step=5, badge_at=0.5)
    x6 = X[0] + BW + 60                         # Detection's right side: every alert to Talon
    y6 = R1 + H + 50
    d.arrow([(X[0] + BW, R1 + H - 14), (x6, R1 + H - 14), (x6, ymid(R2)), (X[1], ymid(R2))], step=6,
            badge=(x6, y6), label="every alert", label_pos=(x6 - 18, y6 + 5), label_anchor="end")
    d.arrow([(X[1] + BW, ymid(R2)), (X[2], ymid(R2))], step=7, badge_at=0.5, label="on a rule match",
            label_pos=((X[1] + BW + X[2]) / 2, ymid(R2) + 32))
    x8 = X[0] + BW / 2                          # Detection's bottom: critical alerts to the management cluster
    y8 = R2 + H + 40
    d.arrow([(x8, R1 + H), (x8, ymid(R3)), (X[1], ymid(R3))], step=8, badge=(x8, y8),
            label="also: critical alerts", label_pos=(x8 + 20, y8 + 5), label_anchor="start")
    d.require("Admission control", "Build & sign", "Registry", "Detection", "Auto-response",
              "Incident workflow", "App pods")
    d.key("Build & sign scans the image for known vulnerabilities, then cosign signs it with its build record",
          "Build & sign pushes the image and its signature to the registry",
          "Admission control (Kyverno) fetches the signature from the registry before any pod starts",
          "Admission control admits only signed images with safe pod settings: it blocks in production and warns in "
          "dev and staging",
          "Detection (Falco) watches what every pod does at runtime, on every node",
          "Detection sends every alert to Auto-response (Falco Talon)",
          "Auto-response stops or labels the offending pod when an alert matches one of its rules",
          "Detection also escalates critical alerts to an incident workflow on the management cluster (Argo Events), "
          "which finds the affected app and records the incident on it")
    return d


# ----------------------------------------------------------------------------------------------- network
def network() -> Diagram:
    d = Diagram("Network · a request in, its telemetry out",
                "A request comes in through the ingress gateway to the app pods, and the service mesh encrypts the "
                "traffic between pods; their telemetry goes out to the management cluster.")
    ZX = 204
    X = [228, 472, 708]
    BW = 176
    Z = 128
    RA = Z + 72
    RC = RA + H + 128
    Zb = RC + H + 24
    Z2 = Zb + 64
    RD = Z2 + 48
    gap = (Zb + Z2) / 2
    d.box(28, RA, 112, H, "external", "Client", ["opens the", "app URL"])
    d.zone(ZX, Z, 932 - ZX, Zb - Z, "workload cluster", "workload")
    d.zone(ZX, Z2, 932 - ZX, RD + H + 24 - Z2, "management cluster", "mgmt")
    d.box(X[0], RA, BW, H, "workload", "Ingress gateway", ["front door of", "the cluster"],
          aka=("kgateway",))
    d.box(X[2], RA, BW, H, "workload", "App pods", ["your services, in", "the service mesh"], step=3)
    d.box(X[1], RC, BW, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"], context=True)
    d.box(X[2], RC, BW, H, "workload", "Collectors", ["on every node"])
    d.box(X[1], RD, BW, H, "mgmt", "cluster-gateway", ["entry point", "for agents"], context=True)
    d.box(X[2], RD, BW, H, "mgmt", "Observability plane", ["stores all", "telemetry"])
    d.arrow([(140, ymid(RA)), (X[0], ymid(RA))], step=1, badge=(176, ymid(RA)))
    d.arrow([(X[0] + BW, ymid(RA)), (X[2], ymid(RA))], step=2, badge_at=0.35)
    xl, xr = X[2] + BW / 2 - 40, X[2] + BW / 2 + 40
    yb = RA + H + 62
    d.arrow([(xl, RC), (xl, RA + H)], step=4, badge=(xl, yb), label="tails logs, scrapes metrics",
            label_pos=(xl - 18, yb + 5), label_anchor="end")       # the collectors act: they pull
    d.arrow([(xr, RA + H), (xr, RC)], step=5, badge=(xr, yb), label="traces", label_pos=(xr + 18, yb + 5),
            label_anchor="start")                                   # the pods push their traces
    xp = X[2] + BW / 2
    d.arrow([(xp, RC + H), (xp, RD)], step=6, badge=(xp, gap), label="dials out", label_pos=(xp + 20, gap + 5),
            label_anchor="start")
    xg = X[1] + BW / 2
    d.arrow([(xg, RC + H), (xg, RD)], label="control link", label_pos=(xg + 14, gap + 5), label_anchor="start")
    d.line_label = "the cluster-agent's control link, not telemetry (context)"
    d.require("Ingress gateway", "cluster-gateway", "cluster-agent", "Collectors", "App pods")
    d.key("A client opens the app URL; kgateway takes the request",
          "kgateway routes it to the app pods",
          "Inside the Istio ambient service mesh, ztunnel encrypts every hop between the app pods",
          "The collectors on each node gather the pods' logs and metrics: Fluent Bit tails their log files, the "
          "Prometheus agent scrapes their metrics",
          "The app pods send their traces to the OpenTelemetry collector",
          "The collectors dial out and ship everything to the observability plane on the management cluster")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · one place to query every signal",
                "Collectors on every workload cluster ship to OpenChoreo's observability plane on the management "
                "cluster; Backstage, the promotion gate and the AI agents query it through one API.",
                reading="columns")
    K, KW = 44, 192
    T, TW = 380, 120
    O, OW = 572, 120
    U, UW = 784, 132
    R = [216, 352, 488]
    m = [ymid(y) for y in R]
    zb = R[2] + H + 24
    d.zone(28, 128, 224, zb - 128, "workload cluster", "workload")
    d.zone(348, 128, 584, zb - 128, "management cluster", "mgmt")
    d.zone(364, 168, O + OW + 16 - 364, zb - 16 - 168, "observability plane", "mgmt")
    d.lane(U, R[0] - 20, "consumers", color="#cbd5e1")
    d.box(K, R[0], KW, H, "workload", "Fluent Bit", ["container logs,", "security alerts"])
    d.box(K, R[1], KW, H, "workload", "OpenTelemetry", ["traces, events,", "app metrics"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["container and", "cluster metrics"])
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
    d.arrow([(O, m[1]), (T + TW, m[1])])
    xi = T + TW + 36
    d.arrow([(O, m[1] + 26), (xi, m[1] + 26), (xi, m[2]), (T + TW, m[2])])
    d.line_label = "the observer API reads both stores"
    xo = U - 24                                # step 4 joins before its badge: three consumers query the API
    d.arrow([(U, m[1]), (O + OW, m[1])], step=4, badge=(O + OW + 48, m[1]))
    d.arrow([(U, m[0]), (xo, m[0]), (xo, m[1])], step=4, badge=False, head=False)
    d.arrow([(U, m[2]), (xo, m[2]), (xo, m[1])], step=4, badge=False, head=False)
    d.junction(xo, m[1])
    d.require("OpenTelemetry", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "Observer API",
              "Backstage", "Promotion gate", "AI agents")
    d.key("Fluent Bit ships container logs, security alerts included, to OpenSearch",
          "The OpenTelemetry collector sends app traces and events to OpenSearch and app metrics to Prometheus",
          "The Prometheus agent collects container and cluster metrics and sends them to Prometheus",
          "Backstage, the promotion gate and the opt-in AI agents query the observer API, which reads both stores "
          "behind one login")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image: development deploys automatically, staging and production are promoted by pull "
                "requests in the app repo. Production is gated twice, at promotion and at admission.")
    c, w = [44, 272, 500, 728], 148
    H0 = 100                                    # top row: room for three arrows between the repo and the build
    R0 = 120
    R1 = R0 + H0 + 80
    R2 = R1 + PITCH
    R3 = R2 + PITCH
    xr = c[3] + w + 28                          # right channel: Kyverno to the registry
    d.box(c[0], R0, w, H0, "external", "App repo", ["your code and", "deploy/ folder"])
    d.box(c[1], R0, c[2] + w - c[1], H0, "mgmt", "Build & sign", ["builds, scans and signs every image"])
    d.box(c[3], R0, w, H0, "mgmt", "Registry", ["signed", "images"])
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(c[1], R1, w, H, "mgmt", "OpenChoreo", ["snapshots and", "deploys releases"])
    d.box(c[2], R1, w, H, "workload", "Development", ["first", "environment"])
    d.box(c[2], R2, w, H, "workload", "Staging", ["second", "environment"])
    d.box(c[3], R2, w, H, "mgmt", "Promotion gate", ["checks staging,", "opens the PR"])
    d.box(c[2], R3, w, H, "workload", "Admission", ["checks every", "pod first"], aka=("Kyverno",))
    d.box(c[3], R3, w, H, "workload", "Production", ["runs only", "admitted pods"])
    d.arrow([(c[0] + w, R0 + 24), (c[1], R0 + 24)], step=1)
    d.arrow([(c[2] + w, R0 + H0 / 2), (c[3], R0 + H0 / 2)], step=2)
    d.arrow([(c[1], R0 + H0 - 16), (c[0] + w, R0 + H0 - 16)], step=3)       # the commit Argo CD then reads
    xa = c[0] + w / 2
    d.arrow([(xa, R1), (xa, R0 + H0)], step=4)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=5)
    d.arrow([(c[1] + w, ymid(R1)), (c[2], ymid(R1))], step=6)
    xs, xq = c[1] + 110, c[1] + 48             # the release reaches staging, and only later production
    d.arrow([(xs, R1 + H), (xs, ymid(R2)), (c[2], ymid(R2))], step=7, badge=(c[1] + w + 40, ymid(R2)),
            label="after the team's staging PR", label_pos=(xs + 12, R1 + H + 52), label_anchor="start")
    d.arrow([(c[3], ymid(R2)), (c[2] + w, ymid(R2))], step=8)
    xg, yg = c[3] + w / 2, R0 + H0 + 40         # the gate's pull request: out of its top, back to the repo
    pr = d.arrow([(xg, R2), (xg, yg), (c[0] + w - 22, yg), (c[0] + w - 22, R0 + H0)], step=9,
                 badge=(xg, R2 - 34), label="production pull request", label_pos=(xg - 20, R2 - 29),
                 label_anchor="end")
    d.label(c[0] + w - 10, yg + 24, "once merged: back through 4 and 5", anchor="start", owner=pr)
    d.arrow([(xq, R1 + H), (xq, ymid(R3)), (c[2], ymid(R3))], step=10, badge=(xq, ymid(R3) - 60),
            label="after the approved PR", label_pos=(xq + 14, ymid(R3) + 24), label_anchor="start")
    yb = R3 + H + 30                            # Kyverno checks the registry: under Production, up the right side
    d.arrow([(c[2] + w / 2, R3 + H), (c[2] + w / 2, yb), (xr, yb), (xr, R0 + H0 / 2 + 14),
             (c[3] + w, R0 + H0 / 2 + 14)], step=11, badge=(c[3] + 40, yb), label="checks the signature",
            label_pos=(c[3] + 60, yb + 5), label_anchor="start")
    d.arrow([(c[2] + w, ymid(R3)), (c[3], ymid(R3))], step=12)
    d.require("App repo", "Build & sign", "Registry", "Argo CD", "OpenChoreo", "Promotion gate", "Development",
              "Staging", "Production", "Admission")
    d.stages("Development", "Staging", "Production")
    d.key("A push to the app repo starts Build & sign on OpenChoreo's workflow plane on the management cluster",
          "Build & sign scans and signs the image and pushes it to the registry",
          "Build & sign commits the new image version to the deploy/ folder of the app repo",
          "Argo CD reads the deploy/ folder of the app repo",
          "Argo CD applies every merge to OpenChoreo, which snapshots an immutable release",
          "OpenChoreo deploys the release to development automatically",
          "OpenChoreo deploys it to staging once the team merges a staging pull request in the app repo (back "
          "through steps 4 and 5)",
          "The promotion gate checks staging: readiness, smoke tests, alerts, error rate, change freezes",
          "The promotion gate opens the production pull request in the app repo only if every check passes",
          "OpenChoreo submits the release to production, through admission, only after a code owner approves and "
          "merges that pull request",
          "Kyverno checks each production pod's image signature and digest in the registry before the pod starts",
          "Kyverno admits only verified pods into production")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    d = Diagram("Cluster lifecycle · add, upgrade, remove = edit one file",
                "One fleet file in Git becomes a running cluster with its addons and its OpenChoreo agent; deleting "
                "the file removes all of it.")
    AX, AW = 44, 160
    A, AWD = 300, 200
    ZR = 596
    WZ = ZR + 96
    WX, WW = WZ + 16, 932 - 16 - WZ - 16
    L = [264, 264 + H + 72, 264 + 2 * (H + 72), 264 + 3 * (H + 72)]
    m = [ymid(y) for y in L]
    ZB = L[3] + H + 24
    xz = (ZR + WZ) / 2
    d.box(AX, 108, 240, 52, "external", "Fleet file", ["`clusters/dev1.yaml`"])
    d.zone(28, 200, ZR - 28, ZB - 200, "management cluster", "mgmt", label_at="tr")
    d.zone(WZ, 200, 932 - WZ, ZB - 200, "new cluster", "workload", label_at="tr")
    d.box(AX, L[0], AW, L[3] + H - L[0], "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(A, L[0], AWD, H, "mgmt", "Cluster API", ["creates and", "upgrades nodes"])
    d.box(A, L[1], AWD, H, "mgmt", "cert-manager", ["one CA", "per cluster"])
    d.box(A, L[3], AWD, H, "mgmt", "OpenChoreo", ["developer", "platform"])
    d.box(WX, L[0], WW, H, "workload", "k3s nodes", ["servers and", "workers"])
    d.box(WX, L[2], WW, H, "workload", "cluster-agent", ["installed with", "the addons"])
    xf = AX + AW / 2
    d.arrow([(xf, L[0]), (xf, 160)], step=1, badge=(xf, L[0] - 32))
    xj = A - 40                                 # step 2 forks after its badge: Argo CD renders all four
    d.arrow([(AX + AW, m[0]), (xj, m[0])], step=2, head=False, badge=(AX + AW + 30, m[0]))
    d.arrow([(xj, m[0]), (A, m[0])], step=2, badge=False)
    d.arrow([(xj, m[0]), (xj, m[1]), (A, m[1])], step=2, badge=False)
    d.junction(xj, m[0])
    d.arrow([(A + AWD, m[0]), (WX, m[0])], step=3, badge=(xz, m[0]))
    d.arrow([(A + AWD / 2, L[0] + H), (A + AWD / 2, L[1])], label="certificate", label_pos=(A + AWD / 2 + 8, L[0] + H + 40),
            label_anchor="start")
    d.line_label = "Cluster API picks up the agent certificate"
    xc = ZR + 34
    d.arrow([(A + AWD, L[0] + 64), (xc, L[0] + 64), (xc, L[2] + 20), (WX, L[2] + 20)], step=4, badge=(xc, m[1]))
    d.arrow([(AX + AW, m[2] + 12), (WX, m[2] + 12)], step=5, badge=(xj, m[2] + 12))   # only once the nodes exist
    xg = WX + WW / 2
    d.arrow([(xg, L[2] + H), (xg, m[3]), (A + AWD, m[3])], step=6, badge=(xz, m[3]), label="dials out",
            label_pos=(xz, m[3] + 32))
    d.legend_label("workload", "runs on the new cluster")
    d.require("Fleet file", "Argo CD", "Cluster API", "k3s nodes", "cert-manager", "OpenChoreo", "cluster-agent")
    d.key("Argo CD reads the fleet file clusters/<name>.yaml",
          "Argo CD renders the cluster chart: the cluster for Cluster API, the agent certificate for cert-manager "
          "(and the data plane record for OpenChoreo)",
          "Cluster API creates the machines and installs k3s",
          "Cluster API copies the agent certificate into the cluster; the CA key stays on the management cluster",
          "Once the cluster is up, Argo CD installs its addons, cluster-agent included",
          "The cluster-agent dials out to OpenChoreo, which accepts only this cluster's CA")
    d.note("Upgrade: bump kubernetesVersion in the fleet file; Cluster API replaces the nodes one at a time. "
           "Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.")
    return d


# ------------------------------------------------------------------------------------ trust & certificates
def trust() -> Diagram:
    d = Diagram("Trust & certificates · who signs what, and how it renews",
                "Two separate chains, both rooted on the management cluster: a CA per cluster for the OpenChoreo "
                "agent and, opt-in, OpenBao's mesh CA (by default istiod signs mesh certificates itself).")
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
    d.divider(44, ZR - 16, DIV)
    d.divider(WZ + 16, 916, DIV)
    d.lane(44, Z + 52, "agent identity · steps 1-4", color="#cbd5e1")
    d.lane(44, DIV + 34, "opt-in mesh CA · steps 5-7", color="#cbd5e1")
    d.box(C1, RA1, W1, H, "mgmt", "cert-manager", ["one CA", "per cluster"], step=1)
    d.box(C2, RA1, W2, H, "mgmt", "Cluster API", ["manages the", "cluster"])
    d.box(C2, RA2, W2, H, "mgmt", "cluster-gateway", ["entry point", "for agents"])
    d.box(WX, RA1, WW, H, "workload", "cluster-agent", ["OpenChoreo's agent", "on the cluster"])
    d.box(C1, RB1, C2 + W2 - C1, H, "mgmt", "OpenBao", ["mesh certificate authority,", "one per group of clusters"],
          status="optin", step=5)
    d.box(WX, RB1, WW, H, "workload", "Mesh proxies", ["ztunnel and", "gateways"])
    d.box(WX, RB2, WW, H, "workload", "istio-csr", ["signs requests", "through OpenBao"], status="optin")
    d.arrow([(C1 + W1, ymid(RA1)), (C2, ymid(RA1))], label="certificate", label_pos=((C1 + W1 + C2) / 2, ymid(RA1) - 10))
    d.line_label = "cert-manager's certificate, picked up by Cluster API"
    d.arrow([(C2 + W2, ymid(RA1)), (WX, ymid(RA1))], step=2, badge=(xz, ymid(RA1)))
    xc = C1 + W1 / 2
    d.arrow([(xc, RA1 + H), (xc, ymid(RA2)), (C2, ymid(RA2))], step=3)
    xa = WX + WW / 2
    d.arrow([(xa, RA1 + H), (xa, ymid(RA2)), (C2 + W2, ymid(RA2))], step=4, badge=(xz, ymid(RA2)),
            label="dials out", label_pos=(xz, ymid(RA2) + 32))
    d.arrow([(xa, RB1 + H), (xa, RB2)], step=6)
    xb = C2 + W2 - 100
    d.arrow([(WX, ymid(RB2)), (xb, ymid(RB2)), (xb, RB1 + H)], step=7, badge=(xz, ymid(RB2)), label="dials out",
            label_pos=(xz, ymid(RB2) + 32))
    d.require("cert-manager", "cluster-agent", "cluster-gateway", "OpenBao", "istio-csr", "Mesh proxies",
              "Cluster API")
    d.key("cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it a month "
          "before it expires",
          "Cluster API copies the agent certificate into the cluster; the CA's private key stays on the management "
          "cluster",
          "cert-manager gives cluster-gateway that cluster's CA, the only one it accepts for that cluster",
          "The cluster-agent dials out with its certificate and restarts by itself when the certificate renews",
          "Separately, OpenBao (opt-in) creates a root and an intermediate CA for each group of clusters; the keys "
          "never leave it",
          "The mesh proxies ask istio-csr for short-lived certificates: 24 hours, renewed at half-life",
          "istio-csr dials out to OpenBao, logs in with its service account and gets each request signed")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · the restore order",
                "After losing the management cluster, the operator first restores the state Git cannot recreate, "
                "from backup copies kept off the host; then Argo CD rebuilds the rest from Git.")
    SX, SW = 44, 136                           # left: the off-host copies and the operator who restores them
    MZ = SX + SW + 88                          # middle: one restore per row, in order
    OZ = 932 - 236                             # right: the secret backend, Git and object storage
    ZR = OZ - 96
    MX, MW = MZ + 16, ZR - 16 - MZ - 16
    OX, OW = OZ + 16, 932 - 16 - OZ - 16
    BY, BH = 120, 60                           # the backup copies, above the operator
    R = [BY + BH + 80 + i * (H + 40) for i in range(5)]
    zb = R[4] + H + 24
    RW = zb + 40 + 72                          # the workload cluster's row: room between its label and the chip
    zw = RW + H + 24
    d.zone(MZ, R[0] - 48, ZR - MZ, zb - R[0] + 48, "management cluster", "mgmt")
    d.zone(MZ, zb + 40, ZR - MZ, zw - zb - 40, "workload cluster", "workload")
    d.zone(OZ, R[2] - 48, 932 - OZ, zw - R[2] + 48, "outside the clusters", "external")
    d.box(SX, BY, SW, BH, "external", "Backup copies", ["off the host"])
    d.box(SX, R[0], SW, R[3] + H - R[0], "external", "Operator", ["runs the restore", "runbook"])
    d.box(MX, R[0], MW, H, "mgmt", "Cluster state (etcd)", ["clusters, access and CA keys:",
                                                             "a snapshot every 12 hours"], aka=("etcd",))
    d.box(MX, R[1], MW, H, "mgmt", "Thunder", ["users, sign-in clients,", "signing keys"])
    d.box(MX, R[2], MW, H, "mgmt", "OpenBao", ["secrets and", "mesh CA keys"], status="optin")
    d.box(MX, R[3], MW, H, "mgmt", "Harbor", ["pushed", "images"])
    d.box(MX, R[4], MW, H, "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(MX, RW, MW, H, "workload", "Databases", ["app data, only if this", "cluster is lost too"],
          status="optin")
    d.box(OX, R[2], OW, H, "external", "Secret backend", ["AWS or Vault", "secret store"])
    d.box(OX, R[4], OW, H, "external", "Git", ["everything", "declarative"])
    d.box(OX, RW, OW, H, "external", "Object storage", ["database", "backups"])
    xo = SX + SW / 2
    d.arrow([(xo, R[0]), (xo, BY + BH)], step=1, badge=(xo, BY + BH + 40), label="fetches",
            label_pos=(xo + 20, BY + BH + 45), label_anchor="start")
    xl = (SX + SW + MZ) / 2                    # badge columns: left and right of the management cluster
    xz = (ZR + OZ) / 2
    for i, n in ((0, 2), (1, 3), (2, 4), (3, 6)):
        d.arrow([(SX + SW, ymid(R[i])), (MX, ymid(R[i]))], step=n, badge=(xl, ymid(R[i])), label="restores",
                label_pos=(xl, ymid(R[i]) + 32))
    d.arrow([(MX + MW, ymid(R[2])), (OX, ymid(R[2]))], step=5, badge=(xz, ymid(R[2])),
            label="reads its key", label_pos=(xz, ymid(R[2]) + 32))
    d.arrow([(MX + MW, ymid(R[4])), (OX, ymid(R[4]))], step=7, badge=(xz, ymid(R[4])), label="reads",
            label_pos=(xz, ymid(R[4]) + 32))
    d.arrow([(MX + MW, ymid(RW)), (OX, ymid(RW))], step=8, badge=(xz, ymid(RW)), label="reads backups",
            label_pos=(xz, ymid(RW) + 32))
    d.require("Git", "Secret backend", "Cluster state (etcd)", "OpenBao", "Thunder", "Harbor", "Databases",
              "Backup copies", "Object storage", "Operator")
    d.key("The operator fetches the latest backup copies from off the host: etcd snapshots and volume copies",
          "The operator restores the management cluster's etcd from its latest snapshot: the workload clusters' "
          "records and the CA keys come back",
          "The operator restores Thunder's volumes from their copy: users, sign-in clients, signing keys",
          "The operator restores OpenBao's volume copy (opt-in): secrets and the mesh CA keys",
          "OpenBao fetches its unseal key from the secret backend, which lives outside the clusters (on a local "
          "setup, re-create it with task secrets)",
          "The operator restores Harbor's volume copy, or new builds push the images again",
          "Argo CD re-syncs everything else from Git",
          "The databases (opt-in) restore themselves from object storage, only if a workload cluster is lost too")
    d.note("Telemetry is not backed up: it starts empty.")
    return d


# -------------------------------------------------------------------------------------------- upgrade flow
def upgrade() -> Diagram:
    d = Diagram("Upgrade flow · every upgrade is a pull request",
                "Renovate proposes, CI proves, a maintainer merges; Argo CD rolls the change out to the dev clusters, "
                "and prod follows a second, reviewed pull request.")
    c, w = COLS4, CW4
    R0 = 120
    R1 = R0 + H + 96
    y0 = R0 + H + 48
    y1 = R1 + H + 40
    d.box(c[0], R0, w, H, "external", "Renovate", ["proposes", "version bumps"])
    d.box(c[1], R0, c[2] + w - c[1], H, "external", "GitHub",
          ["platform repo: pull request,", "CI, review, merge to main"], step=2, aka=("main",))
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps", "engine"])
    d.box(c[1], R1, w, H, "workload", "Dev clusters", ["follow main", "first"], step=5)
    d.box(c[2], R1, w, H, "workload", "Prod clusters", ["follow a", "verified commit"])
    d.arrow([(c[0] + w, ymid(R0)), (c[1], ymid(R0))], step=1, badge_at=0.4)
    d.arrow([(c[0] + w / 2, R1), (c[0] + w / 2, y0), (c[1] + 120, y0), (c[1] + 120, R0 + H)], step=3)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=4, badge_at=0.4)
    d.box(c[3], R1, w, H, "external", "Maintainer", ["promotes", "prod"], step=6)
    xm = c[3] + w / 2                           # the prod promotion is a pull request too
    d.arrow([(xm, R1), (xm, ymid(R0)), (c[2] + w, ymid(R0))], label="second pull request",
            label_pos=(xm - 10, R0 + H + 52), label_anchor="end")
    d.line_label = "the maintainer's prod pull request"
    d.arrow([(c[0] + w / 2, R1 + H), (c[0] + w / 2, y1), (c[2] + w / 2, y1), (c[2] + w / 2, R1 + H)], step=7,
            badge=(c[0] + w / 2 + 80, y1))
    d.legend_label("workload", "workload clusters")
    d.require("Renovate", "GitHub", "Argo CD", "Dev clusters", "Prod clusters", "Maintainer")
    d.stages("Dev clusters", "Prod clusters")
    d.key("Renovate opens a pull request: a Helm chart, a k3s release, an image or a tool version",
          "GitHub runs CI on the pull request, every chart rendered and tested on Linux, macOS and Windows, x86 and "
          "arm; a maintainer reviews and merges it into main",
          "Argo CD reads main for every cluster that follows it",
          "Argo CD syncs the dev clusters first, each app in a fixed order",
          "Dev clusters are verified: every app synced and healthy",
          "A maintainer opens and merges a second pull request in GitHub that moves the prod clusters to the verified "
          "commit",
          "Argo CD syncs the prod clusters to that commit")
    d.note("Kubernetes versions: a kubernetesVersion bump in a fleet file rolls through Cluster API instead, one "
           "server at a time, dev before prod (see the cluster lifecycle view).")
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
