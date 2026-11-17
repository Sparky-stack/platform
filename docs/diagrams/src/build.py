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
CW4 = 160                                     # 4 columns of 160 px with 80 px gutters (room for a step badge)
COLS4 = [40 + i * (CW4 + 80) for i in range(4)]
H = 80                                        # standard box height (title + 2 lines)
PITCH = H + 80                                # row pitch: 80 px between rows


def ymid(y, h=H):
    return y + h / 2


def at(a, b, f=0.5):
    """Point at fraction f from a to b (badge positions)."""
    return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)


# ------------------------------------------------------------------------------------------ architecture
def architecture() -> Diagram:
    d = Diagram("koorikla/platform · architecture",
                "Git is the only input. The mgmt cluster turns it into clusters, addons and app releases; the "
                "workload clusters run the apps.")
    w = 124
    X = [32 + i * 193 for i in range(5)]       # 5 columns, 69 px gutters
    Z1, R1 = 200, 256
    R2 = R1 + H + 80
    Z1b = R2 + H + 24
    Z2 = Z1b + 64
    CH = (Z1b + Z2) / 2                         # channel between the clusters: badges 3, 4, 5
    R3 = Z2 + 48
    d.box(X[0], 100, 200, 56, "external", "Git", ["platform + app repos"])
    d.zone(16, Z1, 928, Z1b - Z1, "mgmt cluster", "mgmt", label_at="tr")
    d.box(X[0], R1, w, H, "mgmt", "Argo CD", ["reads git,", "applies it"])
    d.box(X[2], R1, X[4] + w - X[2], H, "mgmt", "Also on mgmt",
          ["image registry (Harbor) · secrets and certificates", "admission policy (Kyverno) · sign-in (Thunder)"],
          context=True)
    d.box(X[0], R2, w, H, "mgmt", "Cluster API", ["creates the", "clusters"])
    d.box(X[2], R2, X[4] + w - X[2], H, "mgmt", "OpenChoreo", ["developer platform: builds, releases, telemetry"])
    d.zone(16, Z2, 928, R3 + H + 24 - Z2, "workload clusters · one per fleet file", "workload", label_at="tr")
    d.box(X[0], R3, w, H, "workload", "k3s nodes", ["servers +", "workers"])
    d.box(X[1], R3, w, H, "workload", "Addons", ["network, mesh,", "policy, telemetry"])
    d.box(X[2], R3, w, H, "workload", "cluster-agent", ["runs app", "releases"], aka=("agent",))
    d.box(X[3], R3, w, H, "workload", "Kyverno", ["checks every", "pod"])
    d.box(X[4], R3, w, H, "workload", "Apps", ["your teams'", "services"])
    xa = X[0] + w / 2
    d.arrow([(xa, R1), (xa, 156)], step=1, badge=(xa, R1 - 30))
    d.arrow([(xa, R1 + H), (xa, R2)], step=2)
    d.arrow([(xa, R2 + H), (xa, R3)], step=3, badge=(xa, CH))
    x4 = X[1] + w / 2
    d.arrow([(X[0] + w, ymid(R1)), (x4, ymid(R1)), (x4, R3)], step=4, badge=(x4, CH))
    x5 = X[2] + w / 2
    d.arrow([(x5, R3), (x5, R2 + H)], step=5, badge=(x5, CH))
    g = X[1] - X[0] - w
    d.arrow([(X[2] + w, ymid(R3)), (X[3], ymid(R3))], step=6, badge_at=30 / g)
    d.arrow([(X[3] + w, ymid(R3)), (X[4], ymid(R3))], step=7, badge_at=30 / g)
    d.require("Git", "Argo CD", "Cluster API", "OpenChoreo", "Kyverno", "cluster-agent", "Apps", "Also on mgmt")
    d.key("Argo CD reads git: fleet files, the addon catalog, teams",
          "Argo CD turns each fleet file into a Cluster API cluster",
          "Cluster API creates the k3s nodes on docker, AWS or Hetzner",
          "Argo CD installs the addons on every cluster whose labels match",
          "The cluster-agent dials out to OpenChoreo (mTLS) and pulls app releases",
          "The agent applies them; Kyverno checks every pod first",
          "Kyverno admits only signed images with safe pod settings into the app namespaces")
    return d


# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    d = Diagram("Security · from build to runtime",
                "A signed supply chain, admission that checks it, and runtime detection with a response; identity, "
                "secrets and keys underneath.")
    X = [196, 468, 740]
    BW = 180
    Y = [120, 280, 440, 624]
    for y, label, sub in ((Y[0], "supply chain", ["every image", "is signed"]),
                          (Y[1], "admission", ["only verified", "images start"]),
                          (Y[2], "runtime", ["detect and", "respond"]),
                          (Y[3], "foundations", ["identity, secrets,", "keys"])):
        d.lane(32, y + 22, label, sub)
    d.box(X[0], Y[0], BW, H, "mgmt", "Build", ["builds and scans", "every image"])
    d.box(X[1], Y[0], BW, H, "mgmt", "cosign", ["signs and", "attests it"])
    d.box(X[2], Y[0], BW, H, "mgmt", "Registry", ["Harbor or GitHub,", "image + signature"])
    d.box(X[0], Y[1], BW, H, "mgmt", "Production gate", ["only Argo CD may", "write production"], context=True)
    d.box(X[1], Y[1], BW, H, "workload", "App pods", ["your services"])
    d.box(X[2], Y[1], BW, H, "workload", "Kyverno", ["verifies before", "a pod starts"])
    d.box(X[0], Y[2], BW, H, "workload", "Falco", ["watches system calls", "on every node"])
    d.box(X[1], Y[2], BW, H, "workload", "Falco Talon", ["stops or labels", "the pod"])
    d.box(X[2], Y[2], BW, H, "mgmt", "Response workflow", ["on mgmt, for", "critical alerts"])
    d.box(X[0], Y[3], BW, H, "security", "Thunder", ["sign-in for console,", "API and CLI"], context=True)
    d.box(X[1], Y[3], BW, H, "security", "External Secrets", ["one secret backend,", "scoped stores"], context=True)
    d.box(X[2], Y[3], BW, H, "security", "Certificates", ["a CA per cluster,", "a mesh CA"], context=True)
    g = X[1] - X[0] - BW
    d.arrow([(X[0] + BW, ymid(Y[0])), (X[1], ymid(Y[0]))], step=1, badge_at=34 / g)
    d.arrow([(X[1] + BW, ymid(Y[0])), (X[2], ymid(Y[0]))], step=2, badge_at=34 / g)
    xk = X[2] + BW / 2
    d.arrow([(xk, Y[1]), (xk, Y[0] + H)], step=3)
    d.arrow([(X[2], ymid(Y[1])), (X[1] + BW, ymid(Y[1]))], step=4, badge_at=34 / g)
    ch = (Y[1] + H + Y[2]) / 2
    d.arrow([(X[0] + 64, Y[2]), (X[0] + 64, ch), (X[1] + 52, ch), (X[1] + 52, Y[1] + H)], step=5)
    d.arrow([(X[0] + BW, ymid(Y[2])), (X[1], ymid(Y[2]))], step=6, badge_at=34 / g)
    cb = Y[2] + H + 40
    d.arrow([(X[0] + 104, Y[2] + H), (X[0] + 104, cb), (xk, cb), (xk, Y[2] + H)], step=7)
    d.require("Kyverno", "cosign", "Registry", "Production gate", "Falco", "Falco Talon", "Response workflow",
              "Thunder", "External Secrets", "Certificates")
    d.key("The build scans the image (Trivy), writes an SBOM and SLSA provenance and hands it to cosign",
          "cosign signs and attests it (platform key in-cluster, keyless on GitHub) and stores both in the registry",
          "Kyverno checks the signature and attestations in the registry: Deny in production, Audit in dev and "
          "staging",
          "Kyverno admits only verified images with Pod Security baseline settings",
          "Falco watches every pod's system calls (eBPF on each node)",
          "Falco alerts Falco Talon, which terminates or labels the pod in place",
          "Falco escalates critical alerts to mgmt: falcosidekick → argo-events → the response workflow")
    return d


# ----------------------------------------------------------------------------------------------- network
def network() -> Diagram:
    d = Diagram("Network · a request in, the agents out",
                "A request enters through kgateway and crosses the mesh on mTLS; the agent and the collectors dial "
                "out to mgmt. Kyverno adds every app to the mesh before any traffic.")
    C = [40, 280, 520]
    BW = 160
    ZR = 648                                    # workload zone right edge
    MX, MW = 752, 168
    R1 = 264
    R2 = R1 + H + 72
    HB = 64                                     # mesh and network rows: title + one line
    R3 = R2 + HB + 72
    R4 = R3 + HB + 104
    R5 = R4 + H + 56
    d.box(C[0], 100, BW, 56, "external", "Client", ["opens the app URL"])
    d.zone(16, 200, ZR - 16, R5 + H + 24 - 200, "workload cluster", "workload", label_at="tr")
    d.zone(MX - 24, R4 - 56, 944 - MX + 24, R5 + H + 24 - R4 + 56, "mgmt cluster", "mgmt")
    d.box(C[0], R1, BW, H, "workload", "kgateway", ["the cluster's", "front door"])
    d.box(C[1], R1, BW, H, "workload", "App pods", ["your services"])
    d.box(C[2], R1, ZR - 16 - C[2], H, "workload", "Kyverno", ["adds every app", "to the mesh"], context=True)
    d.box(C[0], R2, ZR - 16 - C[0], HB, "workload", "Service mesh (Istio ambient)",
          ["encrypts every hop between pods and gives each one an identity"], aka=("service mesh",))
    d.box(C[0], R3, ZR - 16 - C[0], HB, "workload", "Cluster network (Cilium or flannel)",
          ["chosen per cluster when it is created"])
    d.lane(32, R4 - 24, "the agents out")
    d.box(C[0], R4, 192, H, "workload", "cluster-agent", ["OpenChoreo's agent"])
    d.box(C[0], R5, 192, H, "workload", "Collectors", ["logs, metrics", "and traces"])
    d.box(MX, R4, MW, H, "mgmt", "cluster-gateway", ["accepts only", "known clusters"])
    d.box(MX, R5, MW, H, "mgmt", "Observability plane", ["stores all", "telemetry"])
    xc = C[0] + BW / 2
    d.arrow([(xc, 156), (xc, R1)], step=1, badge=(xc, R1 - 42))
    g = C[1] - C[0] - BW
    d.arrow([(C[0] + BW, ymid(R1)), (C[1], ymid(R1))], step=2, badge_at=0.4)
    d.arrow([(C[2], ymid(R1)), (C[1] + BW, ymid(R1))])
    d.line_label = "Kyverno sets this up (context)"
    xp = C[1] + BW / 2
    d.arrow([(xp, R1 + H), (xp, R2)], step=3, badge_at=0.45)
    d.arrow([(xp, R2 + HB), (xp, R3)], step=4, badge_at=0.45)
    xz = (ZR + MX - 24) / 2
    d.arrow([(C[0] + 192, ymid(R4)), (MX, ymid(R4))], step=5, badge=(xz, ymid(R4)))
    d.arrow([(C[0] + 192, ymid(R5)), (MX, ymid(R5))], step=6, badge=(xz, ymid(R5)))
    d.require("kgateway", "Kyverno", "Service mesh (Istio ambient)", "Cluster network (Cilium or flannel)",
              "cluster-gateway", "cluster-agent", "Collectors")
    d.key("A client opens the app URL; kgateway (Gateway API) takes the request",
          "kgateway routes it to the app pods (HTTPRoute; through a waypoint if opted in)",
          "App pods reach each other only through the service mesh: ztunnel adds mTLS and a workload identity, "
          "no sidecars",
          "The service mesh rides the cluster network: Cilium (eBPF, WireGuard) or flannel, chosen in the fleet file",
          "The cluster-agent dials out to mgmt on port 8443 (TLS passthrough); cluster-gateway accepts only that "
          "cluster's certificate",
          "Collectors (OTel Collector, Fluent Bit, Prometheus agent) dial out and ship logs, metrics and traces to "
          "the observability plane")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · one place to query every signal",
                "Collectors on every workload cluster ship to OpenChoreo's observability plane on mgmt; one observer "
                "API answers Backstage, the promotion gate and the AI agents.", reading="columns")
    K, KW = 32, 192
    T, TW = 344, 136
    O, OW = 560, 128
    U, UW = 792, 136
    R = [200, 336, 472]
    m = [ymid(y) for y in R]
    zb = R[2] + H + 24
    d.zone(16, 128, 224, zb - 128, "workload cluster", "workload")
    d.zone(320, 128, 624, zb - 128, "mgmt cluster", "mgmt")
    d.lane(T, R[0] - 20, "observability plane")
    d.lane(U, R[0] - 20, "consumers")
    d.box(K, R[0], KW, H, "workload", "Fluent Bit", ["container logs,", "security alerts"])
    d.box(K, R[1], KW, H, "workload", "OTel Collector", ["app traces, metrics", "and cluster events"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["container and", "cluster metrics"])
    d.box(T, R[0], TW, R[1] + H - R[0], "data", "OpenSearch", ["logs, traces", "and events"])
    d.box(T, R[2], TW, H, "data", "Prometheus", ["metrics"])
    d.box(O, R[1], OW, H, "mgmt", "Observer API", ["one query API,", "one login"])
    d.box(U, R[0], UW, H, "mgmt", "Backstage", ["developer", "portal"])
    d.box(U, R[1], UW, H, "mgmt", "Promotion gate", ["checks alerts", "before release"])
    d.box(U, R[2], UW, H, "mgmt", "AI agents", ["root cause,", "cost reports"], status="optin")
    d.legend_label("data", "telemetry stores (mgmt)")
    xb = 280                                   # badge column between the zones
    d.arrow([(K + KW, m[0]), (T, m[0])], step=1, badge=(xb, m[0]))
    xj = 304                                   # step 2 forks after its badge: traces/events up, metrics down
    d.arrow([(K + KW, m[1]), (xj, m[1])], step=2, head=False, badge=(xb - 4, m[1]))
    d.arrow([(xj, m[1]), (T, m[1])], step=2, badge=False)
    d.arrow([(xj, m[1]), (xj, R[2] + 24), (T, R[2] + 24)], step=2, badge=False)
    d.junction(xj, m[1])
    d.arrow([(K + KW, R[2] + 56), (T, R[2] + 56)], step=3, badge=(xb, R[2] + 56))
    xi = 512                                   # step 4 forks after its badge: the observer API queries both stores
    d.arrow([(O, m[1]), (T + TW, m[1])], step=4, badge=(O - 30, m[1]))
    d.arrow([(xi, m[1]), (xi, m[2]), (T + TW, m[2])], step=4, badge=False)
    d.junction(xi, m[1])
    xo = 736                                   # step 5 joins before its badge: three consumers query the API
    d.arrow([(U, m[1]), (O + OW, m[1])], step=5, badge=(U - 30, m[1]))
    d.arrow([(U, m[0]), (xo, m[0]), (xo, m[1])], step=5, badge=False, head=False)
    d.arrow([(U, m[2]), (xo, m[2]), (xo, m[1])], step=5, badge=False, head=False)
    d.junction(xo, m[1])
    d.require("OTel Collector", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "Observer API",
              "Backstage", "Promotion gate", "AI agents")
    d.key("Fluent Bit ships container logs, Falco security alerts included, to OpenSearch",
          "The OTel Collector sends app traces and Kubernetes events to OpenSearch and app metrics to Prometheus",
          "The Prometheus agent scrapes container and cluster metrics (cAdvisor, kube-state-metrics) and "
          "remote-writes them to Prometheus",
          "The observer API queries both stores behind one login (Thunder)",
          "Backstage, the promotion gate and the opt-in AI agents query the observer API")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image, promoted through environments by pull requests; production is gated twice, "
                "at promotion and at admission.")
    c, w = COLS4, CW4
    R = [120, 120 + PITCH, 120 + 2 * PITCH + 16]
    ch = R[1] + H + 48
    d.box(c[0], R[0], w, H, "external", "App repo", ["your code and its", "deploy/ folder"])
    d.box(c[1], R[0], c[2] + w - c[1], H, "mgmt", "Build & sign",
          ["OpenChoreo workflow plane or GitHub Actions", "scans, records what is inside, signs"])
    d.box(c[3], R[0], w, H, "mgmt", "Registry", ["Harbor or GitHub,", "signed images"])
    d.box(c[0], R[1], w, H, "mgmt", "Argo CD", ["reads the", "deploy/ folder"])
    d.box(c[1], R[1], w, H, "mgmt", "Release", ["an immutable", "snapshot"])
    d.box(c[2], R[1], w, H, "mgmt", "Promotion gate", ["checks health,", "opens the PR"])
    d.box(c[0], R[2], w, H, "workload", "Development", ["deploys", "automatically"])
    d.box(c[1], R[2], w, H, "workload", "Staging", ["after a", "promotion PR"])
    d.box(c[2], R[2], w, H, "workload", "Production", ["gated PR,", "code owners"])
    d.box(c[3], R[2], w, H, "workload", "Kyverno", ["signed, pinned", "images only"])
    d.arrow([(c[0] + w, ymid(R[0])), (c[1], ymid(R[0]))], step=1, badge_at=0.4)
    d.arrow([(c[2] + w, ymid(R[0])), (c[3], ymid(R[0]))], step=2, badge_at=0.4)
    xa = c[0] + w / 2
    d.arrow([(xa, R[1]), (xa, R[0] + H)], step=3)
    d.arrow([(c[0] + w, ymid(R[1])), (c[1], ymid(R[1]))], step=4, badge_at=0.4)
    d.arrow([(c[1] + 24, R[1] + H), (c[1] + 24, ch), (xa, ch), (xa, R[2])], step=5)
    d.arrow([(c[2] + 32, R[1] + H), (c[2] + 32, ch), (c[1] + 104, ch), (c[1] + 104, R[2])], step=6)
    d.arrow([(c[2] + 112, R[1] + H), (c[2] + 112, R[2])], step=7, badge=(c[2] + 112, ch))
    d.arrow([(c[3], ymid(R[2])), (c[2] + w, ymid(R[2]))], step=8, badge_at=0.4)
    d.arrow([(c[0] + w, ymid(R[2])), (c[1], ymid(R[2]))])
    d.arrow([(c[1] + w, ymid(R[2])), (c[2], ymid(R[2]))])
    xk = c[3] + w / 2
    d.arrow([(xk, R[2]), (xk, R[0] + H)], label="checks the signature", label_pos=(xk, ymid(R[1]) + 5))
    d.line_label = "promotion path, signature check"
    d.require("App repo", "Build & sign", "Registry", "Argo CD", "Release", "Promotion gate", "Development",
              "Staging", "Production", "Kyverno")
    d.key("A push to the app repo starts a build on the OpenChoreo workflow plane (or GitHub Actions)",
          "Build & sign scans the image (Trivy), writes SBOM and SLSA provenance, signs with cosign, pushes it and "
          "commits the new image ref to deploy/",
          "Argo CD reads the app repo's deploy/ folder (Component and Workload)",
          "Argo CD applies them to OpenChoreo, which snapshots an immutable release (ComponentRelease)",
          "The release deploys to development automatically (autoDeploy)",
          "The promotion gate checks development (readiness, smoke tests, alerts, freezes) and opens the PR to "
          "staging",
          "The promotion gate opens production only with CODEOWNERS approval; an admission policy lets only "
          "Argo CD write production",
          "Kyverno admits into production only signed images pinned by digest (Audit in development and staging)")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    d = Diagram("Cluster lifecycle · add, upgrade, remove = edit one file",
                "A fleet file becomes a Cluster API cluster, an Argo CD cluster secret and an OpenChoreo data plane; "
                "deleting it removes all three.")
    AX, AW = 32, 144
    A, B, CW = 276, 500, 144
    ZR = 660
    WX, WW = 764, 160
    L = [256, 256 + H + 72, 256 + 2 * (H + 72), 256 + 3 * (H + 72)]
    m = [ymid(y) for y in L]
    ZB = L[3] + H + 24
    d.box(AX, 100, 240, 56, "external", "Fleet file", ["`clusters/dev1.yaml`"])
    d.zone(16, 200, ZR - 16, ZB - 200, "mgmt cluster", "mgmt", label_at="tr")
    d.zone(ZR + 80, 200, 944 - ZR - 80, ZB - 200, "workload cluster", "workload", label_at="tr")
    d.box(AX, L[0], AW, L[3] + H - L[0], "mgmt", "Argo CD",
          ["renders one chart", "per fleet file:", "", "the cluster,", "its secrets,", "its identity,", "its data plane"])
    d.box(A, L[0], CW, H, "mgmt", "Cluster API", ["creates and", "upgrades nodes"])
    d.box(WX, L[0], WW, H, "workload", "k3s nodes", ["servers +", "workers"])
    d.box(A, L[1], CW, H, "mgmt", "Cluster secret", ["access + labels", "for Argo CD"])
    d.box(B, L[1], CW, H, "mgmt", "Addon sets", ["pick clusters", "by label"])
    d.box(WX, L[1], WW, H, "workload", "Addons", ["network, mesh,", "policy, …"])
    d.box(A, L[2], CW, H, "mgmt", "Agent identity", ["a CA of its own", "per cluster"])
    d.box(WX, L[2], WW, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"])
    d.box(B, L[3], CW, H, "mgmt", "Data plane", ["OpenChoreo's view", "of the cluster"])
    xf = AX + AW / 2
    xz = (ZR + ZR + 80) / 2                     # badge column between the zones
    d.arrow([(xf, L[0]), (xf, 156)], step=1, badge=(xf, L[0] - 30))
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
    d.arrow([(WX + 80, L[2] + H), (WX + 80, m[3]), (B + CW, m[3])], step=8, badge=(xz, m[3]))
    d.require("Fleet file", "Argo CD", "Cluster API", "k3s nodes", "Cluster secret", "Addon sets", "Addons",
              "Agent identity", "Data plane", "cluster-agent")
    d.key("Argo CD reads clusters/<name>.yaml and creates Application cluster-<name> (ApplicationSet fleet)",
          "Argo CD renders charts/cluster: the Cluster API cluster, its secrets, the agent identity and the "
          "OpenChoreo data plane",
          "Cluster API creates the machines and installs k3s",
          "Cluster API's kubeconfig becomes an Argo CD cluster secret with the fleet labels (ESO)",
          "The cluster secret's labels select the addon sets (ApplicationSets) that apply",
          "The addon sets install every selected addon on the new cluster",
          "The agent identity (its certificate) is delivered to the cluster; the CA key never leaves mgmt",
          "The cluster-agent dials out; the data plane tells the gateway to accept only this cluster's CA")
    d.note("Upgrade: bump kubernetesVersion in the fleet file; Cluster API replaces the nodes one at a time. "
           "Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.")
    return d


# ------------------------------------------------------------------------------------ trust & certificates
def trust() -> Diagram:
    d = Diagram("Trust & certificates · who signs what, and how it renews",
                "Two certificate chains, both rooted on mgmt: a CA per cluster for the OpenChoreo agent, and "
                "OpenBao's mesh CA per cluster group. Private CA keys never leave mgmt.")
    C1, W1 = 32, 220
    C2, W2 = 320, 220
    ZR = 576
    WX, WW = 680, 240
    Z = 112
    RA1 = 184
    RA2 = RA1 + H + 64
    DIV = RA2 + H + 36
    RB1 = DIV + 76
    RB2 = RB1 + H + 80
    ZB = RB2 + H + 24
    xz = (ZR + ZR + 80) / 2
    d.zone(16, Z, ZR - 16, ZB - Z, "mgmt cluster", "mgmt")
    d.zone(ZR + 80, Z, 944 - ZR - 80, ZB - Z, "workload cluster", "workload")
    d.divider(32, 928, DIV)
    d.lane(32, Z + 52, "agent identity · always on")
    d.lane(32, DIV + 34, "service mesh CA · opt-in")
    d.box(C1, RA1, W1, H, "mgmt", "cert-manager", ["one CA per cluster,", "renews certificates"], step=1)
    d.box(C2, RA2, W2, H, "mgmt", "cluster-gateway", ["the agents' entry", "point on mgmt"])
    d.box(WX, RA1, WW, H, "workload", "cluster-agent", ["OpenChoreo's agent", "on the cluster"])
    d.box(C1, RB1, W1, H, "mgmt", "OpenBao", ["mesh CA per group,", "keys never leave it"], status="optin",
          step=5)
    d.box(WX, RB1, WW, H, "workload", "istio-csr", ["gets mesh certificates", "signed"])
    d.box(WX, RB2, WW, H, "workload", "Mesh proxies", ["encrypt traffic", "between services"])
    d.arrow([(C1 + W1, ymid(RA1)), (WX, ymid(RA1))], step=2, badge=(xz, ymid(RA1)))
    xc = C1 + W1 / 2
    d.arrow([(xc, RA1 + H), (xc, ymid(RA2)), (C2, ymid(RA2))], step=3)
    xa = WX + WW / 2
    d.arrow([(xa, RA1 + H), (xa, ymid(RA2)), (C2 + W2, ymid(RA2))], step=4, badge=(xz, ymid(RA2)))
    d.arrow([(WX, ymid(RB1)), (C1 + W1, ymid(RB1))], step=6, status="optin", both=True, badge=(xz, ymid(RB1)))
    d.arrow([(xa, RB1 + H), (xa, RB2)], step=7)
    d.require("cert-manager", "cluster-agent", "cluster-gateway", "OpenBao", "istio-csr", "Mesh proxies")
    d.key("cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it 30 days "
          "before expiry",
          "cert-manager's certificate is copied to the cluster (ESO, ClusterResourceSet); the CA key stays on mgmt",
          "cert-manager gives cluster-gateway that CA: the only one it accepts for this cluster",
          "The cluster-agent dials out with its certificate (mTLS); Reloader restarts it when the certificate renews",
          "OpenBao (opt-in) holds each group's root and intermediate CA; its public root is copied to every member",
          "istio-csr logs in to OpenBao with its service account token and gets mesh certificates signed",
          "istio-csr hands short-lived certificates to the mesh: 24 h for workloads, 48 h for istiod, renewed at "
          "half-life")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · what is stateful, where",
                "Git rebuilds everything declarative; the violet boxes hold state it cannot recreate. Numbers: the "
                "restore order after losing mgmt.")
    OX, OW = 32, 192
    M1, M2, MW = 336, 504, 152
    WX, WW = 768, 160
    R = [176, 312, 448, 608]
    d.zone(16, 128, 224, R[3] + H + 24 - 128, "outside", "external")
    d.zone(320, 128, 352, R[2] + H + 24 - 128, "mgmt cluster", "mgmt")
    d.zone(752, 128, 192, R[3] + H + 24 - 128, "workload", "workload")
    d.box(OX, R[0], OW, H, "external", "Secret backend", ["AWS or Vault", "secret stores"], step=1)
    d.box(OX, R[2], OW, H, "external", "Git", ["everything", "declarative"])
    d.box(OX, R[3], OW, H, "external", "Object storage", ["database backups:", "S3, GCS, Azure"])
    d.box(M1, R[0], M2 + MW - M1, H, "data", "Cluster state (etcd)",
          ["snapshot every 12 h, 5 kept:", "clusters, access, CA keys"], step=2, aka=("mgmt etcd",))
    d.box(M1, R[1], MW, H, "data", "OpenBao", ["a cold copy", "of its data"], status="optin")
    d.box(M2, R[1], MW, H, "data", "Thunder", ["users and", "sign-in clients"], step=4)
    d.box(M1, R[2], MW, H, "mgmt", "Argo CD", ["re-applies", "everything else"])
    d.box(M2, R[2], MW, H, "data", "Harbor", ["pushed", "images"], step=6)
    d.box(WX, R[0], WW, H, "workload", "Workload clusters", ["rebuilt by Argo CD", "and OpenChoreo"], context=True)
    d.box(WX, R[3], WW, H, "data", "Databases", ["continuous", "backup"], status="optin")
    xz = 280
    xs = OX + OW / 2
    d.arrow([(M1, ymid(R[1])), (xs, ymid(R[1])), (xs, R[0] + H)], step=3, badge=(xz, ymid(R[1])))
    d.arrow([(M1, ymid(R[2])), (OX + OW, ymid(R[2]))], step=5, badge=(xz, ymid(R[2])))
    d.arrow([(WX, ymid(R[3])), (OX + OW, ymid(R[3]))], step=7, status="optin", badge=(712, ymid(R[3])))
    d.legend_label("data", "holds state: restore it")
    d.legend_label("mgmt", "mgmt: rebuilt from git")
    d.legend_label("external", "outside: where backups live")
    d.require("Git", "Secret backend", "Cluster state (etcd)", "OpenBao", "Thunder", "Harbor", "Workload clusters",
              "Databases")
    d.key("The secret backend lives outside the clusters (AWS Secrets Manager, Vault); locally re-seed it with "
          "task secrets",
          "Restore mgmt etcd from a k3s snapshot: Cluster API keeps its clusters and the CA keys come back",
          "OpenBao (opt-in) restores its data from a cold volume copy and unseals with the key from the secret "
          "backend",
          "Restore Thunder's volumes: users, OAuth clients, signing keys",
          "Argo CD re-syncs everything else from git",
          "Harbor's images come back from its volumes or from new builds; telemetry starts empty",
          "Databases (opt-in CNPG) restore from object storage when a workload cluster is lost")
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
    d.box(c[0], R0, w, H, "external", "Renovate", ["proposes every", "version bump"])
    d.box(c[1], R0, w, H, "external", "Pull request", ["one bump", "per PR"])
    d.box(c[2], R0, w, H, "external", "CI", ["renders and tests", "every install"])
    d.box(c[3], R0, w, H, "external", "Main branch", ["reviewed and", "merged"], aka=("main",))
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["syncs clusters", "from main"])
    d.box(c[1], R1, w, H, "workload", "Dev clusters", ["follow main", "first"], step=6)
    d.box(c[2], R1, w, H, "workload", "Prod clusters", ["follow a", "verified commit"])
    d.box(c[3], R1, w, H, "mgmt", "Cluster API", ["replaces servers", "one at a time"])
    for i in range(3):
        d.arrow([(c[i] + w, ymid(R0)), (c[i + 1], ymid(R0))], step=i + 1, badge_at=0.4)
    d.arrow([(c[0] + 64, R1), (c[0] + 64, y0), (c[3] + w / 2, y0), (c[3] + w / 2, R0 + H)], step=4)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=5, badge_at=0.4)
    d.arrow([(c[0] + 100, R1 + H), (c[0] + 100, y1), (c[2] + w / 2, y1), (c[2] + w / 2, R1 + H)], step=7)
    d.arrow([(c[0] + 40, R1 + H), (c[0] + 40, y2), (c[3] + w / 2, y2), (c[3] + w / 2, R1 + H)], step=8,
            badge=(c[3] - 40, y2))
    d.require("Renovate", "Pull request", "CI", "Main branch", "Argo CD", "Dev clusters", "Prod clusters",
              "Cluster API")
    d.key("Renovate opens a pull request: a Helm chart, a k3s release, an image digest or a tool pin",
          "The pull request runs CI: every chart rendered for every installation; lint, schema, unit and contract "
          "tests on Linux (x86, arm), macOS, Windows and the devcontainers",
          "CI must pass and a maintainer reviews; then the pull request is squash-merged into main",
          "Argo CD reads main for every cluster that follows it (addonsRevision: HEAD)",
          "Argo CD syncs the dev clusters first; sync waves order each app (e.g. istiod before ztunnel)",
          "Dev clusters are verified: every Argo CD app Synced and Healthy, task status green",
          "Argo CD syncs the prod clusters only after a pull request moves their addonsRevision to the verified "
          "commit",
          "Argo CD hands a kubernetesVersion bump to Cluster API, which replaces servers one at a time (3 keep "
          "quorum)")
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
