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
from svglib import INK2 as INK2_TXT, MUTED as MUTED_TXT, Diagram  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
README = os.path.join(OUT, "README.md")


# ------------------------------------------------------------------------------------------ layout helpers
CW4 = 160                                     # 4 columns of 160 px with 80 px gutters (room for a step badge)
COLS4 = [40 + i * (CW4 + 80) for i in range(4)]
GUT4 = [x + CW4 + 40 for x in COLS4[:3]]      # gutter centres
H = 80                                        # standard box height (title + 2 lines)
PITCH = H + 80                                # row pitch: 80 px between rows


def ymid(y, h=H):
    return y + h / 2


# ------------------------------------------------------------------------------------------ architecture
def architecture() -> Diagram:
    d = Diagram("koorikla/platform · architecture",
                "Git is the only input. The mgmt cluster turns it into clusters, addons and app releases; the "
                "workload clusters run the apps.")
    c, g, w = COLS4, GUT4, CW4
    d.box(c[1], 88, w, 56, "external", "git", ["platform + app repos"])
    R1 = 264
    R2 = R1 + PITCH
    d.zone(16, 184, 928, R2 + H + 24 - 184, "mgmt cluster", "mgmt")
    d.box(c[0], R1, w, H, "security", "Kyverno", ["admission policy", "Pod Security"])
    d.box(c[1], R1, w, H, "mgmt", "Argo CD", ["ApplicationSets", "push mode"])
    d.box(c[2], R1, w, H, "mgmt", "Cluster API", ["k3s on docker,", "AWS, Hetzner"])
    d.box(c[3], R1, w, H, "security", "secrets & PKI", ["ESO · cert-manager", "OpenBao (opt-in)"])
    d.box(c[0], R2, w, H, "data", "Harbor", ["registry · scans", "image cache"])
    d.box(c[3], R2, w, H, "mgmt", "OpenChoreo", ["control, workflow,", "observability planes"])
    ZB = R2 + H + 24
    ZT = ZB + 80
    CH = ZB + 40                               # channel between the zones: badges 3, 4, 5 sit on it
    d.zone(16, ZT, 921, 152, "workload clusters", "workload", stacked=1)
    R3 = ZT + 48
    d.box(c[0], R3, w, H, "workload", "addons", ["kgateway · Istio", "Cilium · Falco · OTel"])
    d.box(c[1], R3, w, H, "workload", "app workloads", ["dp-* namespaces"])
    d.box(c[2], R3, w, H, "security", "Kyverno", ["signed images only", "Pod Security"], name="Kyverno (workload)",
          emphasis=True)
    d.box(c[3], R3, w, H, "workload", "cluster-agent", ["OpenChoreo", "data plane"])

    xg = c[1] + w / 2
    d.arrow([(xg, 144), (xg, R1)], step=1)
    d.arrow([(c[1] + w, ymid(R1)), (c[2], ymid(R1))], step=2)
    x3 = c[2] + w - 40
    d.arrow([(x3, R1 + H), (x3, CH), (g[2], CH), (g[2], ZT)], step=3)
    x4 = c[1] + 50
    d.arrow([(x4, R1 + H), (x4, CH), (g[0], CH), (g[0], ymid(R3)), (c[0] + w, ymid(R3))], step=4)
    xa = c[3] + w / 2
    d.arrow([(xa, R2 + H), (xa, R3)], step=5, badge=(xa, CH))
    d.arrow([(c[3], ymid(R3)), (c[2] + w, ymid(R3))], step=6)
    d.arrow([(c[2], ymid(R3)), (c[1] + w, ymid(R3))], step=7)

    d.require("git", "Argo CD", "Cluster API", "secrets & PKI", "Harbor", "OpenChoreo", "Kyverno",
              "Kyverno (workload)", "cluster-agent", "app workloads")
    d.key("Argo CD syncs git: fleet files, the addon catalog, tenants",
          "Each fleet file becomes a Cluster API cluster on mgmt",
          "Cluster API creates the k3s cluster on docker, AWS or Hetzner",
          "Argo CD pushes the addons to every cluster whose labels match",
          "OpenChoreo sends app releases down the connection the cluster-agent dials out (mTLS)",
          "The agent applies them; every pod passes Kyverno admission first",
          "Kyverno admits only signed images and Pod Security baseline pods into dp-* namespaces")
    return d


# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    d = Diagram("Security · from build to runtime",
                "Four layers, each its own control: a signed supply chain, admission, runtime detection and response, "
                "and the identity, secrets and keys underneath.")
    X = [196, 468, 740]
    BW = 180
    Y = [120, 120 + PITCH, 120 + 2 * PITCH, 120 + 3 * PITCH]
    for y, label, sub in ((Y[0], "supply chain", ["every image is", "signed + attested"]),
                          (Y[1], "admission", ["only verified", "images start"]),
                          (Y[2], "runtime", ["detect, respond,", "escalate"]),
                          (Y[3], "foundations", ["identity, secrets,", "keys (trust view)"])):
        d.text(32, y + 24, label.upper(), 13, INK2_TXT, weight=700, spacing=1.0)
        for i, t in enumerate(sub):
            d.text(32, y + 46 + i * 18, t, 13, MUTED_TXT)
    d.box(X[0], Y[0], BW, H, "mgmt", "build & scan", ["BuildKit · Trivy", "SBOM · provenance"])
    d.box(X[1], Y[0], BW, H, "security", "cosign", ["platform key in-cluster", "or keyless (Fulcio)"])
    d.box(X[2], Y[0], BW, H, "data", "registry", ["Harbor · GHCR", "image + signature"])
    d.box(X[0], Y[1], BW, H, "security", "production gate", ["VAP: only Argo CD's", "gated app writes prod"])
    d.box(X[1], Y[1], BW, H, "workload", "app pods", ["OpenChoreo dp-*", "namespaces"])
    d.box(X[2], Y[1], BW, H, "security", "Kyverno", ["image verification", "+ Pod Security"], emphasis=True)
    d.box(X[0], Y[2], BW, H, "security", "Falco Talon", ["terminate or label", "the pod (dp-* only)"])
    d.box(X[1], Y[2], BW, H, "security", "Falco", ["modern eBPF", "on every node"])
    d.box(X[2], Y[2], BW, H, "mgmt", "falco-response", ["via falcosidekick", "and argo-events"])
    d.box(X[0], Y[3], BW, H, "security", "Thunder", ["OIDC: console, API,", "CLI, promotion gate"])
    d.box(X[1], Y[3], BW, H, "security", "ESO", ["one secret backend,", "scoped stores"])
    d.box(X[2], Y[3], BW, H, "security", "PKI", ["cert-manager: agent CAs", "OpenBao: mesh CA"])
    d.arrow([(X[0] + BW, ymid(Y[0])), (X[1], ymid(Y[0]))], step=1)
    d.arrow([(X[1] + BW, ymid(Y[0])), (X[2], ymid(Y[0]))], step=2)
    d.arrow([(X[2] + BW / 2, Y[0] + H), (X[2] + BW / 2, Y[1])], step=3)
    d.arrow([(X[0] + BW, ymid(Y[1])), (X[1], ymid(Y[1]))])
    d.line_label = "production bindings only"
    d.arrow([(X[2], ymid(Y[1])), (X[1] + BW, ymid(Y[1]))], step=4)
    d.arrow([(X[1] + BW / 2, Y[1] + H), (X[1] + BW / 2, Y[2])], step=5)
    d.arrow([(X[1], ymid(Y[2])), (X[0] + BW, ymid(Y[2]))], step=6)
    d.arrow([(X[1] + BW, ymid(Y[2])), (X[2], ymid(Y[2]))], step=7)
    d.require("Kyverno", "cosign", "registry", "production gate", "Falco", "Falco Talon", "falco-response", "Thunder",
              "ESO", "PKI")
    d.key("The build scans (Trivy) and writes an SBOM and SLSA provenance",
          "cosign signs and attests: platform key in-cluster, keyless (Fulcio) on GitHub",
          "Kyverno verifies signature and attestations: Deny in production, Audit in dev and staging",
          "Only verified images and Pod Security baseline pods start",
          "Falco sees every pod's syscalls (modern eBPF on each node)",
          "Falco Talon responds in place: terminate or label the pod",
          "≥ Critical escalates to mgmt: falcosidekick → argo-events → falco-response")
    return d


# ----------------------------------------------------------------------------------------------- network
def network() -> Diagram:
    d = Diagram("Network · a request in, the agents out",
                "kgateway for north-south, Istio ambient for identity and mTLS, Cilium or flannel underneath; "
                "agents and collectors dial out to mgmt.")
    C = [40, 264, 488]
    BW = 144
    WX, WW = 728, 192
    R = [264, 264 + PITCH, 264 + 2 * PITCH, 264 + 3 * PITCH]
    d.box(C[1] + BW / 2 - 100, 88, 200, 56, "external", "client", ["HTTPS to the app URL"])
    d.zone(16, 184, 632, R[3] + H + 24 - 184, "workload cluster", "workload")
    d.zone(712, 184, 224, R[2] + H + 24 - 184, "mgmt cluster", "mgmt")
    d.box(C[1], R[0], BW, H, "workload", "kgateway", ["Gateway API", "HTTPRoute"])
    d.box(C[2], R[0], BW, H, "workload", "agents", ["cluster-agent, OTel,", "Fluent Bit"])
    d.box(C[0], R[1], BW, H, "security", "Kyverno", ["enrols dp-* in", "Istio ambient"], emphasis=True,
          step=1)
    d.box(C[1], R[1], BW, H, "workload", "app pods", ["dp-* namespaces", "(waypoint: opt-in)"])
    d.box(C[0], R[2], C[2] + BW - C[0], H, "workload", "ztunnel · Istio ambient",
          ["per node · HBONE mTLS between every pod pair", "SPIFFE identity · no sidecars"])
    d.box(C[0], R[3], C[2] + BW - C[0], H, "workload", "Cilium or flannel",
          ["CNI fixed at cluster birth (fleet file cni)", "Cilium: eBPF, no kube-proxy, WireGuard"])
    d.box(WX, R[0], WW, H, "mgmt", "mgmt Gateway", ["kgateway · TLS", "passthrough :8443"])
    d.box(WX, R[1], WW, H, "mgmt", "cluster-gateway", ["checks the agent's", "client certificate"])
    d.box(WX, R[2], WW, H, "data", "observability plane", ["own Gateway →", "OpenSearch, Prometheus"])
    xc = C[1] + BW / 2
    d.arrow([(xc, 144), (xc, R[0])], step=2)
    d.arrow([(xc, R[0] + H), (xc, R[1])], step=3)
    d.arrow([(xc, R[1] + H), (xc, R[2])], step=4)
    d.arrow([(xc, R[2] + H), (xc, R[3])], step=5)
    xz = 680                                   # badge column between the zones
    d.arrow([(C[2] + BW, ymid(R[0]) - 14), (WX, ymid(R[0]) - 14)], step=6, badge=(xz, ymid(R[0]) - 14))
    d.arrow([(WX + WW / 2, R[0] + H), (WX + WW / 2, R[1])], step=7)
    d.arrow([(C[2] + BW, ymid(R[0]) + 18), (xz, ymid(R[0]) + 18), (xz, ymid(R[2])), (WX, ymid(R[2]))], step=8)
    d.require("kgateway", "Kyverno", "ztunnel · Istio ambient", "Cilium or flannel", "mgmt Gateway", "cluster-gateway",
              "agents")
    d.key("Kyverno enrols every OpenChoreo dp-* namespace in Istio ambient (before any traffic)",
          "A client calls the app URL; kgateway (Gateway API) takes it",
          "An HTTPRoute sends it to the app Service (through a waypoint if opted in)",
          "Every pod-to-pod hop rides ztunnel's HBONE mTLS with SPIFFE identities",
          "Packets travel on the CNI: Cilium (eBPF) or flannel, chosen per cluster",
          "The cluster-agent dials out to mgmt on :8443 (TLS passthrough, SNI)",
          "cluster-gateway accepts only that cluster's client certificate",
          "Collectors ship logs, metrics and traces through the observability plane's Gateway")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · every signal lands in one place",
                "Collectors on each workload cluster ship to OpenChoreo's observability plane on mgmt; one observer "
                "API serves Backstage, the promotion gate and the AI agents.")
    K, KW = 32, 192
    T, TW = 336, 120
    O, OW = 546, 140
    U, UW = 776, 144
    R = [176, 176 + 136, 176 + 2 * 136]
    m = [ymid(y) for y in R]
    d.zone(16, 128, 224, R[2] + H + 24 - 128, "workload cluster", "workload")
    d.zone(320, 128, 616, R[2] + H + 24 - 128, "mgmt · observability plane", "mgmt")
    d.box(K, R[0], KW, H, "workload", "Fluent Bit", ["container logs,", "Falco alerts included"])
    d.box(K, R[1], KW, H, "workload", "OTel Collector", ["OTLP from apps", "+ k8s events"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["cAdvisor and", "kube-state-metrics"])
    d.box(T, R[0], TW, R[1] + H - R[0], "data", "OpenSearch", ["logs · traces", "k8s events"])
    d.box(T, R[2], TW, H, "data", "Prometheus", ["metrics"])
    d.box(O, R[0], OW, R[2] + H - R[0], "mgmt", "observer API", ["one query API", "Thunder auth"])
    d.box(U, R[0], UW, H, "mgmt", "Backstage", ["logs, metrics"])
    d.box(U, R[1], UW, H, "mgmt", "promotion gate", ["alerts, error rate"])
    d.box(U, R[2], UW, H, "mgmt", "AI agents", ["RCA · FinOps"], status="optin")
    xb = 264                                   # badge column between the zones
    d.arrow([(K + KW, m[0]), (T, m[0])], step=1, badge=(xb, m[0]))
    xj = 304                                   # step 2 forks after its badge: traces/events up, metrics down
    d.arrow([(K + KW, m[1]), (xj, m[1])], step=2, head=False, badge=(xb, m[1]))
    d.arrow([(xj, m[1]), (T, m[1])], step=2, badge=False)
    d.arrow([(xj, m[1]), (xj, m[2] - 16), (T, m[2] - 16)], step=2, badge=False)
    d.junction(xj, m[1])
    d.arrow([(K + KW, m[2] + 16), (T, m[2] + 16)], step=3, badge=(xb, m[2] + 16))
    xi = 470                                   # step 4 joins before its badge: both stores feed the observer API
    mo = ymid(R[0], R[1] + H - R[0])
    d.arrow([(T + TW, mo), (xi, mo), (xi, m[1] + 30)], step=4, head=False, badge=False)
    d.arrow([(T + TW, m[2]), (xi, m[2]), (xi, m[1] + 30)], step=4, head=False, badge=False)
    d.arrow([(xi, m[1] + 30), (O, m[1] + 30)], step=4)
    d.junction(xi, m[1] + 30)
    xo = 744                                   # step 5 forks after its badge to the three consumers
    d.arrow([(O + OW, m[1]), (xo, m[1])], step=5, head=False)
    d.arrow([(xo, m[1]), (U, m[1])], step=5, badge=False)
    d.arrow([(xo, m[1]), (xo, m[0]), (U, m[0])], step=5, badge=False)
    d.arrow([(xo, m[1]), (xo, m[2]), (U, m[2])], step=5, badge=False)
    d.junction(xo, m[1])
    d.require("OTel Collector", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "observer API",
              "Backstage", "promotion gate", "AI agents")
    d.key("Fluent Bit tails container logs, Falco alerts included, into OpenSearch",
          "Apps send OTLP to the OTel Collector on their node: traces and k8s events to OpenSearch, metrics to "
          "Prometheus",
          "The Prometheus agent scrapes cAdvisor and kube-state-metrics and remote-writes",
          "Both stores feed the observer API, one query API behind Thunder auth",
          "It serves Backstage, the promotion gate and the opt-in AI agents")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image, promoted through environments by pull requests; production is gated twice, "
                "at promotion and at admission.")
    c, g, w = COLS4, GUT4, CW4
    R = [112, 112 + PITCH, 112 + 2 * PITCH]
    d.box(c[0], R[0], w, H, "external", "app repo", ["code + deploy/", "koorikla/hello-world"])
    d.box(c[1], R[0], c[2] + w - c[1], H, "mgmt", "build & sign",
          ["OpenChoreo workflow plane (or GitHub Actions)", "Trivy · SBOM · SLSA · cosign"])
    d.box(c[3], R[0], w, H, "data", "registry", ["Harbor · GHCR", "signed image"])
    d.box(c[0], R[1], w, H, "mgmt", "Argo CD", ["tenant AppProject", "per app repo"])
    d.box(c[1], R[1], w, H, "mgmt", "release", ["ComponentRelease:", "immutable snapshot"])
    d.box(c[2], R[1], w, H, "mgmt", "promotion gate", ["checks each edge,", "opens the PR"])
    d.box(c[3], R[1], w, H, "security", "production gate", ["VAP: only Argo CD", "writes production"])
    d.box(c[0], R[2], w, H, "workload", "development", ["auto-deploy"])
    d.box(c[1], R[2], w, H, "workload", "staging", ["promotion PR"])
    d.box(c[2], R[2], w, H, "workload", "production", ["gated PR", "+ CODEOWNERS"])
    d.box(c[3], R[2], w, H, "security", "Kyverno", ["denies unsigned or", "unpinned images"],
          name="Kyverno (production)", emphasis=True)
    d.arrow([(c[0] + w, R[0] + 22), (c[1], R[0] + 22)], step=1)
    d.arrow([(c[2] + w, ymid(R[0])), (c[3], ymid(R[0]))], step=2)
    d.arrow([(c[1], R[0] + 58), (c[0] + w, R[0] + 58)], step=3)
    d.arrow([(c[0] + w / 2, R[0] + H), (c[0] + w / 2, R[1])], step=4)
    d.arrow([(c[0] + w, ymid(R[1])), (c[1], ymid(R[1]))], step=5)
    ch = R[1] + H + 40
    d.arrow([(c[1] + 50, R[1] + H), (c[1] + 50, ch), (c[0] + w / 2, ch), (c[0] + w / 2, R[2])], step=6)
    d.arrow([(c[0] + w, ymid(R[2])), (c[1], ymid(R[2]))], step=7)
    d.arrow([(c[1] + w, ymid(R[2])), (c[2], ymid(R[2]))], step=8)
    d.arrow([(c[2] + w, ymid(R[2])), (c[3], ymid(R[2]))], step=9)
    gy = ch + 18                               # the promotion gate sits on edges 7 and 8 (lines end at their badges)
    d.arrow([(c[2] + 40, R[1] + H), (c[2] + 40, gy), (g[0], gy), (g[0], ymid(R[2]) - 15)], loose=True)
    d.arrow([(g[1], gy), (g[1], ymid(R[2]) - 15)], loose=True)
    d.junction(g[1], gy, flow=False)
    d.arrow([(c[3] + w / 2, R[1] + H), (c[3] + w / 2, gy), (c[2] + w - 30, gy), (c[2] + w - 30, R[2])])
    d.line_label = "gate: on an edge, or on production writes"
    d.require("app repo", "build & sign", "registry", "Argo CD", "release", "promotion gate",
              "production gate", "development", "staging", "production", "Kyverno (production)")
    d.key("A push to main starts a build on the OpenChoreo workflow plane (or GitHub Actions)",
          "The build scans, writes SBOM + SLSA provenance, signs with cosign and pushes",
          "It commits the new image ref to deploy/ in the app repo",
          "Argo CD syncs the app's Component and Workload into OpenChoreo",
          "OpenChoreo snapshots them as an immutable ComponentRelease",
          "autoDeploy binds the release to development",
          "The promotion gate checks the edge (readiness, smoke, alerts, freezes) and opens a PR for staging",
          "Production needs the gate and CODEOWNERS; a ValidatingAdmissionPolicy lets only Argo CD write it",
          "In production Kyverno denies unsigned or unpinned images (Audit in dev and staging)")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    d = Diagram("Cluster lifecycle · add, upgrade, remove = edit one file",
                "A fleet file becomes a CAPI cluster, an Argo CD cluster secret and an OpenChoreo data plane; "
                "deleting it removes all three.")
    AX, AW = 32, 160
    A, B, CW = 296, 528, 152
    WX, WW = 784, 136
    L = [280, 280 + PITCH, 280 + 2 * PITCH]
    d.box(AX, 88, 264, 56, "external", "fleet file", ["`clusters/<name>.yaml`"], step=9)
    ZB = L[2] + H + 64
    d.zone(16, 192, 688, ZB - 192, "mgmt cluster", "mgmt")
    d.zone(768, 192, 168, ZB - 192, "workload", "workload")
    d.box(AX, L[0], AW, L[2] + H - L[0], "mgmt", "Argo CD",
          ["ApplicationSet fleet", "→ cluster-<name>", "", "renders", "charts/cluster:", "Cluster, secrets,",
           "agent PKI, CRS"])
    d.box(A, L[0], CW, H, "mgmt", "Cluster API", ["ClusterClass", "k3s-<provider>"], step=10)
    d.box(WX, L[0], WW, H, "workload", "k3s nodes", ["control plane", "+ workers"])
    d.box(A, L[1], CW, H, "security", "cluster secret", ["ESO: kubeconfig", "+ fleet labels"])
    d.box(B, L[1], CW, H, "mgmt", "addon AppSets", ["select clusters", "by label"])
    d.box(WX, L[1], WW, H, "workload", "addons", ["Cilium, Istio,", "Kyverno, ESO, …"])
    d.box(A, L[2], CW, H, "security", "agent identity", ["own CA on mgmt", "cert CN=<name>"])
    d.box(B, L[2], CW, H, "mgmt", "data plane", ["ClusterDataPlane: the", "gateway trusts its CA"])
    d.box(WX, L[2], WW, H, "workload", "cluster-agent", ["OpenChoreo", "data plane"])
    xf = 182
    xz = 736                                    # badge column between the zones
    d.arrow([(xf, 144), (xf, L[0])], step=1)
    xj = 256                                    # step 2 forks after its badge: Argo CD renders all three
    d.arrow([(AX + AW, ymid(L[1])), (xj, ymid(L[1]))], step=2, head=False)
    d.arrow([(xj, ymid(L[1])), (A, ymid(L[1]))], step=2, badge=False)
    d.arrow([(xj, ymid(L[1])), (xj, ymid(L[0])), (A, ymid(L[0]))], step=2, badge=False)
    d.arrow([(xj, ymid(L[1])), (xj, ymid(L[2])), (A, ymid(L[2]))], step=2, badge=False)
    d.junction(xj, ymid(L[1]))
    d.arrow([(A + CW, ymid(L[0])), (WX, ymid(L[0]))], step=3, badge=(xz, ymid(L[0])))
    d.arrow([(A + CW / 2, L[0] + H), (A + CW / 2, L[1])], step=4)
    d.arrow([(A + CW, ymid(L[1])), (B, ymid(L[1]))], step=5)
    d.arrow([(B + CW, ymid(L[1])), (WX, ymid(L[1]))], step=6, badge=(xz, ymid(L[1])))
    yb = L[2] + H + 32
    d.arrow([(A + CW / 2, L[2] + H), (A + CW / 2, yb), (WX + WW / 2, yb), (WX + WW / 2, L[2] + H)], step=7,
            badge=((A + CW + B) / 2, yb))
    d.arrow([(WX, ymid(L[2])), (B + CW, ymid(L[2]))], step=8, badge=(xz, ymid(L[2])))
    d.require("fleet file", "Argo CD", "Cluster API", "k3s nodes", "cluster secret", "addon AppSets", "addons",
              "agent identity", "data plane", "cluster-agent")
    d.key("Add clusters/<name>.yaml: ApplicationSet fleet creates Application cluster-<name>",
          "charts/cluster renders the CAPI Cluster, its ExternalSecrets and the agent PKI on mgmt",
          "Cluster API creates the machines and installs k3s",
          "ESO turns CAPI's kubeconfig into an Argo CD cluster secret with the fleet labels",
          "Addon ApplicationSets select the cluster by its labels",
          "Argo CD pushes every selected addon to the new cluster",
          "A ClusterResourceSet delivers the agent's cert; the CA key never leaves mgmt",
          "The cluster-agent dials out; the gateway accepts only that cluster's CA",
          "Remove: delete the file; Argo CD prunes, CAPI deletes the cluster, its CA goes with it",
          "Upgrade: bump kubernetesVersion in the fleet file; CAPI replaces nodes one at a time")
    return d


# ------------------------------------------------------------------------------------ trust & certificates
def trust() -> Diagram:
    d = Diagram("Trust & certificates · who signs what, and how it renews",
                "Two chains, both rooted on mgmt: a CA per cluster for the OpenChoreo agent, and OpenBao's mesh CA "
                "per group. Private CA keys never leave mgmt.")
    C1, W1 = 32, 224
    C2, W2 = 336, 232
    WX, WW = 680, 240
    A1, A2, B1, B3 = 176, 336, 488, 648
    ZB = B3 + H + 24
    d.zone(16, 112, 568, ZB - 112, "mgmt cluster", "mgmt")
    d.zone(664, 112, 272, ZB - 112, "workload cluster <name>", "workload")
    d.text(32, 162, "OPENCHOREO AGENT IDENTITY", 13, INK2_TXT, weight=700, spacing=1.0)
    d.text(32, 466, "MESH CA", 13, INK2_TXT, weight=700, spacing=1.0)
    d.box(C1, A1, W1, H, "security", "cert-manager", ["agent CA per cluster (10y)", "client cert (1y)"], step=8)
    d.box(C2, A1, W2, H, "security", "ESO + CRS", ["cert, key and the public", "gateway CA, as a payload"],
          name="agent payload")
    d.box(WX, A1, WW, H, "workload", "cluster-agent", ["Secret cluster-agent-tls;", "Reloader restarts it"])
    d.box(C2, A2, W2, H, "mgmt", "cluster-gateway", ["accepts only the CA in", "that ClusterDataPlane"])
    d.box(C1, B1, W1, B3 + H - B1, "security", "OpenBao",
          ["group root + intermediate", "keys generated inside,", "never exported", "", "per member: JWT auth",
           "mount + PKI role"], status="optin", step=9)
    d.box(C2, B1, W2, H, "security", "ESO + CRS", ["group root + OpenBao CA", "(public certificates)"],
          name="mesh trust")
    d.box(WX, B1, WW, H, "security", "istio-csr", ["cert-manager Vault Issuer", "projected SA token (JWT)"])
    d.box(WX, B3, WW, H, "workload", "ztunnel · istiod", ["workload certs 24h,", "istiod 48h; renew at 50%"])
    xz = 624
    d.arrow([(C1 + W1, ymid(A1)), (C2, ymid(A1))], step=1)
    d.arrow([(C2 + W2, ymid(A1)), (WX, ymid(A1))], step=2, badge=(xz, ymid(A1)))
    d.arrow([(WX + WW / 2, A1 + H), (WX + WW / 2, ymid(A2)), (C2 + W2, ymid(A2))], step=3, badge=(xz, ymid(A2)))
    d.arrow([(C1 + W1, ymid(B1)), (C2, ymid(B1))], step=4, status="optin")
    d.arrow([(C2 + W2, ymid(B1)), (WX, ymid(B1))], step=5, status="optin", badge=(xz, ymid(B1)))
    d.arrow([(WX, B1 + 66), (xz, B1 + 66), (xz, ymid(B3)), (C1 + W1, ymid(B3))], step=6, status="optin",
            badge=(C2 + W2 / 2, ymid(B3)))
    d.arrow([(WX + WW / 2, B1 + H), (WX + WW / 2, B3)], step=7, status="optin")
    d.require("cert-manager", "agent payload", "cluster-agent", "cluster-gateway", "OpenBao", "mesh trust",
              "istio-csr", "ztunnel · istiod")
    d.key("cert-manager issues each cluster's agent cert (CN=<name>) from that cluster's own CA",
          "ESO and a ClusterResourceSet copy cert, key and the public gateway CA to the cluster",
          "The agent dials out with mTLS; cluster-gateway accepts only that cluster's CA",
          "OpenBao publishes each group root; its keys stay inside OpenBao",
          "ESO and a ClusterResourceSet deliver the root and OpenBao's CA to every member",
          "istio-csr logs in with a projected token (its own JWT mount) and gets certs signed by the group intermediate",
          "ztunnel and gateways get 24h workload certs, istiod 48h, renewed at half-life",
          "Rotation: certs renew 30 days before expiry; Reloader restarts the agent on the new cert",
          "Root rotation is planned: new root beside the old one, trust bundle, switch, drop (#71)")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · what is stateful, where",
                "Git rebuilds everything declarative; only the violet boxes hold state it cannot recreate. "
                "Numbers: the restore order after losing mgmt.")
    OX, OW = 32, 192
    M1, M2, MW = 336, 504, 152
    WX, WW = 768, 152
    R = [176, 176 + 136, 176 + 2 * 136, 176 + 3 * 136 + 24]
    d.zone(16, 128, 224, R[3] + H + 24 - 128, "outside", "external")
    d.zone(320, 128, 352, R[2] + H + 24 - 128, "mgmt cluster", "mgmt")
    d.zone(752, 128, 184, R[3] + H + 24 - 128, "workload", "workload")
    d.box(OX, R[0], OW, H, "security", "secret backend", ["AWS SM · Vault", "local: task secrets"], step=1)
    d.box(OX, R[2], OW, H, "external", "git", ["everything", "declarative"])
    d.box(OX, R[3], OW, H, "external", "object storage", ["S3 · GCS · Azure Blob", "WAL + base backups"])
    d.box(M1, R[0], M2 + MW - M1, H, "data", "mgmt etcd",
          ["k3s snapshot every 12 h, keeps 5", "CAPI objects, kubeconfigs, CA keys"], step=2)
    d.box(M1, R[1], MW, H, "data", "OpenBao", ["raft PVC copy", "+ unseal key"], status="optin")
    d.box(M2, R[1], MW, H, "data", "Thunder", ["users, OAuth", "clients (PVC)"], step=4)
    d.box(M1, R[2], MW, H, "mgmt", "Argo CD", ["re-applies", "everything else"])
    d.box(M2, R[2], MW, H, "data", "Harbor", ["pushed images: PVC,", "or re-run builds"])
    d.box(WX, R[0], WW, H, "workload", "workload etcd", ["rebuilt by Argo CD", "+ OpenChoreo"])
    d.box(WX, R[3], WW, H, "data", "CNPG databases", ["Barman Cloud", "plugin"], status="optin")
    xz = 280
    d.arrow([(OX + OW / 2, R[0] + H), (OX + OW / 2, ymid(R[1])), (M1, ymid(R[1]))], step=3, badge=(xz, ymid(R[1])))
    d.arrow([(OX + OW, ymid(R[2])), (M1, ymid(R[2]))], step=5, badge=(xz, ymid(R[2])))
    d.arrow([(OX + OW, ymid(R[3])), (WX, ymid(R[3]))], step=6)
    d.legend_label("data", "stateful: needs a backup")
    d.legend_label("mgmt", "mgmt: rebuilt from git")
    d.legend_label("workload", "workload: rebuilt from git")
    d.legend_label("security", "secrets: outside, backed up by the backend")
    d.require("git", "secret backend", "mgmt etcd", "OpenBao", "Thunder", "Harbor", "workload etcd",
              "CNPG databases")
    d.key("The secret backend lives outside the clusters; locally re-seed it with task secrets",
          "Restore mgmt etcd from a k3s snapshot: CAPI keeps its clusters and the CA keys come back",
          "Restore OpenBao's raft data (a cold PVC copy); it unseals with the key from the backend",
          "Restore Thunder's PVCs (users, OAuth clients, signing keys)",
          "Argo CD re-syncs everything else from git; Harbor's images come back from its PVCs or new builds, "
          "telemetry starts empty",
          "Databases restore from object storage (CNPG bootstrap.recovery)")
    return d


# -------------------------------------------------------------------------------------------- upgrade flow
def upgrade() -> Diagram:
    d = Diagram("Upgrade flow · every upgrade is a pull request",
                "Renovate proposes, CI proves, Argo CD rolls out in sync-wave order, dev before prod; "
                "Kubernetes versions roll through Cluster API.")
    c, w = COLS4, CW4
    R = [112, 112 + PITCH, 112 + 2 * PITCH]
    d.box(c[0], R[0], w, H, "external", "Renovate", ["charts, k3s, digests,", "CI tools"])
    d.box(c[1], R[0], w, H, "external", "pull request", ["one bump per PR"])
    d.box(c[2], R[0], w, H, "external", "CI", ["render, lint, tests", "4 OSes, x86 + arm"])
    d.box(c[3], R[0], w, H, "external", "main", ["review +", "squash merge"])
    d.box(c[3], R[1], w, H, "mgmt", "Argo CD", ["clusters that follow", "HEAD sync first"])
    d.box(c[2], R[1], w, H, "workload", "dev clusters", ["sync waves inside", "each app"])
    d.box(c[1], R[1], w, H, "external", "verify", ["apps Synced/Healthy", "task status"])
    d.box(c[0], R[1], w, H, "workload", "prod clusters", ["pinned", "addonsRevision"])
    d.box(c[3], R[2], w, H, "mgmt", "Cluster API", ["replaces servers", "one at a time"])
    for i in range(3):
        d.arrow([(c[i] + w, ymid(R[0])), (c[i + 1], ymid(R[0]))], step=i + 1)
    d.arrow([(c[3] + w / 2, R[0] + H), (c[3] + w / 2, R[1])], step=4)
    d.arrow([(c[3], ymid(R[1])), (c[2] + w, ymid(R[1]))], step=5)
    d.arrow([(c[3] + w / 2, R[1] + H), (c[3] + w / 2, R[2])], step=6)
    d.arrow([(c[2], ymid(R[1])), (c[1] + w, ymid(R[1]))], step=7)
    d.arrow([(c[1], ymid(R[1])), (c[0] + w, ymid(R[1]))], step=8)
    d.require("Renovate", "pull request", "CI", "main", "Argo CD", "dev clusters", "verify", "prod clusters",
              "Cluster API")
    d.key("Renovate opens a PR: a Helm chart, a k3s release, an image digest or a tool pin",
          "CI renders every chart for every installation and runs lint, kubeconform, unit and contract tests on "
          "Linux x86 and arm, macOS, Windows and the devcontainers",
          "Review, then squash merge to main",
          "Argo CD picks up main for every cluster that follows HEAD (addonsRevision)",
          "Dev clusters sync first; sync waves order each app (e.g. istiod before ztunnel)",
          "A kubernetesVersion bump goes to Cluster API instead: it replaces servers one at a time (3 keep quorum)",
          "Verify: Argo CD apps Synced/Healthy and task status",
          "Prod follows when its addonsRevision moves to the verified ref (a PR to its fleet file)")
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
