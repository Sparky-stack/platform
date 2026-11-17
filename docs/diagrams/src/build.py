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
                "Argo CD syncs everything from Git; the management cluster turns it into clusters, addons and app "
                "releases, and the workload clusters run the apps.")
    c, w = COLS4, CW4
    Z1, R1 = 200, 264
    R2 = R1 + H + 80
    Z1b = R2 + H + 24
    Z2 = Z1b + 64
    CH = Z1b + 22                               # channel between the clusters: badges 4, 5, 6
    R3 = Z2 + 48
    d.box(c[0], 100, w, 56, "external", "Git", ["platform + app repos"])
    d.zone(28, Z1, 904, Z1b - Z1, "management cluster", "mgmt", label_at="tr")
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["GitOps engine"])
    d.box(c[2], R1, c[3] + w - c[2], H, "mgmt", "OpenChoreo", ["developer platform: builds, releases, telemetry"])
    d.box(c[0], R2, w, H, "mgmt", "Cluster API", ["creates", "clusters"])
    d.box(c[3], R2, w, H, "mgmt", "Shared services", ["image registry,", "secrets, sign-in"], context=True)
    d.zone(28, Z2, 904, R3 + H + 24 - Z2, "workload clusters", "workload", label_at="tr")
    d.box(c[1], R3, w, H, "workload", "Addons", ["network, mesh,", "policy, telemetry"])
    d.box(c[2], R3, w, H, "workload", "cluster-agent", ["OpenChoreo's", "agent"], aka=("agent",))
    d.box(c[3], R3, w, H, "workload", "Apps", ["your teams'", "services"], step=8)
    xa = c[0] + w / 2
    d.arrow([(xa, 156), (xa, R1)], step=1, badge=(xa, R1 - 42))
    d.arrow([(c[0] + w, R1 + 24), (c[2], R1 + 24)], step=2, badge=(c[0] + w + 58, R1 + 24))
    d.arrow([(xa, R1 + H), (xa, R2)], step=3)
    d.arrow([(xa, R2 + H), (xa, Z2)], step=4, badge=(xa, CH))
    x5 = c[1] + w / 2
    d.arrow([(c[0] + w, R1 + 56), (x5, R1 + 56), (x5, R3)], step=5, badge=(x5, CH))
    x6 = c[2] + w / 2
    d.arrow([(x6, R3), (x6, R1 + H)], step=6, badge=(x6, CH), label="dials out", label_pos=(x6 + 20, CH + 5),
            label_anchor="start")
    d.arrow([(c[2] + w, ymid(R3)), (c[3], ymid(R3))], step=7, badge_at=0.4)
    d.require("Git", "Argo CD", "Cluster API", "OpenChoreo", "cluster-agent", "Apps", "Addons", "Shared services")
    d.key("Git holds everything: fleet files, the addon catalog, teams and app repos; Argo CD syncs it",
          "Argo CD hands each app's release to OpenChoreo",
          "Argo CD turns each fleet file into a Cluster API cluster",
          "Cluster API creates a workload cluster per fleet file, on docker, AWS or Hetzner",
          "Argo CD installs the addons on every cluster whose labels match: network, mesh, policy, telemetry",
          "The cluster-agent dials out to OpenChoreo (mTLS); the releases come back over that connection",
          "The agent deploys the apps",
          "Apps start only after Kyverno admits them: signed images, safe pod settings")
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
    d.box(X[1], Y[0], BW, H, "mgmt", "cosign", ["signatures and", "attestations"])
    d.box(X[2], Y[0], BW, H, "mgmt", "Registry", ["stores images", "and signatures"])
    d.box(X[0], Y[1], BW, H, "workload", "Kyverno", ["admission", "policy"])
    d.box(X[1], Y[1], BW, H, "workload", "App pods", ["your", "services"])
    d.box(X[0], Y[2], BW, H, "workload", "Falco", ["runtime", "detection"])
    d.box(X[1], Y[2], BW, H, "workload", "Falco Talon", ["automatic", "response"])
    d.box(X[2], Y[2], BW, H, "mgmt", "Response workflow", ["escalation on the", "management cluster"])
    g = X[1] - X[0] - BW
    xk = X[0] + BW / 2
    xr = X[2] + BW / 2
    d.arrow([(X[0] + BW, ymid(Y[0])), (X[1], ymid(Y[0]))], step=1, badge_at=0.4)
    d.arrow([(X[1] + BW, ymid(Y[0])), (X[2], ymid(Y[0]))], step=2, badge_at=0.4)
    c0 = Y[0] + H + 40
    d.arrow([(xr, Y[0] + H), (xr, c0), (xk, c0), (xk, Y[1])], step=3)
    d.arrow([(X[0] + BW, ymid(Y[1])), (X[1], ymid(Y[1]))], step=4, badge_at=0.4)
    c1 = Y[1] + H + 40
    d.arrow([(X[1] + 64, Y[1] + H), (X[1] + 64, c1), (xk, c1), (xk, Y[2])], step=5)
    d.arrow([(X[0] + BW, ymid(Y[2])), (X[1], ymid(Y[2]))], step=6, badge_at=0.4)
    c2 = Y[2] + H + 40
    d.arrow([(xk, Y[2] + H), (xk, c2), (xr, c2), (xr, Y[2] + H)], step=7)
    assert g >= 80
    d.require("Kyverno", "cosign", "Registry", "Falco", "Falco Talon", "Response workflow", "App pods", "Build")
    d.key("The build scans the image (Trivy), writes an SBOM and SLSA provenance and hands the digest to cosign",
          "cosign signs and attests the image and stores both next to it in the registry (Harbor or GHCR)",
          "The registry serves image, signature and attestations to Kyverno at admission",
          "Kyverno admits only verified images whose pods meet the Pod Security baseline: it blocks in production "
          "and only warns in dev and staging",
          "App pods' system calls are watched by Falco (eBPF on every node)",
          "Falco alerts Falco Talon, which stops or labels the offending pod",
          "Falco escalates critical alerts to the response workflow on the management cluster (falcosidekick, "
          "argo-events)")
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
    d.key("A client opens the app URL; kgateway (Gateway API) takes the request",
          "kgateway routes it into the service mesh (HTTPRoute; a waypoint adds L7 policy if opted in)",
          "The service mesh delivers it to the app pods: ztunnel encrypts every hop with mTLS and a workload "
          "identity, no sidecars",
          "The service mesh rides the cluster network: Cilium (eBPF, WireGuard) or flannel, chosen per cluster",
          "Separately, the cluster-agent dials out to the management cluster on port 8443; cluster-gateway accepts "
          "only that cluster's certificate",
          "The collectors (OTel Collector, Fluent Bit, Prometheus agent) dial out too and ship logs, metrics and "
          "traces to the observability plane")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · one place to query every signal",
                "Collectors on every workload cluster ship to OpenChoreo's observability plane on the management "
                "cluster; one observer API answers Backstage, the promotion gate and the AI agents.",
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
    d.box(K, R[0], KW, H, "workload", "Fluent Bit", ["container logs,", "security alerts"])
    d.box(K, R[1], KW, H, "workload", "OTel Collector", ["app traces, metrics", "and cluster events"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["container and", "cluster metrics"])
    d.box(T, R[0], TW, R[1] + H - R[0], "mgmt", "OpenSearch", ["logs, traces", "and events"])
    d.box(T, R[2], TW, H, "mgmt", "Prometheus", ["metrics"])
    d.box(O, R[1], OW, H, "mgmt", "Observer API", ["one query API,", "one login"])
    d.box(U, R[0], UW, H, "mgmt", "Backstage", ["developer", "portal"])
    d.box(U, R[1], UW, H, "mgmt", "Promotion gate", ["checks alerts", "before release"])
    d.box(U, R[2], UW, H, "mgmt", "AI agents", ["root cause,", "cost reports"], status="optin")
    xb = 300                                   # badge column between the zones
    d.arrow([(K + KW, m[0]), (T, m[0])], step=1, badge=(xb, m[0]))
    xj = 320                                   # step 2 forks after its badge: traces/events up, metrics down
    d.arrow([(K + KW, m[1]), (xj, m[1])], step=2, head=False, badge=(xb - 8, m[1]))
    d.arrow([(xj, m[1]), (T, m[1])], step=2, badge=False)
    d.arrow([(xj, m[1]), (xj, R[2] + 24), (T, R[2] + 24)], step=2, badge=False)
    d.junction(xj, m[1])
    d.arrow([(K + KW, R[2] + 56), (T, R[2] + 56)], step=3, badge=(xb, R[2] + 56))
    xi = T + TW + 20                           # step 4 joins before its badge: both stores answer the observer API
    d.arrow([(T + TW, m[1]), (O, m[1])], step=4, badge=(O - 38, m[1]))
    d.arrow([(T + TW, m[2]), (xi, m[2]), (xi, m[1])], step=4, badge=False, head=False)
    d.junction(xi, m[1])
    xo = O + OW + 56                           # step 5 forks after its badge to the three consumers
    d.arrow([(O + OW, m[1]), (U, m[1])], step=5, badge=(O + OW + 30, m[1]))
    d.arrow([(xo, m[1]), (xo, m[0]), (U, m[0])], step=5, badge=False)
    d.arrow([(xo, m[1]), (xo, m[2]), (U, m[2])], step=5, badge=False)
    d.junction(xo, m[1])
    d.require("OTel Collector", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "Observer API",
              "Backstage", "Promotion gate", "AI agents")
    d.key("Fluent Bit ships container logs, Falco security alerts included, to OpenSearch",
          "The OTel Collector sends app traces and Kubernetes events to OpenSearch and app metrics to Prometheus",
          "The Prometheus agent scrapes container and cluster metrics (cAdvisor, kube-state-metrics) and "
          "remote-writes them to Prometheus",
          "OpenSearch and Prometheus answer the observer API: one query API behind one login (Thunder)",
          "The observer API answers Backstage, the promotion gate and the opt-in AI agents")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image, promoted through environments by pull requests; production is gated twice, "
                "at promotion and at admission.")
    c, w = COLS4, CW4
    R = [120, 120 + PITCH, 120 + 2 * PITCH + 16]
    ch = R[1] + H + 48
    d.box(c[0], R[0], w, H, "external", "App repo", ["your code and", "deploy/ folder"])
    d.box(c[1], R[0], c[2] + w - c[1], H, "mgmt", "Build & sign",
          ["OpenChoreo workflow plane (or GitHub Actions)", "scan, inventory, signature"])
    d.box(c[3], R[0], w, H, "mgmt", "Registry", ["signed", "images"])
    d.box(c[0], R[1], w, H, "mgmt", "Argo CD", ["syncs the", "deploy/ folder"])
    d.box(c[1], R[1], w, H, "mgmt", "Release", ["immutable", "snapshot"])
    d.box(c[2], R[1], w, H, "workload", "Development", ["deploys", "automatically"])
    d.box(c[3], R[1], w, H, "mgmt", "Promotion gate", ["checks health,", "opens the PR"])
    d.box(c[1], R[2], w, H, "workload", "Staging", ["promoted", "by PR"])
    d.box(c[2], R[2], w, H, "workload", "Production", ["code owners,", "signed images"], step=9)
    d.arrow([(c[0] + w, ymid(R[0])), (c[1], ymid(R[0]))], step=1, badge_at=0.4)
    d.arrow([(c[2] + w, ymid(R[0])), (c[3], ymid(R[0]))], step=2, badge_at=0.4)
    xa = c[0] + w / 2
    d.arrow([(xa, R[0] + H), (xa, R[1])], step=3)
    d.arrow([(c[0] + w, ymid(R[1])), (c[1], ymid(R[1]))], step=4, badge_at=0.4)
    d.arrow([(c[1] + w, ymid(R[1])), (c[2], ymid(R[1]))], step=5, badge_at=0.4)
    d.arrow([(c[2] + w, ymid(R[1])), (c[3], ymid(R[1]))], step=6, badge_at=0.4)
    d.arrow([(c[3] + w / 2, R[1] + H), (c[3] + w / 2, ch), (c[1] + w / 2, ch), (c[1] + w / 2, R[2])], step=7)
    d.arrow([(c[1] + w, ymid(R[2])), (c[2], ymid(R[2]))], step=8, badge_at=0.4)
    d.require("App repo", "Build & sign", "Registry", "Argo CD", "Release", "Promotion gate", "Development",
              "Staging", "Production")
    d.key("A push to the app repo starts a build on the OpenChoreo workflow plane (or GitHub Actions)",
          "Build & sign scans the image (Trivy), writes SBOM and SLSA provenance, signs with cosign, pushes it to "
          "the registry and commits the new image ref to deploy/",
          "The app repo's deploy/ folder is synced by Argo CD",
          "Argo CD applies it to OpenChoreo, which snapshots an immutable release (ComponentRelease)",
          "The release deploys to development automatically",
          "Development's health (readiness, smoke tests, alerts, freezes) is checked by the promotion gate",
          "The promotion gate opens the pull request that promotes the release to staging; Argo CD applies it "
          "once merged",
          "Staging is promoted to production the same way, plus CODEOWNERS approval; only Argo CD may write "
          "production",
          "Production admits only signed images pinned by digest: Kyverno blocks the rest (in dev and staging it "
          "only warns)")
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
                "agent, and OpenBao's mesh CA per group of clusters. Private CA keys never leave it.")
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
    d.box(WX, RB2, WW, H, "workload", "Mesh proxies", ["ztunnel, gateways", "and istiod"])
    d.arrow([(C1 + W1, ymid(RA1)), (WX, ymid(RA1))], step=2, badge=(xz, ymid(RA1)))
    xc = C1 + W1 / 2
    d.arrow([(xc, RA1 + H), (xc, ymid(RA2)), (C2, ymid(RA2))], step=3)
    xa = WX + WW / 2
    d.arrow([(xa, RA1 + H), (xa, ymid(RA2)), (C2 + W2, ymid(RA2))], step=4, badge=(xz, ymid(RA2)),
            label="dials out", label_pos=(xz, ymid(RA2) + 32))
    d.arrow([(WX, ymid(RB1)), (C2 + W2, ymid(RB1))], step=6, badge=(xz, ymid(RB1)), label="dials out",
            label_pos=(xz, ymid(RB1) + 32))
    d.arrow([(xa, RB1 + H), (xa, RB2)], step=7)
    d.require("cert-manager", "cluster-agent", "cluster-gateway", "OpenBao", "istio-csr", "Mesh proxies")
    d.key("cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it 30 days "
          "before expiry",
          "cert-manager delivers the certificate to the cluster through ESO and a ClusterResourceSet; the CA key "
          "stays on the management cluster",
          "cert-manager gives cluster-gateway that cluster's CA: the only one it accepts for it",
          "The cluster-agent dials out with its certificate (mTLS) and restarts by itself when the certificate "
          "renews",
          "OpenBao (opt-in) creates a root and an intermediate CA per group of clusters; the keys never leave it, "
          "the public root is copied to each member",
          "istio-csr (opt-in) dials out to OpenBao through cert-manager's OpenBao issuer, logs in with its service "
          "account and gets mesh certificates signed",
          "istio-csr hands short-lived certificates to the mesh: 24 h for ztunnel and gateways, 48 h for istiod, "
          "renewed at half-life")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · the restore order",
                "Git rebuilds everything declarative; the violet boxes hold state it cannot recreate. The numbers "
                "are the restore order after losing the management cluster.")
    OX, OW = 44, 192
    M1, M2, MW = 364, 680, 236
    R = [176, 312, 448, 656]
    zb = R[2] + H + 24
    d.zone(28, 128, 224, R[3] + H + 24 - 128, "outside", "external")
    d.zone(348, 128, 584, zb - 128, "management cluster", "mgmt")
    d.zone(348, zb + 40, 584, R[3] + H + 24 - zb - 40, "workload cluster", "workload")
    d.box(OX, R[0], OW, H, "external", "Secret backend", ["AWS or Vault", "secret store"], step=1)
    d.box(OX, R[2], OW, H, "external", "Git", ["everything", "declarative"])
    d.box(OX, R[3], OW, H, "external", "Object storage", ["database", "backups"])
    d.box(M1, R[0], M2 + MW - M1, H, "data", "Cluster state (etcd)",
          ["clusters, access and CA keys:", "a snapshot every 12 h"], step=2, aka=("etcd",))
    d.box(M1, R[1], MW, H, "data", "OpenBao", ["cold copy", "of its data"], status="optin")
    d.box(M2, R[1], MW, H, "data", "Thunder", ["users and", "sign-in clients"], step=4)
    d.box(M1, R[2], MW, H, "mgmt", "Argo CD", ["re-applies", "everything else"])
    d.box(M2, R[2], MW, H, "data", "Harbor", ["pushed", "images"], step=6)
    d.box(M1, R[3], MW, H, "data", "Databases", ["continuous", "backups"], status="optin")
    xz = 300
    xs = OX + OW / 2
    d.arrow([(xs, R[0] + H), (xs, ymid(R[1])), (M1, ymid(R[1]))], step=3, badge=(xz, ymid(R[1])))
    d.arrow([(OX + OW, ymid(R[2])), (M1, ymid(R[2]))], step=5, badge=(xz, ymid(R[2])))
    d.arrow([(OX + OW, ymid(R[3])), (M1, ymid(R[3]))], step=7, badge=(xz, ymid(R[3])))
    d.legend_label("data", "holds state: restore it")
    d.legend_label("mgmt", "management cluster: rebuilt from git")
    d.legend_label("external", "outside: where backups live")
    d.require("Git", "Secret backend", "Cluster state (etcd)", "OpenBao", "Thunder", "Harbor", "Databases")
    d.key("The secret backend (AWS Secrets Manager, Vault) lives outside the clusters; locally, re-seed it with "
          "task secrets",
          "Restore the management cluster's etcd from a k3s snapshot (every 12 h, 5 kept): Cluster API keeps its "
          "clusters, the CA keys come back",
          "The secret backend gives OpenBao (opt-in) its unseal key; OpenBao's data comes back from a cold volume "
          "copy",
          "Restore Thunder's volumes: users, OAuth clients, signing keys",
          "Git re-creates everything else through Argo CD",
          "Harbor's images come back from its volumes or from new builds; telemetry starts empty",
          "Object storage restores the databases (opt-in CNPG) if a workload cluster is lost too")
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
    y2 = R1 + H + 44
    d.box(c[0], R0, w, H, "external", "Renovate", ["proposes", "version bumps"])
    d.box(c[1], R0, w, H, "external", "Pull request", ["one bump", "per PR"])
    d.box(c[2], R0, w, H, "external", "CI", ["renders and", "tests everything"])
    d.box(c[3], R0, w, H, "external", "Main branch", ["reviewed,", "merged"], aka=("main",))
    d.box(c[0], R1, w, H, "mgmt", "Argo CD", ["syncs clusters", "from main"])
    d.box(c[1], R1, w, H, "workload", "Dev clusters", ["follow main", "first"], step=6)
    d.box(c[2], R1, w, H, "workload", "Prod clusters", ["follow a", "verified commit"])
    d.box(c[3], R1, w, H, "mgmt", "Cluster API", ["replaces servers", "one at a time"])
    for i in range(3):
        d.arrow([(c[i] + w, ymid(R0)), (c[i + 1], ymid(R0))], step=i + 1, badge_at=0.4)
    d.arrow([(c[3] + w / 2, R0 + H), (c[3] + w / 2, y0), (c[0] + w / 2, y0), (c[0] + w / 2, R1)], step=4)
    d.arrow([(c[0] + w, ymid(R1)), (c[1], ymid(R1))], step=5, badge_at=0.4)
    d.arrow([(c[1] + w, ymid(R1)), (c[2], ymid(R1))], step=7, badge_at=0.4)
    d.arrow([(c[0] + w / 2, R1 + H), (c[0] + w / 2, y2), (c[3] + w / 2, y2), (c[3] + w / 2, R1 + H)], step=8)
    d.require("Renovate", "Pull request", "CI", "Main branch", "Argo CD", "Dev clusters", "Prod clusters",
              "Cluster API")
    d.key("Renovate opens a pull request: a Helm chart, a k3s release, an image digest or a tool pin",
          "The pull request runs CI: every chart rendered for every installation; lint, schema, unit and contract "
          "tests on Linux (x86, arm), macOS, Windows and the devcontainers",
          "CI gates the merge: once it passes and a maintainer approves, the pull request is squash-merged into "
          "main",
          "Main is synced by Argo CD for every cluster that follows it (addonsRevision: HEAD)",
          "Argo CD syncs the dev clusters first; sync waves order each app (e.g. istiod before ztunnel)",
          "Dev clusters are verified: every Argo CD app Synced and Healthy, task status green",
          "Dev clusters' verified commit reaches the prod clusters through a second pull request that moves their "
          "addonsRevision",
          "Argo CD hands a kubernetesVersion bump to Cluster API, which replaces servers one at a time, dev before "
          "prod (3 keep quorum)")
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
