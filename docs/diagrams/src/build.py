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
    d.box(c[3], R1, w, H, "mgmt", "Shared services", ["image registry, sign-in,", "OpenBao secrets"], context=True)
    d.box(c[0], R2, w, H, "mgmt", "Cluster API", ["creates", "clusters"])
    d.box(c[2], R2, c[3] + w - c[2], H, "mgmt", "OpenChoreo", ["developer platform: builds, releases, telemetry"])
    d.zone(28, Z2, 904, R3 + H + 64 - Z2, "workload clusters", "workload", label_at="tr")
    d.box(c[0], R3, w, H, "workload", "Data services", ["Crossplane databases,", "CloudNativePG"], status="optin",
          context=True)
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
          "Cluster API creates each workload cluster: k3s nodes on docker, AWS or Hetzner, or managed GKE",
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
          "kgateway, itself in the service mesh, routes it to the app pods",
          "Inside the Istio ambient service mesh, ztunnel encrypts every hop, from the gateway to the app pods and "
          "between them; app namespaces refuse unencrypted traffic and callers from other apps' namespaces",
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
SDLC_STEPS = (
    "A developer merges a reviewed PR to main in the app repo",
    "The new commit reaches Build & sign within a minute (it polls main)",
    "Build & sign tests, scans and signs the image with the platform key and pushes it to Harbor",
    "Build & sign commits the image digest to deploy/ on main, which starts no new build",
    "The digest commit is synced by Argo CD; OpenChoreo cuts one immutable release",
    "OpenChoreo deploys it to development",
    "Kyverno in development checks the image signature and attestations, and only warns",
    "The team opens and merges a staging PR that picks the release verified in development",
    "The merged staging PR is synced by Argo CD",
    "OpenChoreo deploys the same release to staging",
    "Kyverno in staging checks them the same way, and only warns",
    "Staging's finished rollout starts the promotion gate: readiness, smoke tests, alerts, 5xx rate, freeze window",
    "The promotion gate opens a production PR only if every check passes",
    "A code owner approves and merges the production PR",
    "The merged production PR is synced by Argo CD, after the freeze window if one is active",
    "OpenChoreo deploys the same release to production",
    "Kyverno in production blocks any pod whose image signature, attestations or digest do not verify",
)
SDLC_NOTE = ("Freeze window: the gate opens no production PR (re-run it afterwards) and Argo CD holds a production PR "
             "merged anyway until the window ends; break glass by changing the window in git. A failed scan stops the "
             "build, a failed gate check the promotion. Roll back by reverting the production PR.")


def sdlc() -> Diagram:
    """Swimlanes: actors are rows, environments are columns. Every environment repeats one vertical pattern down its
    column (a person merges -> Argo CD syncs -> OpenChoreo deploys -> Kyverno admits), so the loop back through Argo CD
    and OpenChoreo is drawn once per environment instead of as a back-arrow. Arrows follow the change."""
    d = Diagram("SDLC · from merged PR to production",
                "Build once, in-cluster. Then each environment repeats one pattern down its column: a person merges a "
                "PR, Argo CD syncs it, OpenChoreo deploys the same signed release and Kyverno admits it.",
                reading="columns")
    d.flow_label = "numbered step: the change moves along the arrow"
    xb, cw, gap = 150, 196, 68                  # columns: development, staging, production
    cx = [xb, xb + cw + gap, xb + 2 * (cw + gap)]
    ax = [cx[i] + 50 for i in range(3)]         # each column's spine, right of the step rings
    PT, PB, G = 36, 14, 96                      # band padding (top: lane label, chips), gap between lanes' boxes
    RB, HB = 104 + PT, 72                       # build, registry, gate (the lede is two lines)
    RG, HG = RB + HB + G, 72                    # app repo
    RP, HP = RG + HG + G, 72                    # Argo CD + OpenChoreo
    RE, HE = RP + HP + G, 80                    # workload
    DN = 36                                     # badge offset from the source edge of a downward arrow

    def band(y, h, label, plane, sub=()):
        d.zone(28, y - PT, 904, h + PT + PB, label, plane)
        for i, s in enumerate(sub):
            d.text(44, y - PT + 44 + i * 18, s)

    band(RB, HB, "automation", "mgmt", ("build, registry", "and gate"))
    band(RG, HG, "app repo", "external", ("every change:", "a merge to main"))
    band(RP, HP, "platform", "mgmt", ("Argo CD +", "OpenChoreo"))
    band(RE, HE, "workload", "workload", ("local default:", "one workload", "cluster, a name-", "space per env"))

    d.box(cx[0], RB, cw, HB, "mgmt", "Build & sign", ["in-cluster: tests, scans,", "signs with platform key"])
    d.box(cx[1], RB, cw, HB, "mgmt", "Harbor", ["one signed image per", "build; every env pulls it"])
    d.box(cx[2], RB, cw, HB, "mgmt", "Promotion gate", ["readiness, smoke, alerts,", "5xx rate, freeze window"])
    d.box(cx[0], RG, cw, HG, "external", "Main branch", ["developers merge", "reviewed code"], step=1,
          tag="MANUAL", aka=("developer", "new commit", "digest commit"))
    d.box(cx[1], RG, cw, HG, "external", "Staging PR", ["picks a release,", "the team merges"], step=8,
          tag="MANUAL", aka=("team", "merged staging PR"))
    d.box(cx[2], RG, cw, HG, "external", "Production PR", ["opened by the gate,", "a code owner merges"], step=14,
          tag="MANUAL", aka=("code owner", "merged production PR"))
    d.box(cx[0], RP, cw, HP, "mgmt", "New release", ["Argo CD syncs,", "OpenChoreo cuts it"],
          aka=("OpenChoreo deploys it to development",))
    d.box(cx[1], RP, cw, HP, "mgmt", "Promote to staging", ["Argo CD syncs,", "OpenChoreo deploys"],
          aka=("OpenChoreo deploys the same release to staging",))
    d.box(cx[2], RP, cw, HP, "mgmt", "Promote to production", ["Argo CD syncs, OpenChoreo", "deploys; never in a freeze"],
          aka=("OpenChoreo deploys the same release to production",))
    d.box(cx[0], RE, cw, HE, "workload", "Development", ["every new release;", "Kyverno warns"], step=7,
          aka=("Kyverno in development",))
    d.box(cx[1], RE, cw, HE, "workload", "Staging", ["the same release;", "Kyverno warns"], step=11,
          aka=("Kyverno in staging",))
    d.box(cx[2], RE, cw, HE, "workload", "Production", ["the same release;", "Kyverno blocks"], step=17,
          aka=("Kyverno in production",))

    # build once (development column): the merge goes to Build & sign, the image to Harbor, the digest back to main
    x = ax[0]
    d.arrow([(x - 30, RG), (x - 30, RB + HB)], step=2, badge=(x - 30, RB + HB + 40), label="builds",
            label_pos=(x - 50, RB + HB + 45), label_anchor="end")
    d.arrow([(cx[0] + cw, ymid(RB, HB)), (cx[1], ymid(RB, HB))], step=3, badge=(cx[0] + cw + 30, ymid(RB, HB)),
            label="pushes", label_pos=(cx[0] + cw + 34, ymid(RB, HB) - 22), label_bg=d.zone_fill("mgmt"))
    d.arrow([(x, RB + HB), (x, RG)], step=4, badge=(x, RB + HB + DN), label="digest",
            label_pos=(x + 20, RB + HB + DN + 5), label_anchor="start")
    # the same spine in every column: the merge on main -> Argo CD + OpenChoreo -> the environment
    for i, (s_sync, s_deploy) in enumerate(((5, 6), (9, 10), (15, 16))):
        x = ax[i]
        d.arrow([(x, RG + HG), (x, RP)], step=s_sync, badge=(x, RG + HG + DN), label="syncs",
                label_pos=(x + 20, RG + HG + DN + 5), label_anchor="start")
        d.arrow([(x, RP + HP), (x, RE)], step=s_deploy, badge=(x, RP + HP + DN), label="deploys",
                label_pos=(x + 20, RP + HP + DN + 5), label_anchor="start")
    # staging -> production: staging's finished rollout starts the gate; the gate opens the production PR
    xc = cx[1] + cw + 34
    d.arrow([(cx[1] + cw, ymid(RE, HE)), (xc, ymid(RE, HE)), (xc, ymid(RB, HB)), (cx[2], ymid(RB, HB))], step=12,
            badge=(xc, RB + HB + 40), label="rollout done", label_pos=(xc - 20, RB + HB + 45), label_anchor="end")
    d.arrow([(ax[2], RB + HB), (ax[2], RG)], step=13, badge=(ax[2], RB + HB + DN), label="opens PR",
            label_pos=(ax[2] + 20, RB + HB + DN + 5), label_anchor="start")
    # development -> staging: the team promotes the release it verified in development
    xd = cx[0] + cw + 34
    d.arrow([(cx[0] + cw, ymid(RE, HE)), (xd, ymid(RE, HE)), (xd, ymid(RG, HG)), (cx[1], ymid(RG, HG))],
            label="verified", label_pos=(xd - 14, RP + HP + DN + 5), label_anchor="end")
    d.line_label = "the release the team verified in development"
    d.legend_chip("MANUAL", "a person merges a pull request")
    d.legend_label("workload", "workload cluster (local default: one, with a namespace per environment; "
                               "multicluster: production on its own)")
    d.require("Main branch", "Build & sign", "Harbor", "New release", "Promote to staging", "Promote to production",
              "Staging PR", "Production PR", "Promotion gate", "Development", "Staging", "Production")
    d.stages("Development", "Staging", "Production")
    d.key(*SDLC_STEPS)
    d.note(SDLC_NOTE)
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
    d.box(MX, R[2], MW, H, "mgmt", "OpenBao", ["app secrets and", "mesh CA keys"], status="optin")
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
          "The operator restores OpenBao's volume copy (opt-in): app secrets and the mesh CA keys",
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
          "GitHub runs CI on the pull request: every changed chart rendered and tested (all of them nightly, on "
          "Linux, macOS and Windows); a maintainer reviews and merges it into main",
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


# ------------------------------------------------------------------------------- delivery lanes (#270, devops guide)
# Appended for docs/devops-guide.md: one overview, one view per lane in the same 3-column layout, and the app +
# database object map. Arrows follow the change (like the SDLC view), so a step text names the arrow's source first.
CHANGE_FLOW = "numbered step: the change moves along the arrow"
LW = 232                                      # lane views: 3 columns of 232 px with 88 px gutters (badge channels)
LC = [44 + i * (LW + 88) for i in range(3)]
LANE_APPS_STEPS = (
    "App repo: a merge to main runs the reusable CI workflow it pins by commit (app-go.yaml and the other stacks, "
    "each calling app-container.yaml): lint, tests, vulnerability scan, multi-arch build",
    "Reusable CI pushes the image to ghcr.io and signs it keyless with cosign, with SBOM, provenance and "
    "vulnerability attestations",
    "Registry digest goes into the app repo: app-workload-bump.yaml commits the image digest to the Workload in "
    "deploy/ ([skip ci])",
    "Deploy folder is synced by Argo CD (the team's Application) into OpenChoreo: Component, Workload, "
    "ReleaseBinding",
    "Argo CD hands them to the OpenChoreo control plane, which cuts one immutable release and binds it to "
    "development",
    "OpenChoreo passes the release to the cluster-agent over the connection the agent opened from the workload "
    "cluster",
    "cluster-agent applies the release in the environment's namespace, where Kyverno sees every pod first",
    "Kyverno verifies the image signature, attestations and digest before the pod starts: it blocks in production "
    "and only warns in development and staging",
)
LANE_APPS_NOTE = ("Promotion: the same release moves to staging and production by pull requests, the promotion gate "
                  "opens the production one (see the SDLC view, which also shows the in-cluster build path with "
                  "Harbor and the platform key).")
LR = [168 + i * 160 for i in range(3)]        # rows: source / CI / artifact, then declare / sync / hand-off


def _lane_frame(title: str, lede: str) -> Diagram:
    d = Diagram(title, lede, reading="columns")
    d.flow_label = CHANGE_FLOW
    for x, s in zip(LC, ("build and sign", "declare and sync", "run and admit")):
        d.lane(x, LR[0] - 34, s)
    return d


def _lane_spine(d: Diagram, s1=1, s2=2, s3=3, s4=4):
    """Shared arrows of every lane view: source -> CI -> artifact (column 1), artifact or CI -> git (gutter 1),
    git -> Argo CD (column 2)."""
    x0, x1 = LC[0] + LW / 2, LC[1] + LW / 2
    d.arrow([(x0, LR[0] + H), (x0, LR[1])], step=s1)
    d.arrow([(x0, LR[1] + H), (x0, LR[2])], step=s2)
    xg = LC[0] + LW + 44
    d.arrow([(LC[0] + LW, ymid(LR[2])), (xg, ymid(LR[2])), (xg, ymid(LR[0])), (LC[1], ymid(LR[0]))], step=s3,
            badge=(xg, ymid(LR[1])))
    d.arrow([(x1, LR[0] + H), (x1, LR[1])], step=s4)


def lane_apps() -> Diagram:
    d = _lane_frame("Apps lane · from a merge to a running, verified pod",
                    "The app repo's reusable CI builds and signs one image; its digest goes back into the repo; "
                    "Argo CD and OpenChoreo roll it out; Kyverno admits only that signed digest.")
    c, w = LC, LW
    d.box(c[0], LR[0], w, H, "external", "App repo", ["service code,", "calls the platform CI"])
    d.box(c[0], LR[1], w, H, "external", "Reusable CI", ["tests, scans, builds,", "signs the image"])
    d.box(c[0], LR[2], w, H, "external", "Registry", ["signed image,", "addressed by digest"])
    d.box(c[1], LR[0], w, H, "external", "Deploy folder", ["the app repo's", "release files in git"])
    d.box(c[1], LR[1], w, H, "mgmt", "Argo CD", ["syncs the deploy", "folder"])
    d.box(c[1], LR[2], w, H, "mgmt", "OpenChoreo", ["cuts a release,", "promotes it"])
    d.box(c[2], LR[0], w, H, "mgmt", "Promotion gate", ["staging to production:", "see the SDLC view"],
          context=True)
    d.box(c[2], LR[1], w, H, "workload", "cluster-agent", ["applies the release", "in the cluster"])
    d.box(c[2], LR[2], w, H, "workload", "Kyverno", ["admits only signed", "images by digest"], step=8)
    _lane_spine(d)
    d.arrow([(c[1] + w / 2, LR[1] + H), (c[1] + w / 2, LR[2])], step=5)
    xg = c[1] + w + 44
    d.arrow([(c[1] + w, ymid(LR[2])), (xg, ymid(LR[2])), (xg, ymid(LR[1])), (c[2], ymid(LR[1]))], step=6,
            badge=(xg, LR[1] + H + 40))
    d.arrow([(c[2] + 50, LR[1] + H), (c[2] + 50, LR[2])], step=7)    # left of centre: the ring (8) sits at x+26
    d.require("App repo", "Reusable CI", "Registry", "Deploy folder", "Argo CD", "OpenChoreo", "cluster-agent",
              "Kyverno")
    d.key(*LANE_APPS_STEPS)
    d.note(LANE_APPS_NOTE)
    return d


LANE_INFRA_STEPS = (
    "A pull request to the platform repo, from Renovate (a new upstream release) or a person, changes a chart pin, "
    "addon values or a fleet file and runs ci.yaml, scoped to what changed",
    "CI fetches the pinned upstream charts (versions in Chart.yaml and Chart.lock, sha256 pins for the mesh) and "
    "lints, renders and unit-tests every changed chart",
    "CI must pass before a maintainer merges: main then declares the versions, in the addon charts, the "
    "ApplicationSets and the installation values",
    "Main branch is read by Argo CD: dev clusters follow main, prod clusters a verified commit",
    "Argo CD renders each fleet file into a cluster for Cluster API, which creates and upgrades its k3s nodes",
    "Argo CD installs the addons on every cluster whose labels match, in a fixed order",
    "Kyverno admits the addon pods with safe settings only; their images are pinned by digest in git (a test checks "
    "it), not signature-verified: Argo CD cannot verify Helm or OCI chart signatures",
)
LANE_INFRA_NOTE = ("Planned: verify upstream chart signatures in the Renovate pull request and mirror the charts "
                   "into an internal registry, once upstreams sign them (few do today). release-please tags each "
                   "platform release.")


def lane_infra() -> Diagram:
    d = _lane_frame("Infra lane · addons, clusters and platform charts",
                    "Upstream charts are pinned in git and tested by CI; Argo CD installs them on every matching "
                    "cluster and Cluster API builds the clusters. Signatures stop at the image layer for now.")
    c, w = LC, LW
    d.box(c[0], LR[0], w, H, "external", "Pull request", ["Renovate or a person:", "a pin, values, a cluster"],
          aka=("Renovate",))
    d.box(c[0], LR[1], w, H, "external", "CI", ["lints, renders, tests", "every changed chart"])
    d.box(c[0], LR[2], w, H, "external", "Upstream charts", ["their own registries,", "pinned by version"])
    d.box(c[1], LR[0], w, H, "external", "Main branch", ["chart pins, addon", "catalog, fleet files"])
    d.box(c[1], LR[1], w, H, "mgmt", "Argo CD", ["installs by", "cluster label"])
    d.box(c[1], LR[2], w, H, "mgmt", "Cluster API", ["creates and", "upgrades clusters"])
    d.box(c[2], LR[1], w, H, "workload", "Addons", ["network, mesh, policy,", "operators"])
    d.box(c[2], LR[2], w, H, "workload", "Kyverno", ["checks pod settings;", "images pinned by digest"], step=7)
    x0 = c[0] + w / 2
    d.arrow([(x0, LR[0] + H), (x0, LR[1])], step=1)
    d.arrow([(x0, LR[1] + H), (x0, LR[2])], step=2)
    xg = c[0] + w + 44
    d.arrow([(c[0] + w, ymid(LR[1])), (xg, ymid(LR[1])), (xg, ymid(LR[0])), (c[1], ymid(LR[0]))], step=3,
            badge=(xg, LR[0] + H + 40))
    x1 = c[1] + w / 2
    d.arrow([(x1, LR[0] + H), (x1, LR[1])], step=4)
    d.arrow([(x1, LR[1] + H), (x1, LR[2])], step=5)
    d.arrow([(c[1] + w, ymid(LR[1])), (c[2], ymid(LR[1]))], step=6, badge=(c[1] + w + 34, ymid(LR[1])))
    d.require("Pull request", "CI", "Upstream charts", "Main branch", "Argo CD", "Cluster API", "Addons", "Kyverno")
    d.key(*LANE_INFRA_STEPS)
    d.note(LANE_INFRA_NOTE)
    return d


LANE_EXT_STEPS = (
    "A pull request to packages/<api> runs package-<api>.yaml, which calls app-crossplane-configuration.yaml: "
    "schema checks and render tests for every backend",
    "Package CI pushes the Configuration package and its embedded function to ghcr.io on main and on release tags, "
    "signed keyless with cosign, with SLSA provenance",
    "Registry tag and digest are pinned in addon crossplane's values (or one installation's) by a Renovate pull "
    "request; merging it is the promotion",
    "Package pin on main is synced by Argo CD to every cluster that runs addon crossplane (opt-in)",
    "Argo CD applies the Configuration at that digest; Crossplane's package manager pulls it and its function from "
    "the registry",
    "Crossplane will verify the package signature before installing it: the switch is on main but stays off until "
    "Crossplane reads cosign v3 signatures",
    "Crossplane installs the API definition, its composition and function: apps can now claim the API, for "
    "example a PostgreSQL database",
)
LANE_EXT_NOTE = ("The other extension points ride the other lanes: OpenChoreo component types, traits and resource "
                 "types are files of the openchoreo-platform addon (infra lane), Backstage templates are read from "
                 "git by the catalog, Backstage plugins come with its image.")


def lane_extensions() -> Diagram:
    d = _lane_frame("Extensions lane · a new platform API",
                    "A Crossplane package is built, signed and pushed like an app image; a pinned digest in git "
                    "promotes it, and Crossplane installs the API on every cluster that runs it.")
    c, w = LC, LW
    d.box(c[0], LR[0], w, H, "external", "Package source", ["an API, its composition", "and render tests"],
          aka=("pull request",))
    d.box(c[0], LR[1], w, H, "external", "Package CI", ["validates, renders,", "signs the package"])
    d.box(c[0], LR[2], w, H, "external", "Registry", ["signed package,", "addressed by digest"])
    d.box(c[1], LR[0], w, H, "external", "Package pin", ["version and digest", "in git"])
    d.box(c[1], LR[1], w, H, "mgmt", "Argo CD", ["syncs the pin to", "each cluster"])
    d.box(c[1], LR[2], w, H, "external", "Other extensions", ["component types, traits:", "the infra lane"],
          context=True)
    d.box(c[2], LR[0], w, H, "workload", "Platform API", ["what apps claim,", "e.g. a database"])
    d.box(c[2], LR[1], w, H, "workload", "Crossplane", ["installs packages,", "composes claims"], status="optin")
    d.box(c[2], LR[2], w, H, "workload", "Signature check", status="planned")
    _lane_spine(d)
    d.arrow([(c[1] + w, ymid(LR[1])), (c[2], ymid(LR[1]))], step=5, badge=(c[1] + w + 34, ymid(LR[1])))
    x2 = c[2] + w / 2
    d.arrow([(x2, LR[1] + H), (x2, LR[2])], step=6, status="planned")
    d.arrow([(x2, LR[1]), (x2, LR[0] + H)], step=7)
    d.require("Package source", "Package CI", "Registry", "Package pin", "Argo CD", "Crossplane", "Platform API")
    d.key(*LANE_EXT_STEPS)
    d.note(LANE_EXT_NOTE)
    return d


DELIVERY_STEPS = (
    "App CI builds, scans and signs one image per merge (keyless cosign, attestations) and pushes it by digest",
    "Signed image's digest is committed to the app repo's deploy folder by the bump job",
    "Deploy folder is synced by Argo CD into OpenChoreo, which releases it to each environment through the "
    "cluster-agent",
    "OpenChoreo's environments run Kyverno, which admits only the signed digest: it blocks in production and "
    "warns in development and staging",
    "Infra CI renders and tests every chart against its pinned upstream version; Renovate opens the bump pull "
    "requests",
    "Upstream charts stay pinned by version (and digest where possible) on main after review",
    "Main branch is synced by Argo CD to every cluster whose labels match; Cluster API builds the clusters",
    "Argo CD's addons pass Kyverno for pod settings; their images are pinned by digest, chart signatures are not "
    "checked yet",
    "Package CI renders, tests, signs and pushes each Crossplane package by digest",
    "Signed package's digest is pinned in addon crossplane by a reviewed Renovate pull request",
    "Package pin is synced by Argo CD; Crossplane (opt-in) pulls the package and installs the API",
    "Crossplane's package signature check is planned: packages are signed, verification waits for cosign v3 "
    "support",
)


def delivery_lanes() -> Diagram:
    d = Diagram("Delivery lanes · three lanes, one pattern",
                "Apps, infra and extensions each go source and reusable CI, then a signed artifact pinned by digest, "
                "then a version declared in git, then a reconciler and the cluster's admission check.")
    d.flow_label = CHANGE_FLOW
    w, g = 166, 69
    x = [44 + i * (w + g) for i in range(4)]
    for xi, s in zip(x, ("source + CI", "signed artifact", "declared in git", "reconciled")):
        d.text(xi, 128, s.upper(), 13, "#cbd5e1", weight=700, spacing=1.0)
    rows = [184 + i * 156 for i in range(3)]
    lanes = (
        ("apps lane", ("App CI", ["app repo, reusable", "workflows"]), ("Signed image", ["keyless signature,", "attestations"]),
         ("Deploy folder", ["image digest in", "the app repo"]), ("OpenChoreo", ["releases to each", "environment"], "mgmt", "built")),
        ("infra lane", ("Infra CI", ["addon wrappers,", "cluster charts"]), ("Upstream charts", ["pinned upstream", "releases"]),
         ("Main branch", ["platform repo:", "pins and values"]), ("Argo CD", ["by cluster label;", "Cluster API"], "mgmt", "built")),
        ("extensions lane", ("Package CI", ["Crossplane", "packages"]), ("Signed package", ["keyless signature,", "provenance"]),
         ("Package pin", ["version and digest", "in the addon"]), ("Crossplane", ["installs the", "platform API"], "workload", "optin")),
    )
    n = 1
    for r, (lane, a, b, c3, dd) in zip(rows, lanes):
        d.lane(x[0], r - 14, lane)
        d.box(x[0], r, w, H, "external", *a)
        d.box(x[1], r, w, H, "external", *b)
        d.box(x[2], r, w, H, "external", *c3)
        d.box(x[3], r, w, H, dd[2], dd[0], dd[1], status=dd[3], step=n + 3)
        for i in range(3):
            d.arrow([(x[i] + w, ymid(r)), (x[i + 1], ymid(r))], step=n + i, badge=(x[i] + w + 30, ymid(r)))
        n += 4
    d.require("App CI", "Infra CI", "Package CI", "OpenChoreo", "Argo CD", "Crossplane")
    d.key(*DELIVERY_STEPS)
    return d


APP_DB_STEPS = (
    "Component (with the keda-scaler trait), Workload, Resource of type postgresql and SecretReference are synced "
    "from the app repo by Argo CD into OpenChoreo",
    "OpenChoreo renders the Resource into the cell namespace as a PostgreSQL claim (platform.koorikla.io, a "
    "namespaced Crossplane XR)",
    "OpenBao's value behind the SecretReference lands in the app secret: External Secrets reads the project's "
    "own mount through the cell's SecretStore",
    "PostgreSQL claim is composed by Crossplane with the Composition of the Configuration package; the "
    "EnvironmentConfig platform-postgresql picks the backend",
    "Crossplane creates a CloudNativePG Cluster on a local cluster (RDS or Aurora, Cloud SQL, Azure Flexible "
    "Server in the cloud)",
    "CloudNativePG creates the database and its owner and writes the connection secret <name>-app next to the "
    "workload",
    "App secret reaches the app pods as env, from secretKeyRef or envFrom",
    "Connection secret reaches the app pods, which OpenChoreo deployed from the Workload: host, port and database "
    "as values, user, password and URI as secret references; KEDA scales them",
)
APP_DB_NOTE = ("Planned: the same map for the event bus and its topics. Production asks for high availability and "
               "backups (admission policy); credentials never leave the workload cluster.")


def app_database_map() -> Diagram:
    d = Diagram("App + database · how the objects map",
                "A developer writes four objects in the app repo; OpenChoreo renders them into the app's cell "
                "namespace, Crossplane turns the database claim into a real database and the secrets meet in the "
                "pods.")
    d.flow_label = "numbered step: one object becomes the next"
    w, g = 166, 69
    c = [44 + i * (w + g) for i in range(4)]
    Z0 = 140
    R0 = Z0 + 48
    Z0b = R0 + H + 16
    Z1 = Z0b + 96
    R1 = Z1 + 48
    Z1b = R1 + H + 16
    Z2 = Z1b + 64
    R2 = Z2 + 48
    R3 = R2 + H + 80
    d.zone(28, Z0, 904, Z0b - Z0, "app repo: written by the developer", "external")
    d.zone(28, Z1, 904, Z1b - Z1, "management cluster", "mgmt")
    d.zone(28, Z2, 904, R3 + H + 24 - Z2, "workload cluster", "workload", label_at="tr")
    d.box(c[0], R0, w, H, "external", "Component", ["the service and", "its scaling trait"])
    d.box(c[1], R0, w, H, "external", "Workload", ["image, env from the", "database"])
    d.box(c[2], R0, w, H, "external", "Database resource", ["type postgresql:", "version, database"],
          aka=("Resource of type postgresql",))
    d.box(c[3], R0, w, H, "external", "Secret reference", ["points at a value", "in OpenBao"],
          aka=("SecretReference",))
    d.box(c[0], R1, c[2] + w - c[0], H, "mgmt", "OpenChoreo", ["control plane: renders every object", "into the cell namespace"])
    d.box(c[3], R1, w, H, "mgmt", "OpenBao", ["the project's", "secret values"], status="optin")
    d.box(c[0], R2, w, H, "workload", "PostgreSQL claim", ["the platform's", "database API"])
    d.box(c[1], R2, w, H, "workload", "Crossplane", ["composes it for", "this cluster"], status="optin")
    d.box(c[2], R2, w, H, "workload", "CloudNativePG", ["runs PostgreSQL", "in the cluster"], status="optin")
    d.box(c[3], R2, w, H, "workload", "App secret", ["values copied", "from OpenBao"])
    d.box(c[2], R3, w, H, "workload", "Connection secret", ["host, user,", "password"])
    d.box(c[3], R3, w, H, "workload", "App pods", ["env from both", "secrets"])
    yb = Z0b + 30                               # step 1: the four objects join on one bus into OpenChoreo
    xs = [ci + w / 2 for ci in c]
    xm = c[1] + w / 2 + 40
    d.arrow([(xs[0], yb), (xs[3], yb)], step=1, badge=False, head=False)
    for xi in xs:
        d.arrow([(xi, R0 + H), (xi, yb)], step=1, badge=False, head=False)
        d.junction(xi, yb)
    d.arrow([(xm, yb), (xm, R1)], step=1, badge=(xm, yb + 32))
    d.junction(xm, yb)
    d.arrow([(xs[0], R1 + H), (xs[0], R2)], step=2, badge=(xs[0], Z1b + 32))
    xo = c[3] - 25                              # down the gutter, left of the zone label
    d.arrow([(c[3], ymid(R1)), (xo, ymid(R1)), (xo, ymid(R2)), (c[3], ymid(R2))], step=3, badge=(xo, Z1b + 32))
    d.arrow([(c[0] + w, ymid(R2)), (c[1], ymid(R2))], step=4, badge=(c[0] + w + 30, ymid(R2)))
    d.arrow([(c[1] + w, ymid(R2)), (c[2], ymid(R2))], step=5, badge=(c[1] + w + 30, ymid(R2)))
    d.arrow([(xs[2], R2 + H), (xs[2], R3)], step=6)
    d.arrow([(xs[3], R2 + H), (xs[3], R3)], step=7)
    d.arrow([(c[2] + w, ymid(R3)), (c[3], ymid(R3))], step=8, badge=(c[2] + w + 30, ymid(R3)))
    d.require("Component", "Workload", "Database resource", "Secret reference", "OpenChoreo", "PostgreSQL claim",
              "Crossplane", "CloudNativePG", "Connection secret", "App pods", "OpenBao")
    d.key(*APP_DB_STEPS)
    d.note(APP_DB_NOTE)
    return d


DIAGRAMS.update({
    "delivery-lanes": delivery_lanes,
    "lane-apps": lane_apps,
    "lane-infra": lane_infra,
    "lane-extensions": lane_extensions,
    "app-database-map": app_database_map,
})


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
