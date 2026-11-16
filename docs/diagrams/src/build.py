#!/usr/bin/env python3
"""Generate docs/diagrams/*.svg. Usage: python3 docs/diagrams/src/build.py [--png DIR] [name ...]

Prints the issues found by svglib.Diagram.check(): overlaps, text overflow, arrows through text or boxes, arrows not
anchored on a box, missing required components, missing animation / reduced-motion rules, size over budget.
Exits non-zero when there is any. With --png DIR every SVG is also rendered with rsvg-convert (static frame) for
visual review.

Status on every diagram must match main: built = on main and on by default (or selected by the fleet file, like
Cilium), opt-in = on main but off by default (catalog `default: false` or a values switch), planned = not on main
(open PR or roadmap). Source of truth: charts/platform/values.yaml `addons`, the addon values, README "Status".
"""
from __future__ import annotations

import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
from svglib import KINDS, Diagram  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

EM = KINDS["gitops"][2]
CY = KINDS["platform"][2]
BL = KINDS["network"][2]
RO = KINDS["security"][2]
VI = KINDS["data"][2]
OR = KINDS["bus"][2]
SL = KINDS["external"][2]
AM = KINDS["cloud"][2]
NOTE = "#cbd5e1"

ALL_KINDS = ["gitops", "platform", "network", "security", "data", "bus", "external", "cloud"]


# ------------------------------------------------------------------------------------------ architecture
def architecture() -> Diagram:
    W, H = 1320, 990
    d = Diagram(W, H, "koorikla/platform · architecture",
                "mgmt runs GitOps, cluster lifecycle, secrets/PKI, policy and the OpenChoreo planes · "
                "workload clusters run apps · every box is an addon from one catalog")
    Y = [140 + 74 * i for i in range(8)]
    BH = 58
    yc = lambda r: Y[r] + BH / 2  # noqa: E731

    # boundaries
    d.group(16, 104, 200, 406, "git & GitHub", "zone")
    d.group(240, 104, 568, 478, "mgmt cluster · k3d locally, any k8s", "zone")
    d.group(840, 104, 464, 716, "cloud providers · CAPI infrastructure", "cloud")
    d.group(856, 140, 432, 592, "workload clusters · dev1, prod1", "zone", stacked=1,
            sub=["k3s via Cluster API · one fleet file each", "dev1: development + staging · prod1: production"])

    # git & GitHub
    LX, LW = 40, 164
    d.box(LX, Y[0], LW, BH, "external", "koorikla/platform", ["fleet · addons ·", "tenants"])
    d.box(LX, Y[1], LW, BH, "external", "koorikla/hello-world", ["example app repo", "deploy/openchoreo/"],
          title_size=12)
    d.box(LX, Y[2], LW, BH, "external", "koorikla/ci", ["reusable workflows", "+ build scripts"])
    d.box(LX, Y[3], LW, BH, "external", "GitHub Actions", ["test · scan · build", "sign keyless"])
    d.box(LX, Y[4], LW, BH, "data", "GHCR", ["ghcr.io/koorikla/*", "+ SBOM · SLSA"])

    # mgmt: three columns; everything the workload clusters talk to sits in the right column
    C = [256, 440, 624]
    CW, C2 = 170, 354
    d.box(C[0], Y[0], 538, BH, "gitops", "Argo CD + ApplicationSets",
          ["push mode · fleet, addon catalog, tenants · the only Argo CD"], focus=True)
    d.box(C[0], Y[1], CW, BH, "security", "ESO", ["ClusterSecretStore", "platform (scoped)"])
    d.box(C[1], Y[1], CW, BH, "security", "cert-manager", ["agent CA per cluster", "gateway CA · keys stay"])
    d.box(C[2], Y[1], CW, BH, "gitops", "Cluster API", ["k3s · ClusterClass", "CAPD · CAPA · CAPH"])
    d.box(C[0], Y[2], CW, BH, "security", "Thunder", ["OIDC identity", "provider"])
    d.box(C[1], Y[2], C2, BH, "platform", "OpenChoreo control plane",
          ["API · controllers · cluster-gateway", "projects · components · environments"], focus=True)
    d.box(C[0], Y[3], CW, BH, "platform", "Backstage", ["developer portal", "logs · metrics"])
    d.box(C[1], Y[3], CW, BH, "platform", "OC workflow plane", ["Argo Workflows", "rootless BuildKit"])
    d.box(C[2], Y[3], CW, BH, "data", "Harbor", ["registry · caches", "Trivy on push"])
    d.box(C[0], Y[4], CW, BH, "security", "Kyverno", ["admission policy", "PSS baseline"])
    d.box(C[1], Y[4], C2, BH, "data", "OC observability plane",
          ["OpenSearch · Prometheus · observer API", "RCA + FinOps agents: opt-in, off"])
    d.box(C[0], Y[5], CW, BH, "security", "Falco", ["modern_ebpf", "+ falcosidekick"])
    d.box(C[1], Y[5], CW, BH, "security", "OpenBao", ["mesh CA · secret", "backend (PR #4)"], status="planned")
    d.box(C[2], Y[5], CW, BH, "bus", "argo-events", ["Falco escalation", "rollout events"])

    # workload clusters
    A, B, KW = 872, 1080, 192
    d.box(A, Y[2], KW, BH, "platform", "OC data plane", ["cluster-agent", "(dials out)"],
          name="OpenChoreo data plane")
    d.box(B, Y[2], KW, BH, "network", "kgateway", ["Gateway API", "north-south"])
    d.box(A, Y[3], KW, BH, "platform", "app workloads", ["dp-* cell namespaces", "per project × env"])
    d.box(B, Y[3], KW, BH, "network", "Istio ambient", ["ztunnel L4 mTLS", "waypoints: opt-in"])
    d.box(A, Y[4], KW, BH, "bus", "telemetry", ["OTel · Fluent Bit ·", "Prometheus agent"])
    d.box(B, Y[4], KW, BH, "network", "Cilium / flannel", ["CNI fixed at birth", "eBPF, no kube-proxy"])
    d.box(A, Y[5], KW, BH, "security", "Falco + Talon", ["modern_ebpf detect", "Talon: kill · label"])
    d.box(B, Y[5], KW, BH, "security", "Kyverno", ["PSS · image verify", "ambient enrolment"],
          name="Kyverno (workload)")
    d.box(A, Y[6], KW, BH, "security", "ESO", ["ClusterSecretStore", "default"], name="ESO (workload)")
    d.box(B, Y[6], KW, BH, "bus", "OBI", ["eBPF L7 RED", "metrics"], status="optin")
    d.box(A, Y[7], KW, BH, "network", "external-dns", ["Route 53 · Cloudflare", "PR #5"], status="planned")
    d.box(B, Y[7], KW, BH, "network", "east-west gateway", ["Istio multicluster", "PR #4"], status="planned")
    for i, (t, s) in enumerate([("docker · CAPD", ("tested locally", "#6ee7b7")), ("AWS · CAPA", "rendered only"),
                                ("Hetzner · CAPH", "rendered only")]):
        d.box(856 + i * 148, 752, 136, 52, "cloud", t, [s], title_size=12.5)

    d.require("Argo CD + ApplicationSets", "Cluster API", "ESO", "cert-manager", "OpenChoreo control plane",
              "Thunder", "Backstage", "OC workflow plane", "Harbor", "OC observability plane", "Kyverno", "Falco",
              "argo-events", "OpenBao", "OpenChoreo data plane", "kgateway", "Cilium / flannel", "Istio ambient",
              "Kyverno (workload)", "Falco + Talon", "telemetry", "koorikla/platform", "koorikla/ci",
              "koorikla/hello-world", "docker · CAPD", "AWS · CAPA", "Hetzner · CAPH")

    # flows (arrow = initiator -> target); badge = flow key number = animation order
    d.arrow([(C[0], yc(0)), (LX + LW, yc(0))], EM, badge=1, badge_pos=(228, yc(0)), aid="git", step=0)
    d.arrow([(C[0], yc(0) + 16), (222, yc(0) + 16), (222, yc(1)), (LX + LW, yc(1))], EM, aid="git-app", step=0)
    d.arrow([(C[0] + 538, yc(0)), (856, yc(0))], EM, badge=2, badge_pos=(825, yc(0)), aid="push", step=1)
    d.arrow([(C[2] + CW, yc(1)), (856, yc(1))], EM, badge=3, badge_pos=(825, yc(1)), aid="capi", step=2)
    d.arrow([(A, yc(2)), (C[1] + C2, yc(2))], RO, badge=4, badge_pos=(825, yc(2)), aid="agent", step=3)
    d.arrow([(A, yc(3)), (C[2] + CW, yc(3))], VI, badge=5, badge_pos=(825, yc(3)), aid="pull", step=4)
    d.arrow([(A, yc(4)), (C[1] + C2, yc(4))], OR, badge=6, badge_pos=(825, yc(4)), aid="otel", step=5)
    d.arrow([(A, yc(5)), (C[2] + CW, yc(5))], OR, badge=7, badge_pos=(825, yc(5)), aid="falco", step=6)
    d.arrow([(LX, yc(1) + 14), (28, yc(1) + 14), (28, yc(3)), (LX, yc(3))], SL, badge=8, badge_pos=(28, 330),
            aid="ci", step=7)
    d.arrow([(LX + LW / 2, Y[2] + BH), (LX + LW / 2, Y[3])], SL, aid="uses", step=7)
    d.arrow([(LX + LW / 2, Y[3] + BH), (LX + LW / 2, Y[4])], VI, aid="ghcr", step=8)
    d.arrow([(C[1] + CW, yc(3)), (C[2], yc(3))], VI, aid="build", step=8, badge=9, badge_pos=(617, yc(3)))

    # legend + flow key: free space under git & mgmt, outside every boundary
    d.legend(28, 612, ALL_KINDS, cols=4, col_w=196, focus=True)
    flows = [(1, "Argo CD pulls git: koorikla/platform (fleet, addons, tenants) + app repos (deploy/)"),
             (2, "Argo CD pushes every addon to every cluster (push mode, kubeconfig from CAPI)"),
             (3, "Cluster API creates and upgrades the k3s clusters on docker / AWS / Hetzner"),
             (4, "cluster-agent dials out to cluster-gateway: wss + mTLS, one CA per cluster"),
             (5, "nodes pull images through Harbor (registry + proxy caches)"),
             (6, "telemetry ships logs, metrics, traces and k8s events to the observability plane"),
             (7, "Falco alert ≥ Critical: falcosidekick webhook → argo-events → falco-response"),
             (8, "app CI (optional path): GitHub Actions with koorikla/ci → GHCR, cosign keyless"),
             (9, "default build path: OC workflow plane builds in-cluster → Harbor, platform key")]
    d.flowkey(28, 736, flows, [EM, EM, EM, RO, VI, OR, OR, SL, VI],
              title="Flows · arrow = initiator → target · animated in this order")
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    W, H = 1200, 940
    d = Diagram(W, H, "Adding a cluster = adding one file",
                "fleet file → CAPI cluster → Argo CD registration → addons, plus the per-cluster OpenChoreo "
                "identity · all on mgmt, ns fleet")
    # row 0: GitOps entry
    y0, h0 = 96, 56
    d.box(28, y0, 200, h0, "external", "fleet file (git)", ["clusters/<name>.yaml"])
    d.box(268, y0, 200, h0, "gitops", "ApplicationSet fleet", ["git files generator"])
    d.box(508, y0, 220, h0, "gitops", "Application", ["cluster-<name> · prune"])
    d.box(768, y0 - 4, 404, h0 + 8, "gitops", "charts/cluster (per cluster)",
          ["renders on mgmt: Cluster · ExternalSecrets ·", "agent CA/cert · CRS · ClusterDataPlane · Envs"])
    for a, b in ((228, 268), (468, 508), (728, 768)):
        d.arrow([(a, y0 + h0 / 2), (b, y0 + h0 / 2)], EM)
    d.arrow([(888, y0 + h0 + 4), (888, 184)], EM, label="into ns fleet", label_pos=(898, 178),
            label_anchor="start", aid="render")

    d.group(16, 184, 912, 476, "mgmt cluster", "zone")
    d.group(948, 184, 236, 476, "workload cluster <name>", "zone", sub="k3s · no Argo component")

    C = [32, 262, 492, 722]
    BW, BH = 190, 64
    WX, WW = 962, 208
    Y1, Y2, Y3, Y4 = 250, 354, 458, 562
    mid = lambda y: y + BH / 2  # noqa: E731

    d.text(32, Y1 - 10, "1 · lifecycle (CAPI)", 12, EM, weight=700)
    d.text(32, Y2 - 10, "2 · Argo registration", 12, EM, weight=700)
    d.text(32, Y3 - 10, "3 · OpenChoreo identity + data plane", 12, CY, weight=700)

    # lane 1
    d.box(C[0], Y1, BW, BH, "gitops", "Cluster <name>", ["topology · k3s-<provider>", "labels from fleet file"])
    d.box(C[1], Y1, BW, BH, "gitops", "CAPI controllers", ["ClusterClass k3s-<prov.>", "core · k3s · CAPD/A/H"])
    d.box(WX, Y1, WW, BH, "cloud", "k3s nodes", ["control plane + workers", "docker | aws | hetzner"])
    d.arrow([(C[0] + BW, mid(Y1)), (C[1], mid(Y1))], EM)
    d.arrow([(C[1] + BW, mid(Y1)), (WX, mid(Y1))], EM, label="creates machines, installs k3s",
            label_pos=(690, mid(Y1) + 4), aid="create")

    # lane 2
    d.box(C[0], Y2, BW, BH, "security", "<name>-kubeconfig", ["Secret · written by CAPI"])
    d.box(C[1], Y2, BW, BH, "security", "ExternalSecret", ["store mgmt-fleet", "templates the secret"])
    d.box(C[2], Y2, BW, BH, "security", "cluster secret <name>", ["ns argocd · labels:", "role, provider, env, …"])
    d.box(C[3], Y2, BW, BH, "gitops", "addon ApplicationSets", ["select on labels →", "Apps <addon>-<name>"])
    d.box(WX, Y2, WW, BH, "gitops", "addon resources", ["cilium, istio, ESO, …", "applied by Argo (push)"])
    d.arrow([(C[1] + 40, Y1 + BH), (C[1] + 40, Y2 - 22), (200, Y2 - 22), (200, Y2)], EM, label="CAPI writes",
            label_pos=(C[1] + 50, Y2 - 24), label_anchor="start", aid="kcfg")
    for i in range(3):
        d.arrow([(C[i] + BW, mid(Y2)), (C[i + 1], mid(Y2))], EM)
    d.arrow([(C[3] + BW, mid(Y2)), (WX, mid(Y2))], EM, aid="push")

    # lane 3
    d.box(C[0], Y3, BW, BH, "security", "agent CA → client cert", ["CA key stays on mgmt;", "leaf cert CN=<name>"])
    d.box(C[1], Y3, BW, BH, "security", "ExternalSecret", ["store mgmt-fleet →", "CRS payload Secret"])
    d.box(C[2], Y3, BW, BH, "gitops", "ClusterResourceSet", ["Reconcile · + shared", "openchoreo-gateway-ca"])
    d.box(WX, Y3, WW, BH, "security", "ns openchoreo-data-plane", ["Secret cluster-agent-tls", "CM cluster-gateway-ca"])
    d.box(C[0], Y4, BW, BH, "platform", "ClusterDataPlane", ["<name> · clientCA =", "<name>-agent-ca only"])
    d.box(C[1], Y4, BW, BH, "platform", "Environments", ["development, staging", "dataPlaneRef → <name>"])
    d.box(C[2], Y4, BW, BH, "platform", "cluster-gateway", ["checks client cert vs", "ClusterDataPlane CA"])
    d.box(WX, Y4, WW, BH, "platform", "cluster-agent", ["dials out · mTLS", "applies app releases"])
    d.arrow([(C[0] + BW, mid(Y3)), (C[1], mid(Y3))], RO)
    d.arrow([(C[1] + BW, mid(Y3)), (C[2], mid(Y3))], RO)
    d.arrow([(C[2] + BW, mid(Y3)), (WX, mid(Y3))], EM, label="CAPI applies payload",
            label_pos=(805, mid(Y3) + 4), aid="crs")
    d.arrow([(214, Y4), (214, Y3 + BH)], RO, label="trusts", label_pos=(222, Y4 - 14), label_anchor="start",
            aid="trust")
    d.arrow([(C[1], mid(Y4)), (C[0] + BW, mid(Y4))], CY)
    d.arrow([(WX, mid(Y4)), (C[2] + BW, mid(Y4))], RO, label="wss + mTLS (outbound)",
            label_pos=(805, mid(Y4) + 4), aid="wss")
    d.arrow([(C[2] + BW / 2, Y4 + BH), (C[2] + BW / 2, Y4 + BH + 14), (C[0] + BW / 2, Y4 + BH + 14),
             (C[0] + BW / 2, Y4 + BH)], CY, label="reads clientCA", label_pos=(C[1] + BW / 2, Y4 + BH + 18),
            aid="cdp")
    d.arrow([(WX + WW / 2, Y4), (WX + WW / 2, Y3 + BH)], RO, label="mounts",
            label_pos=(WX + WW / 2 + 8, Y4 - 14), label_anchor="start", aid="mount")

    # notes
    pad = 57
    layers = [("addons/<addon>/values.yaml", "all clusters"),
              ("addons/<addon>/values/role-<role>.yaml", "mgmt | workload"),
              ("addons/<addon>/values/provider-<provider>.yaml", "docker|aws|hetzner"),
              ("installations/<inst>/addons/<addon>/values.yaml", "installation"),
              ("installations/<inst>/addons/<addon>/env-<env>.yaml", "environment"),
              ("installations/<inst>/addons/<addon>/cluster-<name>.yaml", "this cluster")]
    d.box(16, 678, 600, 130, "note", "addon values · layered, last wins",
          [p.ljust(pad) + m for p, m in layers], align="start", sub_size=11)
    d.box(632, 678, 552, 130, "note", "contracts",
          ["name = Cluster = cluster secret = ClusterDataPlane = CN",
           "labels: fleet file → CAPI Cluster → Argo cluster secret",
           "addons-revision annotation pins a ring to a git ref",
           "delete the file → prune → cluster + its CA gone",
           "CA private keys never leave mgmt"], align="start", sub_size=11.5)
    d.legend(28, 840, ["external", "gitops", "security", "platform", "cloud"], planned=False, optin=False,
             cols=5, col_w=228,
             flows=[("GitOps / CAPI", EM, False), ("certs & mTLS", RO, False),
                    ("OpenChoreo reference", CY, False)])
    return d



# ---------------------------------------------------------------------------------------------- security
def security() -> Diagram:
    W, H = 1400, 1380
    d = Diagram(W, H, "Security · identity, secrets, supply chain, admission, runtime",
                "rows = concern, columns = trust zone · gutter labels name what crosses · arrow = initiator → target "
                "· CA private keys never leave mgmt")
    EXZ, MZ, WZ = (16, 260), (376, 480), (1016, 368)
    for x, label in ((EXZ[0], "external"), (MZ[0], "mgmt cluster · trust root"), (WZ[0], "workload cluster <name>")):
        d.text(x + 14, 98, label, 12.5, "#e2e8f0", weight=700)
    bands = [(110, 248), (370, 240), (622, 212), (846, 190), (1048, 186)]
    for y, h in bands:
        for zx, zw in (EXZ, MZ, WZ):
            d.group(zx, y, zw, h, "", "zone")
    EX, EW = 32, 228
    ML, MR, MH, MW = 392, 624, 216, 448
    WL, WR, WH, WW = 1032, 1208, 160, 336
    GL, GR = 326, 936

    # 1 · identity & trust
    d.text(32, 134, "1 · identity & trust", 12.5, RO, weight=700)
    d.box(EX, 150, EW, 52, "security", "Okta / Google", ["SSO via Thunder"], planned=True)
    d.box(EX, 214, EW, 58, "external", "GitHub Apps", ["Argo CD repo-creds (read)", "promotion gate (PRs)"])
    d.box(EX, 284, EW, 58, "external", "GitHub Actions OIDC", ["job token → Fulcio cert", "(keyless signing)"])
    d.box(ML, 150, MW, 52, "security", "Thunder", ["OIDC IdP · console, API, CLI, gate client"])
    d.box(ML, 214, MH, 58, "security", "cert-manager", ["agent CA per cluster", "gateway CA · keys stay"],
          focus=True)
    d.box(MR, 214, MH, 58, "security", "ESO + ClusterResourceSet", ["templates cert + key", "into CRS payload"],
          title_size=12)
    d.box(ML, 284, MH, 58, "security", "OpenBao", ["mesh root CA", "PR #4"], status="planned")
    d.box(MR, 284, MH, 58, "platform", "cluster-gateway", ["client CA = that", "cluster's agent CA"])
    d.box(WL, 150, WW, 52, "security", "kube-apiserver OIDC", ["trusts the Thunder issuer"], planned=True)
    d.box(WL, 214, WW, 58, "security", "cluster-agent-tls", ["own cert + key (CN = cluster)", "+ public gateway CA"])
    d.box(WL, 284, WH, 58, "platform", "cluster-agent", ["dials out", "wss + mTLS"])
    d.box(WR, 284, WH, 58, "network", "ztunnel", ["SPIFFE mTLS", "istiod CA today"])
    d.arrow([(ML, 176), (EX + EW, 176)], RO, planned=True, label="OIDC federation", label_pos=(GL, 180),
            aid="fed")
    d.arrow([(WL, 176), (ML + MW, 176)], RO, planned=True, label="trusts issuer", label_pos=(GR, 180), aid="oidc")
    d.arrow([(ML + MH, 243), (MR, 243)], RO, aid="ca", step=0)
    d.arrow([(MR + MH, 243), (WL, 243)], RO, label="cert + key (CRS)", label_pos=(GR, 247), aid="crs", step=1)
    d.arrow([(WL, 313), (MR + MH, 313)], RO, label="wss + mTLS (out)", label_pos=(GR, 317), aid="wss", step=2)
    d.arrow([(500, 342), (500, 351), (1288, 351), (1288, 342)], RO, planned=True, label="mesh intermediate CA",
            label_pos=(GR, 355), aid="mesh")

    # 2 · secrets
    d.text(32, 394, "2 · secrets", 12.5, RO, weight=700)
    d.group(24, 404, 244, 180, "secret backend", "zone", label_size=11.5)
    d.box(36, 436, 220, 44, "external", "kubernetes (mgmt ns)", ["local stand-in"], title_size=12.5, sub_size=11)
    d.box(36, 486, 220, 44, "cloud", "AWS Secrets Manager", ["rendered only"], title_size=12.5, sub_size=11)
    d.box(36, 536, 220, 44, "cloud", "Vault", ["rendered only"], title_size=12.5, sub_size=11)
    d.box(ML, 404, MW, 64, "security", "ClusterSecretStore platform",
          ["namespace-scoped (spec.conditions): argocd,", "fleet, thunder, harbor, workflows-default, …"])
    d.box(ML, 482, MW, 64, "security", "mgmt-fleet · mgmt-openchoreo · mgmt-harbor",
          ["read-only in-cluster stores: kubeconfigs,", "agent certs, public ca.crt only"], title_size=12.5)
    d.box(WL, 404, WW, 64, "security", "ClusterSecretStore default", ["app + collector secrets", "same backend, scoped"])
    d.arrow([(ML, 420), (268, 420)], RO, label="reads flat keys", label_pos=(GL, 424), aid="sp", step=3)
    d.arrow([(WL + WW / 2, 468), (WL + WW / 2, 597), (146, 597), (146, 584)], RO,
            label="reads app secrets directly (not via mgmt)", label_pos=(616, 601), aid="sd", step=3)

    # 3 · supply chain
    d.text(32, 646, "3 · supply chain", 12.5, RO, weight=700)
    d.box(EX, 660, EW, 72, "external", "GitHub Actions", ["koorikla/ci container.yaml", "Trivy · Syft SBOM · SLSA",
                                                         "cosign keyless (Fulcio)"])
    d.box(EX, 764, EW, 58, "data", "GHCR", ["image + signature +", "SBOM · SLSA · vuln"])
    d.box(ML, 660, MW, 72, "platform", "OC workflow plane",
          ["Trivy · SPDX SBOM · SLSA provenance", "cosign sign + attest: platform key", "(cosign-platform via ESO)"])
    d.box(ML, 764, MW, 58, "data", "Harbor · apps", ["signed + scanned (Trivy on push)", "registry CA public via ESO"])
    d.box(WL, 660, WW, 162, "security", "Kyverno ImageValidatingPolicy",
          ["ghcr.io/koorikla/*: keyless, the", "koorikla/ci workflow identity,", "repo + ref + trigger pinned",
           "SBOM · SLSA · vuln required", "Harbor apps/*: platform key", "dev, staging Audit · prod Deny"],
          title_size=12.5, name="Kyverno image verification", focus=True)
    d.arrow([(146, 732), (146, 764)], VI, label="sign + attest", label_pos=(156, 753), label_anchor="start",
            aid="sign", step=4)
    d.arrow([(616, 732), (616, 764)], VI, label="push", label_pos=(626, 753), label_anchor="start", aid="push",
            step=4)
    d.arrow([(WL, 793), (ML + MW, 793)], RO, label="verify platform key", label_pos=(GR, 797), aid="vk", step=5)
    d.arrow([(WL + WW / 2, 660), (WL + WW / 2, 641), (320, 641), (320, 793), (EX + EW, 793)], RO,
            label="verify keyless signature + attestations at GHCR (not via mgmt)", label_pos=(640, 645),
            aid="vg", step=5)

    # 4 · admission
    d.text(32, 870, "4 · admission", 12.5, RO, weight=700)
    for i, t in enumerate(["Pod Security baseline,", "Audit first (reports);", "restricted is the target.",
                           "Platform namespaces are", "never touched."]):
        d.text(32, 896 + i * 18, t, 11.5, NOTE)
    d.box(ML, 880, MW, 58, "security", "Kyverno", ["PSS baseline ValidatingPolicies (Audit)",
                                                  "platform namespaces excluded"])
    d.box(ML, 952, MW, 64, "security", "ValidatingAdmissionPolicy",
          ["gated ReleaseBindings (production): only", "Argo CD's gated Application may write"])
    d.box(WL, 880, WW, 44, "external", "kube-apiserver", ["pod / controller create, update"], sub_size=11)
    d.box(WL, 940, WW, 82, "security", "Kyverno", ["PSS baseline (Audit)", "trusted registries per env",
                                                  "ambient enrolment (mutate)"], name="Kyverno (workload)", focus=True)
    d.arrow([(WL + WW / 2, 924), (WL + WW / 2, 940)], RO, aid="adm", step=6)

    # 5 · runtime
    d.text(32, 1072, "5 · runtime", 12.5, RO, weight=700)
    for i, t in enumerate(["Falco detects on the node;", "Talon responds in place;", "≥ Critical escalates to",
                           "mgmt (argo-events)."]):
        d.text(32, 1098 + i * 18, t, 11.5, NOTE)
    d.box(ML, 1082, MW, 58, "data", "OC observability plane", ["Falco JSON stdout → Fluent Bit →",
                                                               "OpenSearch (alerts searchable)"])
    d.box(ML, 1160, MH, 58, "platform", "falco-response", ["enrich → Event ·", "RCA, notify: opt-in"])
    d.box(MR, 1160, MH, 58, "bus", "argo-events", ["webhook EventSource", "Sensor ≥ Critical"])
    d.box(WL, 1082, WH, 58, "security", "Falco", ["modern_ebpf", "dp-* rules"], focus=True)
    d.box(WL, 1160, WH, 58, "bus", "falcosidekick", ["alert fan-out", "falco-webhook"])
    d.box(WR, 1160, WH, 58, "security", "Falco Talon", ["terminate · label", "(scoped, dp-*)"])
    d.arrow([(WL, 1111), (ML + MW, 1111)], OR, label="logs (Fluent Bit)", label_pos=(GR, 1115), aid="flog",
            step=7)
    d.arrow([(WL + WH / 2, 1140), (WL + WH / 2, 1160)], RO, aid="fsk", step=7)
    d.arrow([(WL + WH, 1189), (WR, 1189)], RO, aid="talon", step=8)
    d.arrow([(WL, 1189), (MR + MH, 1189)], OR, label="webhook ≥ Critical", label_pos=(GR, 1193), aid="esc",
            step=8)
    d.arrow([(MR, 1189), (ML + MH, 1189)], OR, aid="wf", step=9)

    d.require("Thunder", "cert-manager", "ESO + ClusterResourceSet", "OpenBao", "GitHub Apps", "GitHub Actions OIDC",
              "ClusterSecretStore platform", "ClusterSecretStore default", "Kyverno", "Kyverno (workload)",
              "Kyverno image verification", "ValidatingAdmissionPolicy", "Falco", "falcosidekick", "Falco Talon",
              "argo-events", "falco-response", "OC workflow plane", "Harbor · apps", "GHCR")
    d.legend(28, 1264, ["external", "platform", "security", "network", "data", "bus", "cloud"], cols=6, col_w=226,
             optin=False, focus=True,
             flows=[("certs, secrets, verification", RO, False), ("artifact", VI, False),
                    ("alerts, logs", OR, False)])
    return d


DIAGRAMS = {
    "architecture": architecture,
    "security": security,
    "cluster-lifecycle": cluster_lifecycle,
}


def main(argv):
    png_dir = None
    if "--png" in argv:
        i = argv.index("--png")
        png_dir = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    names = argv or list(DIAGRAMS)
    bad = 0
    for n in names:
        d = DIAGRAMS[n]()
        path = os.path.join(OUT, f"{n}.svg")
        d.save(path)
        issues = d.check()
        size = os.path.getsize(path)
        print(f"{n}.svg  {size / 1024:.1f} KB  boxes: {len(d.titles)}  animated flows: {len(d.steps)} steps  "
              f"issues: {len(issues)}")
        for s in issues:
            print("   -", s)
        bad += len(issues)
        if png_dir:
            os.makedirs(png_dir, exist_ok=True)
            subprocess.run(["rsvg-convert", "-w", str(d.w), "-o", os.path.join(png_dir, f"{n}.png"), path],
                           check=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
