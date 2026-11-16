#!/usr/bin/env python3
"""Generate docs/diagrams/*.svg.

Usage: python3 docs/diagrams/src/build.py [--check] [--out DIR] [--png DIR] [name ...]

Prints the issues found by svglib.Diagram.check() (overlaps, text overflow, arrows through text or boxes, more than
12 boxes, type floor, contrast, step numbers vs key, required components, animation and reduced-motion rules, size)
and the steps that differ from docs/diagrams/README.md. Exits non-zero when there is any.
  --check     write nothing; also fail when a committed SVG differs from what this script generates
  --out DIR   write the SVGs to DIR instead of docs/diagrams/
  --png DIR   also render every SVG with rsvg-convert (the static frame) for visual review

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
from svglib import MUTED as MUTED_TXT, Diagram  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
README = os.path.join(OUT, "README.md")


# ------------------------------------------------------------------------------------------ layout helpers
CW5 = 137                                     # 5 columns of 137 px, 48 px gutters, inside a full-width zone
COLS5 = [40 + i * (CW5 + 48) for i in range(5)]
GUT5 = [x + CW5 + 24 for x in COLS5[:4]]     # gutter centres


# ------------------------------------------------------------------------------------------ architecture
def architecture() -> Diagram:
    d = Diagram("koorikla/platform · architecture",
                "Git is the only input. The mgmt cluster turns it into clusters, addons and app releases; "
                "workload clusters run the apps.")
    c, g, w = COLS5, GUT5, CW5
    d.box(c[1], 92, w, 52, "external", "git", ["platform, apps"])
    d.zone(24, 180, 912, 264, "mgmt cluster", "mgmt")
    R1, R2, H = 228, 340, 80
    TALL = R2 + H - R1
    d.box(c[0], R1, w, TALL, "security", "Kyverno", ["admission policy", "Pod Security", "baseline", "(Audit first)"])
    d.box(c[1], R1, w, TALL, "mgmt", "Argo CD", ["ApplicationSets", "push mode", "the only Argo CD", "for all clusters"])
    d.box(c[2], R1, w, TALL, "mgmt", "Cluster API", ["k3s clusters", "one ClusterClass", "per provider:", "docker · AWS ·",
                                                     "Hetzner"])
    d.box(c[3], R1, w, H, "security", "secrets & PKI", ["ESO · OpenBao", "cert-manager"])
    d.box(c[4], R1, w, H, "data", "Harbor", ["registry · scans", "image cache"])
    d.box(c[3], R2, c[4] + w - c[3], H, "mgmt", "OpenChoreo", ["control plane · workflow plane", "observability plane"])
    ZT = 516
    d.zone(24, ZT, 905, 144, "workload clusters · dev1, prod1", "workload", stacked=1)
    R3 = ZT + 48
    d.box(c[0], R3, w, H, "workload", "network & mesh", ["kgateway · Istio", "ambient · Cilium"])
    d.box(c[1], R3, w, H, "security", "Kyverno", ["signed images", "only · PSS"], name="Kyverno (workload)",
          emphasis=True)
    d.box(c[2], R3, w, H, "workload", "app workloads", ["dp-* namespaces"])
    d.box(c[3], R3, w, H, "workload", "cluster-agent", ["OpenChoreo", "data plane"])
    d.box(c[4], R3, w, H, "workload", "Falco + OTel", ["alerts · logs", "metrics · traces"])

    CH = 480                                   # channel between the zones: every cross-zone badge sits on it
    xg = c[1] + w / 2
    d.arrow([(xg, 144), (xg, R1)], step=1, badge=(xg, 162))
    d.arrow([(c[1] + w, R1 + TALL / 2), (c[2], R1 + TALL / 2)], step=2)
    d.arrow([(c[1] + 100, R2 + H), (c[1] + 100, CH), (g[1], CH), (g[1], ZT)], step=4, badge=(c[1] + 100, CH))
    d.arrow([(c[2] + 100, R2 + H), (c[2] + 100, CH), (g[2], CH), (g[2], ZT)], step=3, badge=(c[2] + 100, CH))
    xa = c[3] + w / 2
    d.arrow([(xa, R3), (xa, R2 + H)], step=5, badge=(xa, CH))
    d.arrow([(c[3], R3 + H / 2), (c[2] + w, R3 + H / 2)], step=6)
    d.arrow([(c[1] + w, R3 + H / 2), (c[2], R3 + H / 2)], step=7)
    xt = c[4] + w / 2
    d.arrow([(xt, R3), (xt, R2 + H)], step=8, badge=(xt, CH))

    d.require("git", "Argo CD", "Cluster API", "secrets & PKI", "Harbor", "OpenChoreo", "Kyverno",
              "Kyverno (workload)", "cluster-agent", "app workloads")
    d.key("Argo CD syncs git: fleet files, the addon catalog, tenants",
          "Each fleet file becomes a Cluster API cluster on mgmt",
          "Cluster API creates the k3s cluster on docker, AWS or Hetzner",
          "Argo CD pushes the addons to every cluster whose labels match",
          "The cluster-agent dials out to OpenChoreo (mTLS) and receives app releases",
          "It applies them as app workloads in dp-* namespaces",
          "Kyverno admits only signed images and Pod Security baseline pods",
          "Logs, metrics, traces and Falco alerts flow to the observability plane")
    return d


CW4 = 180                                     # 4 columns of 180 px, 52 px gutters
COLS4 = [42 + i * (CW4 + 52) for i in range(4)]


# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    d = Diagram("Security · from build to runtime",
                "Four layers, each a separate control: signed supply chain, admission, runtime detection and "
                "response, and the identity / secrets / keys underneath.")
    X = [208, 464, 720]
    BW, H = 208, 80
    rows = [(104, "supply chain", ["every image is", "signed + attested"]),
            (240, "admission", ["only verified", "images start"]),
            (376, "runtime", ["detect, respond,", "escalate"]),
            (512, "foundations", ["identity, secrets,", "keys (trust view)"])]
    for y, label, sub in rows:
        d.zone(24, y, 912, 120, label, "external")
        for i, t in enumerate(sub):
            d.text(40, y + 52 + i * 18, t, 13, MUTED_TXT)
    Y = [y + 20 for y, *_ in rows]
    d.box(X[0], Y[0], BW, H, "mgmt", "build & scan", ["BuildKit · Trivy", "SBOM + SLSA provenance"])
    d.box(X[1], Y[0], BW, H, "security", "cosign", ["platform key (in-cluster)", "or keyless (Fulcio)"])
    d.box(X[2], Y[0], BW, H, "data", "registry", ["Harbor · GHCR", "image + signature + SBOM"])
    d.box(X[0], Y[1], BW, H, "security", "production gate", ["ValidatingAdmissionPolicy:", "only Argo CD writes prod"])
    d.box(X[1], Y[1], BW, H, "workload", "app pods", ["OpenChoreo dp-*", "namespaces"])
    d.box(X[2], Y[1], BW, H, "security", "Kyverno", ["image verification", "+ Pod Security baseline"],
          emphasis=True)
    d.box(X[0], Y[2], BW, H, "security", "Falco Talon", ["terminate or label", "the pod (dp-* only)"])
    d.box(X[1], Y[2], BW, H, "security", "Falco", ["modern eBPF", "on every node"])
    d.box(X[2], Y[2], BW, H, "mgmt", "falco-response", ["falcosidekick →", "argo-events → workflow"])
    d.box(X[0], Y[3], BW, H, "security", "Thunder", ["OIDC: console, API,", "CLI, promotion gate"])
    d.box(X[1], Y[3], BW, H, "security", "ESO", ["one secret backend,", "namespace-scoped stores"])
    d.box(X[2], Y[3], BW, H, "security", "cert-manager · OpenBao", ["per-cluster agent CAs,", "mesh CA · keys stay"])
    my = lambda r: Y[r] + H / 2  # noqa: E731
    d.arrow([(X[0] + BW, my(0)), (X[1], my(0))], step=1)
    d.arrow([(X[1] + BW, my(0)), (X[2], my(0))], step=2)
    d.arrow([(X[2] + BW / 2, Y[0] + H), (X[2] + BW / 2, Y[1])], step=3)
    d.arrow([(X[2], my(1)), (X[1] + BW, my(1))], step=4)
    d.badge(X[0], Y[1], 5, owner=(X[0], Y[1], BW, H))
    d.arrow([(X[1] + BW / 2, Y[2]), (X[1] + BW / 2, Y[1] + H)], step=6)
    d.arrow([(X[1], my(2)), (X[0] + BW, my(2))], step=7)
    d.arrow([(X[1] + BW, my(2)), (X[2], my(2))], step=8)
    d.require("Kyverno", "cosign", "registry", "production gate", "Falco", "Falco Talon", "falco-response", "Thunder",
              "ESO", "cert-manager · OpenBao")
    d.key("The build scans (Trivy) and writes an SBOM and SLSA provenance",
          "cosign signs and attests: platform key in-cluster, keyless (Fulcio) on GitHub",
          "Kyverno verifies signature and attestations: Deny in production, Audit in dev and staging",
          "Only verified images and Pod Security baseline pods start",
          "Production bindings: a ValidatingAdmissionPolicy admits only Argo CD's gated app",
          "Falco watches every node's syscalls (modern eBPF)",
          "Falco Talon responds in place: terminate or label the pod",
          "≥ Critical escalates to mgmt: falcosidekick → argo-events → falco-response")
    return d


# ----------------------------------------------------------------------------------------------- network
def network() -> Diagram:
    d = Diagram("Network · a request in, the agents out",
                "kgateway for north-south, Istio ambient for identity and mTLS, Cilium or flannel underneath; "
                "agents and collectors dial out to mgmt.")
    C = [40, 256, 472]
    BW, H = 176, 80
    WX, WW = 736, 184
    d.box(C[1], 92, BW, 52, "external", "client", ["HTTPS to the app URL"])
    d.zone(24, 176, 640, 520, "workload cluster", "workload")
    d.zone(720, 176, 216, 400, "mgmt cluster", "mgmt")
    R = [224, 340, 456, 572]
    my = lambda r: R[r] + H / 2  # noqa: E731
    d.box(C[0], R[0], BW, H, "security", "Kyverno", ["enrols dp-* namespaces", "in Istio ambient"], emphasis=True,
          step=3)
    d.box(C[1], R[0], BW, H, "workload", "kgateway", ["Gateway API", "HTTPRoute"])
    d.box(C[2], R[0], BW, H, "workload", "agent + collectors", ["cluster-agent, OTel,", "Fluent Bit · dial out"])
    d.box(C[0], R[1], BW, H, "workload", "east-west gateway", ["to peer clusters", "(mesh group)"], status="optin")
    d.box(C[1], R[1], BW, H, "workload", "app pods", ["dp-* namespaces", "ambient enrolled"])
    d.box(C[2], R[1], BW, H, "workload", "waypoint", ["per-namespace", "L7 policy"], status="optin")
    d.box(C[0], R[2], C[2] + BW - C[0], H, "workload", "ztunnel · Istio ambient",
          ["per node · HBONE mTLS between every pod pair", "SPIFFE identity · no sidecars"])
    d.box(C[0], R[3], C[2] + BW - C[0], H, "workload", "Cilium or flannel",
          ["CNI fixed at cluster birth (fleet file cni)", "Cilium: eBPF, no kube-proxy, WireGuard"])
    d.box(WX, R[0], WW, H, "mgmt", "mgmt Gateway", ["kgateway · TLS", "passthrough :8443"])
    d.box(WX, R[1], WW, H, "mgmt", "cluster-gateway", ["checks the agent's", "client cert"])
    d.box(WX, R[2], WW, H, "data", "observability", ["Gateway → OpenSearch,", "Prometheus"])
    xc = C[1] + BW / 2
    d.arrow([(xc, 144), (xc, R[0])], step=1, badge=(xc, 160))
    d.arrow([(xc, R[0] + H), (xc, R[1])], step=2)
    d.arrow([(C[2], my(1)), (C[1] + BW, my(1))], status="optin")
    d.arrow([(xc, R[1] + H), (xc, R[2])], step=4)
    d.arrow([(xc, R[2] + H), (xc, R[3])], step=5)
    d.arrow([(C[0] + 60, R[2]), (C[0] + 60, R[1] + H)], status="optin")
    d.arrow([(C[2] + BW, my(0) - 12), (WX, my(0) - 12)], step=6)
    d.arrow([(WX + WW / 2, R[0] + H), (WX + WW / 2, R[1])], step=7)
    d.arrow([(C[2] + BW, my(0) + 16), (692, my(0) + 16), (692, my(2)), (WX, my(2))], step=8, badge=(692, my(1)))
    d.require("kgateway", "Kyverno", "ztunnel · Istio ambient", "Cilium or flannel", "waypoint", "east-west gateway",
              "mgmt Gateway", "cluster-gateway", "agent + collectors")
    d.key("A client calls the app URL; kgateway (Gateway API) takes it",
          "An HTTPRoute sends it to the app Service (through a waypoint if opted in)",
          "Kyverno enrols every OpenChoreo dp-* namespace in Istio ambient",
          "Every pod-to-pod hop rides ztunnel's HBONE mTLS with SPIFFE identities",
          "Packets travel on the CNI: Cilium (eBPF) or flannel, chosen per cluster",
          "The cluster-agent dials out to mgmt on :8443 (TLS passthrough, SNI)",
          "cluster-gateway accepts only that cluster's client certificate",
          "Collectors ship logs, metrics and traces through the observability Gateway")
    return d


# ----------------------------------------------------------------------------------------- observability
def observability() -> Diagram:
    d = Diagram("Observability · every signal lands in one place",
                "Collectors on each workload cluster ship to OpenChoreo's observability plane on mgmt; the observer "
                "API serves Backstage, the promotion gate and the AI agents.")
    S, SW = 40, 120
    K, KW = 192, 168
    T, TW = 440, 130
    O, OW = 602, 124
    U, UW = 758, 162
    R = [168, 272, 376]
    H = 72
    my = lambda r: R[r] + H / 2  # noqa: E731
    d.zone(24, 120, 352, 352, "workload cluster", "workload")
    d.zone(424, 120, 512, 352, "mgmt · observability plane", "mgmt")
    d.box(S, R[0], SW, H, "workload", "app pods", ["OTLP SDK"])
    d.box(S, R[1], SW, H, "workload", "pod logs", ["stdout, incl.", "Falco alerts"])
    d.box(S, R[2], SW, H, "workload", "pod metrics", ["cAdvisor ·", "kube-state"])
    d.box(K, R[0], KW, H, "workload", "OTel Collector", ["per node", "+ k8s events"])
    d.box(K, R[1], KW, H, "workload", "Fluent Bit", ["per node", "OpenChoreo schema"])
    d.box(K, R[2], KW, H, "workload", "Prometheus agent", ["scrape, then", "remote write"])
    d.box(T, R[0], TW, R[1] + H - R[0], "data", "OpenSearch", ["logs · traces", "k8s events"])
    d.box(T, R[2], TW, H, "data", "Prometheus", ["metrics"])
    d.box(O, R[0], OW, R[2] + H - R[0], "mgmt", "observer API", ["reads every", "store", "Thunder auth"])
    d.box(U, R[0], UW, H, "mgmt", "Backstage", ["logs · metrics views"])
    d.box(U, R[1], UW, H, "mgmt", "promotion gate", ["alerts + error rate"])
    d.box(U, R[2], UW, H, "mgmt", "AI agents", ["RCA · FinOps"], status="optin")
    d.arrow([(S + SW, my(0)), (K, my(0))], step=1)
    d.arrow([(K + KW, my(0)), (T, my(0))], step=2, badge=(400, my(0)))
    d.arrow([(K + KW, my(0) + 22), (392, my(0) + 22), (392, my(2) - 14), (T, my(2) - 14)], step=2, badge=False)
    d.arrow([(S + SW, my(1)), (K, my(1))], step=3)
    d.arrow([(K + KW, my(1)), (T, my(1))], step=3, badge=False)
    d.arrow([(S + SW, my(2)), (K, my(2))], step=4)
    d.arrow([(K + KW, my(2) + 10), (T, my(2) + 10)], step=4, badge=False)
    d.arrow([(T + TW, my(0) + 52), (O, my(0) + 52)], step=5)
    d.arrow([(T + TW, my(2)), (O, my(2))], step=5, badge=False)
    for r in range(3):
        d.arrow([(O + OW, my(r)), (U, my(r))], step=6, badge=(O + OW + 16, my(r)) if r == 0 else False)
    d.require("OTel Collector", "Fluent Bit", "Prometheus agent", "OpenSearch", "Prometheus", "observer API",
              "Backstage", "promotion gate", "AI agents")
    d.key("Apps send OTLP traces and metrics to the OTel Collector on their node",
          "It ships traces and k8s events to OpenSearch, metrics to Prometheus",
          "Fluent Bit tails container logs, Falco alerts included, into OpenSearch",
          "The Prometheus agent scrapes cAdvisor and kube-state-metrics and remote-writes",
          "The observer API reads every store (Thunder auth)",
          "Backstage, the promotion gate and the opt-in AI agents query it")
    return d


# -------------------------------------------------------------------------------------------------- sdlc
def sdlc() -> Diagram:
    d = Diagram("SDLC · from git push to production",
                "One signed image, promoted through environments by pull requests; production is gated twice, "
                "at promotion and at admission.")
    c, w, H = COLS4, CW4, 80
    R = [108, 240, 372, 504]
    my = lambda r: R[r] + H / 2  # noqa: E731
    d.box(c[0], R[0], w, H, "external", "app repo", ["code + deploy/", "koorikla/hello-world"])
    d.box(c[1], R[0], c[2] + w - c[1], H, "mgmt", "build & sign",
          ["OpenChoreo workflow plane (or GitHub Actions)", "Trivy · SBOM · SLSA · cosign"])
    d.box(c[3], R[0], w, H, "data", "registry", ["Harbor · GHCR", "signed image"])
    d.box(c[0], R[1], w, H, "mgmt", "Argo CD", ["tenant AppProject", "per app repo"])
    d.box(c[1], R[1], w, H, "mgmt", "ComponentRelease", ["immutable snapshot", "of the Workload"])
    d.box(c[2], R[1], w, H, "mgmt", "promotion gate", ["readiness · smoke ·", "alerts · freezes"])
    d.box(c[3], R[1], w, H, "security", "production gate", ["VAP: only Argo CD's", "gated app writes"])
    d.box(c[1], R[2], w, H, "workload", "development", ["dev1 · auto"])
    d.box(c[2], R[2], w, H, "workload", "staging", ["dev1 · PR"])
    d.box(c[3], R[2], w, H, "workload", "production", ["prod1 · gated PR", "+ CODEOWNERS"])
    d.box(c[3], R[3], w, H, "security", "Kyverno", ["denies unsigned or", "unpinned images"], name="Kyverno (prod1)",
          emphasis=True)
    d.arrow([(c[0] + w, R[0] + 24), (c[1], R[0] + 24)], step=1)
    d.arrow([(c[2] + w, my(0)), (c[3], my(0))], step=2)
    d.arrow([(c[1], R[0] + 58), (c[0] + w, R[0] + 58)], step=3)
    d.arrow([(c[0] + w / 2, R[0] + H), (c[0] + w / 2, R[1])], step=4)
    d.arrow([(c[0] + w, my(1)), (c[1], my(1))], step=5)
    d.arrow([(c[1] + w / 2, R[1] + H), (c[1] + w / 2, R[2])], step=6)
    d.arrow([(c[1] + w, my(2)), (c[2], my(2))], step=7)
    d.arrow([(c[2] + w / 2, R[1] + H), (c[2] + w / 2, R[2])], step=7, badge=False)
    d.arrow([(c[2] + w, my(2)), (c[3], my(2))], step=8)
    d.arrow([(c[3] + w / 2, R[1] + H), (c[3] + w / 2, R[2])], step=8, badge=False)
    d.arrow([(c[3] + w / 2, R[2] + H), (c[3] + w / 2, R[3])], step=9)
    d.require("app repo", "build & sign", "registry", "Argo CD", "ComponentRelease", "promotion gate",
              "production gate", "development", "staging", "production", "Kyverno (prod1)")
    d.key("A push to main starts a build on the OpenChoreo workflow plane (or GitHub Actions)",
          "The build scans, writes SBOM + SLSA provenance, signs with cosign and pushes",
          "It commits the new image ref to deploy/ in the app repo",
          "Argo CD syncs the app's Component and Workload into OpenChoreo",
          "OpenChoreo snapshots them as an immutable ComponentRelease",
          "autoDeploy binds the release to development",
          "The promotion gate checks the edge, then opens a PR for staging",
          "Production needs the gate and CODEOWNERS; a ValidatingAdmissionPolicy lets only Argo CD write it",
          "On prod1 Kyverno denies unsigned or unpinned images")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    d = Diagram("Cluster lifecycle · add, upgrade, remove = edit one file",
                "A fleet file becomes a CAPI cluster, an Argo CD cluster secret and an OpenChoreo data plane; "
                "deleting it removes all three.")
    AX, AW = 40, 200
    A, B, CW = 280, 480, 160
    WX, WW = 728, 192
    H = 80
    L = [232, 372, 512]
    my = lambda r: L[r] + H / 2  # noqa: E731
    fleet = d.box(AX, 96, AW, 56, "external", "fleet file", ["`clusters/<name>.yaml`"], line_size=13)
    d.zone(24, 184, 632, 456, "mgmt cluster", "mgmt")
    d.zone(712, 184, 224, 456, "workload cluster", "workload")
    d.box(AX, L[0], AW, L[2] + H - L[0], "mgmt", "Argo CD",
          ["ApplicationSet fleet", "→ cluster-<name>", "", "renders charts/cluster:", "Cluster, ExternalSecrets,",
           "agent PKI, CRS"])
    capi = d.box(A, L[0], CW, H, "mgmt", "Cluster API", ["ClusterClass", "k3s-<provider>"])
    d.box(WX, L[0], WW, H, "workload", "k3s nodes", ["control plane + workers", "docker · AWS · Hetzner"])
    d.box(A, L[1], CW, H, "security", "cluster secret", ["ESO: kubeconfig", "+ fleet labels"])
    d.box(B, L[1], CW, H, "mgmt", "addon AppSets", ["select clusters", "by label"])
    d.box(WX, L[1], WW, H, "workload", "addons", ["Cilium, Istio, Kyverno,", "ESO, telemetry, …"])
    d.box(A, L[2], CW, H, "security", "agent identity", ["own CA on mgmt", "cert CN=<name>"])
    d.box(B, L[2], CW, H, "mgmt", "ClusterDataPlane", ["+ Environments", "trusts that CA"])
    d.box(WX, L[2], WW, H, "workload", "cluster-agent", ["OpenChoreo", "data plane"])
    xf = AX + 170
    d.arrow([(xf, 152), (xf, L[0])], step=1, badge=(xf, 168))
    d.arrow([(AX + AW, my(0)), (A, my(0))], step=2)
    d.arrow([(A + CW, my(0)), (WX, my(0))], step=3, badge=(684, my(0)))
    d.arrow([(A + CW / 2, L[0] + H), (A + CW / 2, L[1])], step=4)
    d.arrow([(A + CW, my(1)), (B, my(1))], step=5)
    d.arrow([(B + CW, my(1)), (WX, my(1))], step=5, badge=False)
    d.arrow([(AX + AW, my(1)), (A, my(1))])
    d.arrow([(AX + AW, my(2)), (A, my(2))])
    d.arrow([(A + CW / 2, L[2] + H), (A + CW / 2, 616), (WX + WW / 2, 616), (WX + WW / 2, L[2] + H)], step=6,
            badge=(560, 616))
    d.arrow([(WX, my(2)), (B + CW, my(2))], step=7, badge=(684, my(2)))
    d.badge(capi[0], capi[1], 8, owner=capi)
    d.badge(fleet[0], fleet[1], 9, owner=fleet)
    d.line_label = "rendered by Argo CD"
    d.require("fleet file", "Argo CD", "Cluster API", "k3s nodes", "cluster secret", "addon AppSets", "addons",
              "agent identity", "ClusterDataPlane", "cluster-agent")
    d.key("Add clusters/<name>.yaml: ApplicationSet fleet creates Application cluster-<name>",
          "charts/cluster renders the CAPI Cluster, its ExternalSecrets and the agent PKI on mgmt",
          "Cluster API creates the machines and installs k3s",
          "ESO turns CAPI's kubeconfig into an Argo CD cluster secret with the fleet labels",
          "Addon ApplicationSets select the cluster by label; Argo CD pushes the addons",
          "A ClusterResourceSet delivers the agent's cert; the CA key never leaves mgmt",
          "The cluster-agent dials out; the gateway accepts only that cluster's CA",
          "Upgrade: bump kubernetesVersion in the fleet file; CAPI replaces nodes one at a time",
          "Remove: delete the file; Argo CD prunes, CAPI deletes the cluster, its CA goes with it")
    return d


# ------------------------------------------------------------------------------------ trust & certificates
def trust() -> Diagram:
    d = Diagram("Trust & certificates · who signs what, and how it renews",
                "Two chains, both rooted on mgmt: a CA per cluster for the OpenChoreo agent, and OpenBao's mesh CA "
                "per group. Private CA keys never leave mgmt.")
    C1, W1 = 40, 240
    C2, W2 = 328, 256
    WX, WW = 672, 248
    H = 80
    A1, A2, B1, B3 = 176, 296, 444, 564
    d.zone(24, 112, 576, 560, "mgmt cluster", "mgmt")
    d.zone(656, 112, 280, 560, "workload cluster <name>", "workload")
    d.text(40, 162, "OPENCHOREO AGENT IDENTITY", 13, MUTED_TXT, weight=700, spacing=1.0)
    d.text(40, 430, "MESH CA · OPENBAO (OPT-IN)", 13, MUTED_TXT, weight=700, spacing=1.0)
    cm = d.box(C1, A1, W1, H, "security", "cert-manager", ["agent CA per cluster (10y)", "client cert CN=<name> (1y)"])
    d.box(C2, A1, W2, H, "security", "ESO + ClusterResourceSet", ["cert + key, public gateway CA", "→ cluster-agent-tls"],
          name="agent payload")
    d.box(WX, A1, WW, H, "workload", "cluster-agent", ["reads its cert at start", "dials out with mTLS"])
    d.box(C2, A2, W2, H, "mgmt", "cluster-gateway", ["accepts only the CA in", "that ClusterDataPlane"])
    bao = d.box(C1, B1, W1, B3 + H - B1, "security", "OpenBao",
                ["group root + intermediate", "keys generated inside,", "never exported", "", "per member: JWT auth",
                 "mount + PKI role"], status="optin")
    d.box(C2, B1, W2, H, "security", "ESO + ClusterResourceSet", ["group root + OpenBao CA", "(public certificates)"],
          name="mesh trust")
    d.box(WX, B1, WW, H, "security", "istio-csr", ["cert-manager Vault Issuer", "projected SA token (JWT)"])
    d.box(WX, B3, WW, H, "workload", "ztunnel · istiod", ["workload certs 24h", "istiod 48h · renew at ½"])
    my = lambda y: y + H / 2  # noqa: E731
    d.arrow([(C1 + W1, my(A1)), (C2, my(A1))], step=1)
    d.arrow([(C2 + W2, my(A1)), (WX, my(A1))], step=2)
    d.arrow([(WX + WW / 2, A1 + H), (WX + WW / 2, my(A2)), (C2 + W2, my(A2))], step=3, badge=(628, my(A2)))
    d.arrow([(C1 + W1, my(B1)), (C2, my(B1))], step=4, status="optin")
    d.arrow([(C2 + W2, my(B1)), (WX, my(B1))], step=4, status="optin", badge=False)
    d.arrow([(WX, B1 + 64), (628, B1 + 64), (628, my(B3)), (C1 + W1, my(B3))], step=5, status="optin",
            badge=(450, my(B3)))
    d.arrow([(WX + WW / 2, B1 + H), (WX + WW / 2, B3)], step=6, status="optin")
    d.badge(cm[0] + cm[2], cm[1], 7, owner=cm)
    d.badge(bao[0] + bao[2], bao[1] + 30, 8, owner=bao)
    d.require("cert-manager", "agent payload", "cluster-agent", "cluster-gateway", "OpenBao", "mesh trust",
              "istio-csr", "ztunnel · istiod")
    d.key("cert-manager issues each cluster's agent cert (CN=<name>) from that cluster's own CA",
          "ESO and a ClusterResourceSet copy cert, key and the public gateway CA to the cluster",
          "The agent dials out with mTLS; cluster-gateway accepts only that cluster's CA",
          "Public roots only: the group root and OpenBao's CA reach every member the same way",
          "istio-csr logs in with a projected token (its own JWT mount) and gets certs signed by the group intermediate",
          "ztunnel and gateways get 24h workload certs, istiod 48h, renewed at half-life",
          "Rotation: certs renew 30 days before expiry; restart the agent to load them (#50)",
          "Root rotation is planned: new root beside the old one, trust bundle, switch, drop (#71)")
    return d


# ---------------------------------------------------------------------------------------- backup & restore
def backup() -> Diagram:
    d = Diagram("Backup & restore · what is stateful, where",
                "Git rebuilds everything declarative. Only the violet boxes hold state git cannot recreate; the "
                "numbers are the restore order after losing mgmt.")
    OX, OW = 40, 192
    M1, M2, MW = 312, 488, 152
    WX, WW = 720, 200
    H = 80
    R = [168, 280, 392, 520]
    my = lambda r: R[r] + H / 2  # noqa: E731
    d.zone(24, 120, 224, 504, "outside", "external")
    d.zone(296, 120, 360, 376, "mgmt cluster", "mgmt")
    d.zone(704, 120, 232, 504, "workload clusters", "workload")
    d.box(OX, R[0], OW, H, "external", "git", ["everything declarative", "rebuild: task up + Argo CD"])
    d.box(OX, R[1], OW, H, "security", "secret backend", ["AWS SM · Vault", "local: task secrets"], step=1)
    d.box(OX, R[3], OW, H, "external", "object storage", ["S3 · GCS · Azure Blob", "WAL + base backups"])
    d.box(M1, R[0], M2 + MW - M1, H, "data", "mgmt etcd",
          ["k3s snapshot every 12 h, keeps 5", "CAPI objects, kubeconfigs, CA keys"], step=2)
    d.box(M1, R[1], MW, H, "data", "OpenBao", ["raft snapshot", "+ unseal key"], status="optin")
    d.box(M2, R[1], MW, H, "data", "Thunder", ["users, OAuth apps", "PVC (protected)"], step=4)
    d.box(M1, R[2], MW, H, "mgmt", "Harbor", ["images: rebuild", "or re-pull"])
    d.box(M2, R[2], MW, H, "mgmt", "telemetry", ["OpenSearch · Prom", "retention only"])
    d.box(WX, R[0], WW, H, "workload", "workload etcd", ["rebuilt by Argo CD", "+ OpenChoreo"])
    d.box(WX, R[3], WW, H, "data", "CNPG databases", ["Barman Cloud plugin", "(opt-in)"], status="optin")
    d.arrow([(OX + OW, my(1)), (M1, my(1))], step=3, badge=(272, my(1)))
    d.arrow([(OX + OW, my(0)), (296, my(0))], step=5, badge=(272, my(0)))
    d.arrow([(WX, my(3)), (OX + OW, my(3))], step=6, both=True)
    d.legend_label("data", "stateful: needs a backup")
    d.legend_label("mgmt", "mgmt: refills by itself")
    d.legend_label("workload", "workload: rebuilt from git")
    d.legend_label("security", "secrets: outside, backend's own backup")
    d.require("git", "secret backend", "mgmt etcd", "OpenBao", "Thunder", "Harbor", "workload etcd", "CNPG databases")
    d.key("The secret backend lives outside the clusters; locally re-seed it with task secrets",
          "Restore mgmt etcd from a k3s snapshot: CAPI keeps its clusters and the CA keys come back",
          "Restore OpenBao's raft snapshot; it unseals with the key from the backend",
          "Restore Thunder's database (users, OAuth clients)",
          "Argo CD re-syncs everything else from git; Harbor and telemetry refill",
          "Databases restore from object storage (CNPG bootstrap.recovery)")
    return d


# -------------------------------------------------------------------------------------------- upgrade flow
def upgrade() -> Diagram:
    d = Diagram("Upgrade flow · every upgrade is a pull request",
                "Renovate proposes, CI proves, Argo CD rolls out in sync-wave order, dev before prod; "
                "Kubernetes versions roll through Cluster API.")
    c, w, H = COLS4, CW4, 88
    R = [112, 252, 392]
    my = lambda r: R[r] + H / 2  # noqa: E731
    d.box(c[0], R[0], w, H, "external", "Renovate", ["charts, k3s, digests,", "CI tools"])
    d.box(c[1], R[0], w, H, "external", "pull request", ["one bump per PR"])
    d.box(c[2], R[0], w, H, "external", "CI", ["render every chart ×", "installation · tests ·", "Linux, arm, macOS, Win"])
    d.box(c[3], R[0], w, H, "external", "main", ["review +", "squash merge"])
    d.box(c[3], R[1], w, H, "mgmt", "Argo CD", ["clusters that follow", "HEAD sync first"])
    d.box(c[2], R[1], w, H, "workload", "dev clusters", ["sync waves inside", "each app"])
    d.box(c[1], R[1], w, H, "external", "verify", ["apps Synced/Healthy", "task status"])
    d.box(c[0], R[1], w, H, "workload", "prod clusters", ["pinned", "addonsRevision"])
    d.box(c[3], R[2], w, H, "mgmt", "Cluster API", ["replaces servers", "one at a time"])
    for i in range(3):
        d.arrow([(c[i] + w, my(0)), (c[i + 1], my(0))], step=i + 1)
    d.arrow([(c[3] + w / 2, R[0] + H), (c[3] + w / 2, R[1])], step=4)
    d.arrow([(c[3], my(1)), (c[2] + w, my(1))], step=5)
    d.arrow([(c[3] + w / 2, R[1] + H), (c[3] + w / 2, R[2])], step=6)
    d.arrow([(c[2], my(1)), (c[1] + w, my(1))], step=7)
    d.arrow([(c[1], my(1)), (c[0] + w, my(1))], step=8)
    d.require("Renovate", "pull request", "CI", "main", "Argo CD", "dev clusters", "verify", "prod clusters",
              "Cluster API")
    d.key("Renovate opens a PR: a Helm chart, a k3s release, an image digest or a tool pin",
          "CI renders every chart for every installation: lint, kubeconform, unit and contract tests, image audit",
          "The same suite passes on Linux x86 and arm, macOS, Windows and the devcontainers; review, squash merge",
          "Argo CD picks up main for every cluster that follows HEAD (addonsRevision)",
          "Dev clusters sync first; sync waves order each app (e.g. istiod before ztunnel)",
          "A kubernetesVersion bump makes Cluster API replace servers one at a time (3 keep quorum)",
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
    names = argv or list(DIAGRAMS)
    docs = {}
    if os.path.exists(README):
        with open(README, encoding="utf-8") as f:
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
