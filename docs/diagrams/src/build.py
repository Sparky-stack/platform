#!/usr/bin/env python3
"""Generate docs/diagrams/*.svg. Usage: python3 docs/diagrams/src/build.py [--png DIR] [name ...]

Prints layout issues found by svglib.Diagram.check() (overlaps, overflow, arrows through text).
With --png DIR every SVG is also rendered with rsvg-convert at 1200px width for visual review.
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

ALL_KINDS = ["gitops", "platform", "network", "security", "data", "bus", "external", "cloud"]


# ---------------------------------------------------------------------------------------------- overview
def overview() -> Diagram:
    W, H = 1200, 920
    d = Diagram(W, H, "koorikla/platform · architecture overview",
                "mgmt runs GitOps, cluster lifecycle, secrets/PKI and the OpenChoreo planes · "
                "workload clusters run apps · dashed = planned")
    R = [140, 228, 316, 404, 492, 580, 668]
    BH = 60
    yc = lambda r: R[r] + BH / 2  # noqa: E731

    # boundaries
    d.group(16, 104, 168, 464, "git & external", "zone")
    d.group(240, 104, 464, 464, "mgmt cluster · k3d locally, any k8s", "zone")
    d.group(752, 104, 432, 652, "cloud providers · CAPI infrastructure", "cloud")
    d.group(768, 216, 392, 518, "workload clusters · dev1, prod1", "zone", stacked=1,
            sub=["k3s via CAPI · one fleet file each", "dev1: development+staging · prod1: production"])

    # left column
    LX, LW = 24, 152
    d.box(LX, R[0], LW, BH, "external", "koorikla/platform", ["fleet/addons/tenants"], sub_size=11)
    d.box(LX, R[1], LW, BH, "external", "app repos", ["e.g. hello-world"])
    d.box(LX, 308, LW, 52, "external", "GitHub Actions", ["app CI → koorikla/ci"], sub_size=11)
    d.box(LX, 420, LW, 52, "data", "GHCR", ["ghcr.io/koorikla/*"], sub_size=11)
    d.box(LX, R[4], LW, BH, "security", "Okta / Google", ["SSO identity"], planned=True)

    # mgmt
    L, Rx, CW, WW = 256, 480, 208, 432
    d.box(L, R[0], CW, BH, "security", "ESO · cert-manager", ["secret stores · CAs"])
    d.box(Rx, R[0], CW, BH, "gitops", "Cluster API", ["k3s · CAPD · CAPA · CAPH"])
    d.box(L, R[1], WW, BH, "gitops", "Argo CD + ApplicationSets",
          ["push mode · AppSets: fleet, addon catalog, tenants"])
    d.box(L, R[2], WW, BH, "platform", "OpenChoreo control plane",
          ["Thunder · API · controllers · Backstage · gateway"])
    d.box(L, R[3], CW, BH, "platform", "OC workflow plane", ["Argo Workflows"], planned=True)
    d.box(Rx, R[3], CW, BH, "platform", "OC observability", ["logs · metrics · traces"], planned=True)
    d.box(L, R[4], CW, BH, "security", "Kyverno · Falco", ["admission · detection"], planned=True)
    d.box(Rx, R[4], CW, BH, "data", "Harbor", ["pull-through cache"], planned=True)

    # providers strip (top of the cloud region) + workload chips
    for i, (t, s) in enumerate([("docker · CAPD", ("tested", "#6ee7b7")), ("aws · CAPA", "rendered only"),
                                ("hetzner · CAPH", "rendered only")]):
        d.box(768 + i * 136, R[0], 120, BH, "cloud", t, [s], title_size=12.5)
    A, B, KW = 784, 974, 174
    d.box(A, R[2], KW, BH, "platform", "OC data plane", ["cluster-agent"])
    d.box(B, R[2], KW, BH, "network", "kgateway", ["north-south ingress"])
    d.box(A, R[3], KW, BH, "bus", "OTel collector", ["fan-out · Datadog"], planned=True)
    d.box(B, R[3], KW, BH, "network", "Cilium", ["CNI · no kube-proxy"], planned=True)
    d.box(A, R[4], KW, BH, "security", "Falco + Talon", ["detect · respond"], planned=True)
    d.box(B, R[4], KW, BH, "network", "Istio ambient", ["ztunnel · waypoints"], planned=True)
    d.box(A, R[5], KW, BH, "security", "ESO", ["store: default"])
    d.box(B, R[5], KW, BH, "gitops", "Crossplane v2", ["providers · XRs"], planned=True)
    d.box(A, R[6], B + KW - A, BH, "platform", "app workloads",
          ["OpenChoreo cell namespaces per project / env"])

    # flows (arrow = initiator -> target)
    d.arrow([(L, yc(1)), (184, yc(1))], EM, badge=1, badge_pos=(222, yc(1)), aid="git")
    d.arrow([(198, yc(1)), (198, yc(0)), (184, yc(0))], EM, aid="git-p")
    d.arrow([(L + WW, yc(1)), (768, yc(1))], EM, badge=2, badge_pos=(728, yc(1)), aid="push")
    d.arrow([(Rx + CW, yc(0)), (768, yc(0))], EM, badge=3, badge_pos=(728, yc(0)), aid="capi")
    d.arrow([(A, yc(2)), (L + WW, yc(2))], RO, badge=4, badge_pos=(728, yc(2)), aid="agent")
    d.arrow([(A, yc(3)), (Rx + CW, yc(3))], OR, planned=True, badge=5, badge_pos=(728, yc(3)), aid="otel")
    d.arrow([(A, yc(6)), (728, yc(6)), (728, yc(4)), (Rx + CW, yc(4))], VI, planned=True,
            badge=6, badge_pos=(728, 610), aid="pull")
    d.arrow([(100, 360), (100, 420)], VI, badge=7, badge_pos=(100, 390), aid="ci")
    d.arrow([(L, R[2] + 44), (212, R[2] + 44), (212, yc(4)), (176, yc(4))], RO, planned=True,
            badge=8, badge_pos=(212, 440), aid="sso")

    # legend (free space under git/mgmt, outside every boundary) + flow key
    d.legend(28, 612, ALL_KINDS, cols=4, col_w=172)
    e1 = [(1, "Argo CD pulls git: platform (fleet, addons, tenants) + app repos"),
          (2, "Argo CD pushes addons via each cluster's CAPI kubeconfig"),
          (3, "CAPI creates/upgrades clusters on docker / aws / hetzner"),
          (4, "OpenChoreo cluster-agent dials out: wss + mTLS, per-cluster CA")]
    e2 = [(5, "OTel collector ships logs/metrics/traces to obs plane (+ Datadog)"),
          (6, "workloads pull via Harbor, proxy cache of GHCR (today: direct)"),
          (7, "app CI pushes images to GHCR (koorikla/ci + signing: planned)"),
          (8, "Thunder federates console/API login to Okta / Google")]
    d.flowkey(28, 800, e1, [EM, EM, EM, RO], title="Flows · arrow = initiator → target, colour = concern")
    d.flowkey(612, 800, e2, [OR, VI, VI, RO], title=None, planned=(5, 6, 8))
    return d


# ------------------------------------------------------------------------------------- cluster lifecycle
def cluster_lifecycle() -> Diagram:
    W, H = 1200, 910
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
    d.legend(28, 840, ["external", "gitops", "security", "platform", "cloud"], planned=False, cols=5, col_w=228,
             flows=[("GitOps / CAPI", EM, False), ("certs & mTLS", RO, False),
                    ("OpenChoreo reference", CY, False)])
    return d


# ------------------------------------------------------------------------------------------- trust model
def trust_model() -> Diagram:
    W, H = 1200, 1200
    d = Diagram(W, H, "Trust model · what crosses which boundary",
                "rows = concern, columns = trust zone · gutter labels name exactly what crosses · "
                "arrow = initiator → target")
    EXZ, MZ, WZ = (16, 240), (400, 360), (920, 264)
    for x, label in ((EXZ[0], "external"), (MZ[0], "mgmt cluster · trust root"), (WZ[0], "workload cluster <name>")):
        d.text(x + 14, 112, label, 12.5, "#e2e8f0", weight=700)
    bands = [(124, 230), (370, 230), (622, 154), (798, 254)]
    for y, h in bands:
        for zx, zw in (EXZ, MZ, WZ):
            d.group(zx, y, zw, h, "", "zone")
    MX, MW, WX, WW, EX, EW = 416, 328, 936, 232, 32, 208
    GL, GR = 328, 840  # gutter label centres

    # --- PKI
    d.text(32, 150, "PKI · agent identity", 12.5, RO, weight=700)
    for i, t in enumerate(["CA private keys never", "leave mgmt. One CA per", "cluster: delete the", "fleet file = revoke."]):
        d.text(32, 178 + i * 18, t, 11.5, "#cbd5e1")
    d.box(MX, 162, MW, 52, "security", "agent CA · one per cluster", ["fleet/<name>-agent-ca · key stays"])
    d.box(MX, 226, MW, 52, "security", "gateway CA", ["server cert of cluster-gateway · key stays"])
    d.box(MX, 290, MW, 52, "platform", "cluster-gateway", ["client CA = that cluster's agent CA"])
    d.box(WX, 162, WW, 52, "security", "cluster-agent-tls", ["own cert + key, CA cert"])
    d.box(WX, 226, WW, 52, "security", "cluster-gateway-ca", ["ConfigMap · public cert"])
    d.box(WX, 290, WW, 52, "platform", "cluster-agent", ["verifies gateway CA"])
    d.arrow([(MX + MW, 188), (WX, 188)], RO, label="cert + key (CRS)", label_pos=(GR, 192), aid="crs1")
    d.arrow([(MX + MW, 252), (WX, 252)], RO, label="public cert (CRS)", label_pos=(GR, 256), aid="crs2")
    d.arrow([(WX, 316), (MX + MW, 316)], RO, label="wss + mTLS (out)", label_pos=(GR, 320), aid="wss")

    # --- secrets
    d.text(32, 390, "secrets", 12.5, RO, weight=700)
    d.group(24, 400, 224, 190, "secret backend", "zone", label_size=11.5)
    d.box(36, 432, 200, 44, "external", "kubernetes (mgmt ns)", ["local stand-in"], title_size=12.5, sub_size=11)
    d.box(36, 482, 200, 44, "cloud", "AWS Secrets Manager", ["rendered only"], title_size=12.5, sub_size=11)
    d.box(36, 532, 200, 44, "cloud", "Vault / OpenBao", ["rendered only"], title_size=12.5, sub_size=11)
    d.box(MX, 400, MW, 64, "security", "ClusterSecretStore platform",
          ["platform-github, platform-ghcr,", "capi-aws, capi-hetzner, openchoreo"])
    d.box(MX, 478, MW, 64, "security", "mgmt-fleet · mgmt-openchoreo",
          ["read-only in-cluster stores:", "kubeconfigs, agent certs, ca.crt"])
    d.box(WX, 400, WW, 64, "security", "ClusterSecretStore default", ["OpenChoreo app secrets", "same backend, scoped"])
    d.arrow([(MX, 412), (248, 412)], RO, label="reads flat keys", label_pos=(GL, 416), aid="sp")
    d.arrow([(WX + WW / 2, 464), (WX + WW / 2, 611), (136, 611), (136, 590)], RO,
            label="reads app secrets directly (not via mgmt)", label_pos=(580, 615), aid="sd")

    # --- SSO
    d.text(32, 640, "SSO · human identity", 12.5, RO, weight=700)
    d.box(EX, 652, EW, 112, "security", "Okta / Google", ["workforce IdP"], planned=True)
    d.box(MX, 650, MW, 52, "security", "Thunder", ["OpenChoreo IdP · console, API, CLI"])
    d.box(MX, 712, MW, 52, "gitops", "Argo CD SSO", ["OIDC via Dex"], planned=True)
    d.box(WX, 650, WW, 52, "security", "kube-apiserver OIDC", ["k3s --oidc-issuer-url"], planned=True)
    d.arrow([(MX, 676), (EX + EW, 676)], RO, planned=True, label="OIDC federation", label_pos=(GL, 680), aid="fed")
    d.arrow([(MX, 738), (EX + EW, 738)], RO, planned=True, label="OIDC (Dex)", label_pos=(GL, 742), aid="dex")
    d.arrow([(WX, 676), (MX + MW, 676)], RO, planned=True, label="trusts issuer", label_pos=(GR, 680), aid="k3s")

    # --- supply chain
    d.text(32, 816, "supply chain · signing", 12.5, RO, weight=700)
    d.box(EX, 826, EW, 60, "external", "GitHub Actions", ["keyless: Fulcio + Rekor", "koorikla/ci @ main"],
          planned=True)
    d.box(EX, 918, EW, 64, "data", "GHCR", ["ghcr.io/koorikla/*", "images (+ sigs, planned)"])
    d.box(EX, 994, EW, 48, "external", "GitHub App", ["Backstage scaffolder"], planned=True)
    d.box(MX, 826, MW, 60, "platform", "OC workflow plane",
          ["cosign sign with platform key", "(cosign-platform via ESO)"], planned=True)
    d.box(MX, 918, MW, 44, "data", "Harbor · apps", ["cosign content trust"], planned=True)
    d.box(MX, 994, MW, 48, "platform", "Backstage scaffolder", ["new app repo + platform PR"], planned=True)
    d.box(WX, 826, WW, 136, "security", "Kyverno verifyImages",
          ["ghcr.io/koorikla/*:", "keyless, issuer GitHub,", "subject …@refs/heads/main", "harbor apps/*:",
           "platform public key", "Audit mode"], planned=True)
    d.arrow([(136, 886), (136, 918)], VI, planned=True, label="sign + attest", label_pos=(146, 907),
            label_anchor="start", aid="sign")
    d.arrow([(580, 886), (580, 918)], VI, planned=True, label="push", label_pos=(590, 907), label_anchor="start",
            aid="push")
    d.arrow([(WX, 940), (MX + MW, 940)], RO, planned=True, label="verify platform key", label_pos=(GR, 944),
            aid="vk")
    d.arrow([(WX + WW / 2, 826), (WX + WW / 2, 787), (248, 787), (248, 950), (EX + EW, 950)], RO, planned=True,
            label="verify keyless sig directly (not via mgmt)", label_pos=(580, 791), aid="vg")
    d.arrow([(MX, 1018), (EX + EW, 1018)], RO, planned=True, label="App token (ESO)", label_pos=(GL, 1022),
            aid="app")

    d.legend(28, 1102, ["external", "gitops", "security", "platform", "data", "cloud"], cols=6, col_w=190,
             flows=[("certs, secrets, mTLS", RO, False), ("artifact", VI, False)])
    return d


# ---------------------------------------------------------------------------------------------- delivery
def delivery() -> Diagram:
    W, H = 1200, 1000
    d = Diagram(W, H, "Delivery · from git push to data planes",
                "apps: CI → signed image → tag commit → Argo CD → OpenChoreo releases per environment · "
                "platform packages: gated PRs per env ring")
    d.group(16, 84, 1168, 452, "1 · app delivery (GitOps + OpenChoreo)", "zone")
    d.group(16, 560, 1168, 302, "2 · Crossplane package promotion", "zone")

    # row 1: build
    d.box(32, 120, 180, 64, "external", "git push", ["app repo, e.g.", "koorikla/hello-world"])
    d.box(252, 120, 230, 64, "external", "GitHub Actions", ["test · build · push", "(koorikla/ci: planned)"])
    d.box(252, 204, 230, 64, "platform", "OC workflow plane", ["same koorikla/ci scripts", "buildkit · Argo Workflows"],
          planned=True)
    d.box(522, 120, 230, 64, "data", "GHCR", ["ghcr.io/koorikla/<app>", "sign + attest: planned"])
    d.box(522, 204, 230, 64, "data", "Harbor · apps", ["cosign: platform key", "Trivy scan on push"], planned=True)
    d.box(792, 120, 200, 148, "external", "bot commit",
          ["by CI or workflow:", "deploy/openchoreo/", "workload.yaml", "image: <new tag>", "[skip ci]"])
    d.arrow([(212, 152), (252, 152)], SL)
    d.arrow([(212, 172), (232, 172), (232, 236), (252, 236)], SL, planned=True)
    d.arrow([(482, 152), (522, 152)], VI)
    d.arrow([(482, 236), (522, 236)], VI, planned=True)
    d.arrow([(367, 120), (367, 106), (892, 106), (892, 120)], SL, label="commit new image tag",
            label_pos=(630, 110), aid="tag")
    d.arrow([(892, 268), (892, 284), (122, 284), (122, 300)], EM,
            label="Argo CD syncs deploy/openchoreo/ (tenant AppProject)", label_pos=(507, 288), aid="sync")

    # row 2: deploy
    d.box(32, 300, 180, 92, "gitops", "Argo CD", ["App <project>-<app>", "AppProject", "tenant-<project>"])
    d.box(252, 300, 230, 92, "platform", "Component + Workload", ["org ns default (mgmt)", "autoDeploy: true",
                                                                 "project demo"])
    d.box(522, 300, 230, 92, "platform", "ComponentRelease", ["immutable snapshot:", "Workload + type +", "traits"])
    envs = [("development", "ReleaseBinding · auto"), ("staging", "ReleaseBinding · PR"),
            ("production", "ReleaseBinding · PR")]
    EY = [300, 380, 460]
    for (t, sub), y in zip(envs, EY):
        d.box(792, y, 200, 52, "platform", t, [sub])
    d.box(1032, 300, 144, 132, "cloud", "dev1", ["cluster-agent", "applies:", "development,", "staging"])
    d.box(1032, 460, 144, 52, "cloud", "prod1", ["agent: production"])
    d.arrow([(212, 346), (252, 346)], EM)
    d.arrow([(482, 346), (522, 346)], CY)
    d.arrow([(752, 326), (792, 326)], CY)
    d.arrow([(892, 352), (892, 380)], CY, label="promote = PR", label_pos=(902, 371), label_anchor="start",
            aid="p1")
    d.arrow([(892, 432), (892, 460)], CY, label="PR + review", label_pos=(902, 451), label_anchor="start",
            aid="p2")
    d.arrow([(992, 326), (1032, 326)], CY)
    d.arrow([(992, 406), (1032, 406)], CY)
    d.arrow([(992, 486), (1032, 486)], CY)
    d.text(32, 424, "a ReleaseBinding PR sets spec.releaseName to the ComponentRelease running in the previous",
           11.5, "#cbd5e1")
    d.text(32, 442, "environment · releases reach data planes only through the OpenChoreo cluster-agent "
           "(never Argo CD)", 11.5, "#cbd5e1")

    # lane 2: crossplane packages
    d.box(32, 600, 180, 64, "external", "package repos", ["configurations,", "providers (xpkg)"])
    d.box(252, 600, 230, 64, "external", "koorikla/ci", ["crossplane-*.yaml: xpkg", "build · push · cosign"],
          planned=True)
    d.box(522, 600, 230, 212, "gitops", "promote.yaml",
          ["repository_dispatch", "package-released →", "PR to development;", "gate ✓ → next env;",
           "order = OpenChoreo", "DeploymentPipeline"], planned=True)
    PY = [600, 680, 760]
    for (t, sub), y in zip([("env-development.yaml", "PR 1 · on release"),
                            ("env-staging.yaml", "PR 2 · after gate ✓"),
                            ("env-production.yaml", "PR 3 · gate ✓ + review")], PY):
        d.box(792, y, 200, 52, "gitops", t, [sub], planned=True)
    d.box(1032, 600, 144, 212, "gitops", "Argo CD",
          ["syncs crossplane-", "packages-<cluster>", "", "Notifications →", "commit status", "argocd/<app>"],
          planned=True)
    d.arrow([(212, 632), (252, 632)], EM, planned=True)
    d.arrow([(482, 632), (522, 632)], EM, planned=True)
    for y in PY:
        d.arrow([(752, y + 26), (792, y + 26)], EM, planned=True)
        d.arrow([(992, y + 26), (1032, y + 26)], EM, planned=True)
    d.arrow([(1104, 812), (1104, 838), (637, 838), (637, 812)], EM, planned=True,
            label="gate: same version healthy on every env-N cluster", label_pos=(870, 842), aid="gate")
    for i, t in enumerate(["Cluster-scoped packages (Provider,", "Function, Configuration) promote",
                           "here, per env ring. App-level XRs", "(OpenChoreo resource types) promote",
                           "with the app release in lane 1."]):
        d.text(40, 704 + i * 19, t, 11.5, "#cbd5e1")

    d.legend(28, 902, ["external", "gitops", "platform", "data", "cloud"], cols=5, col_w=228, zone=False,
             flows=[("git trigger", SL, False), ("artifact", VI, False), ("GitOps", EM, False),
                    ("OpenChoreo", CY, False)])
    return d


# -------------------------------------------------------------------------------------- runtime security
def runtime_security() -> Diagram:
    W, H = 1200, 890
    d = Diagram(W, H, "Runtime security · layers on every workload cluster",
                "datapath (kgateway, Istio ambient, Cilium) · admission (Kyverno) · detection and response "
                "(Falco, Talon) · escalation to mgmt")
    CA, CW, CB, WIDE = 176, 256, 468, 548
    R = [180, 268, 356, 444, 532, 620]
    BH = 60
    yc = lambda r: R[r] + BH / 2  # noqa: E731

    d.box(CA, 84, CW, 48, "external", "client", ["HTTP to the app URL"])
    d.group(16, 148, 724, 552, "workload cluster · dev1, prod1", "zone")
    d.group(840, 408, 344, 292, "mgmt cluster", "zone")

    tags = [("north-south", BL), ("mesh · L4/L7", BL), ("CNI · L3/L4", BL), ("admission", RO), ("detection", RO),
            ("response", RO)]
    for (t, c), y in zip(tags, R):
        d.text(32, y + 35, t, 12, c, weight=700)

    d.box(CA, R[0], CW, BH, "network", "kgateway", ["Gateway API · OpenChoreo", "gateway :19080"])
    d.box(CB, R[0], CW, BH, "platform", "app pods", ["cell namespace", "ambient-enrolled"])
    d.box(CA, R[1], WIDE, BH, "network", "Istio ambient",
          ["ztunnel per node: L4 mTLS, SPIFFE identity", "waypoint per namespace: L7 authz (optional)"], planned=True)
    d.box(CA, R[2], WIDE, BH, "network", "Cilium",
          ["eBPF CNI · kube-proxy replacement", "NetworkPolicy · Hubble flow visibility"], planned=True)
    d.box(CA, R[3], CW, BH, "external", "kube-apiserver", ["pod create / update"])
    d.box(CB, R[3], CW, BH, "security", "Kyverno", ["admission webhook:", "PSS + verifyImages, Audit"],
          planned=True)
    d.box(CA, R[4], CW, BH, "security", "Falco", ["eBPF syscall rules", "e.g. crypto-miner"], planned=True)
    d.box(CB, R[4], CW, BH, "bus", "falcosidekick", ["alert fan-out"], planned=True)
    d.box(CA, R[5], CW, BH, "security", "Falco Talon", ["kill crypto-miner pod,", "label, isolate (netpol)"],
          planned=True)
    d.box(CB, R[5], CW, BH, "bus", "OTel collector", ["workload telemetry +", "alerts → exporters"],
          planned=True)

    # mgmt side
    d.box(856, 444, 312, BH, "platform", "workflow falco-response",
          ["enrich pod / owner / ns →", "SRE agent → notify"], planned=True)
    d.box(856, 532, 312, BH, "bus", "Argo Events", ["webhook EventSource +", "Sensor: priority ≥ Critical"],
          planned=True)
    d.box(856, 620, 312, BH, "data", "OC observability plane", ["logs · metrics · traces", "Backstage + MCP read it"],
          planned=True)
    d.box(856, 724, 312, 52, "external", "Datadog", ["opt-in exporter (planned)"], planned=True)
    d.box(840, 148, 344, 248, "note", "division of labour",
          ["Cilium: packets, policy, Hubble", "Istio ambient: identity + mTLS", "kgateway: north-south only",
           "Kyverno: admission (Audit first)", "Falco detects · Talon responds", "OBI (opt-in): the one L7",
           "RED source; Hubble L7 off"], align="start")

    # flows
    d.arrow([(CA + CW / 2, 132), (CA + CW / 2, R[0])], BL)
    d.arrow([(CA + CW, yc(0)), (CB, yc(0))], BL)
    d.arrow([(CA + CW, yc(3)), (CB, yc(3))], RO, planned=True)
    d.arrow([(CA + CW, yc(4)), (CB, yc(4))], RO, planned=True)
    d.text(CA, R[2] + BH + 18, "every pod-to-pod hop: ztunnel mTLS (HBONE) over the Cilium eBPF datapath", 11.5,
           "#93c5fd")
    d.arrow([(CB + 64, R[4] + BH), (CB + 64, R[4] + BH + 14), (CA + CW / 2, R[4] + BH + 14),
             (CA + CW / 2, R[5])], RO, planned=True)
    d.arrow([(CB + 192, R[4] + BH), (CB + 192, R[5])], OR, planned=True)
    d.arrow([(CB + CW, yc(4)), (856, yc(4))], OR, planned=True, label="webhook", label_pos=(790, yc(4) + 4),
            aid="esc")
    d.arrow([(856 + 156, R[4]), (856 + 156, R[3] + BH)], OR, planned=True)
    d.arrow([(CB + CW, yc(5) - 10), (856, yc(5) - 10)], OR, planned=True, label="OTLP",
            label_pos=(790, yc(5) - 6), aid="otlp")
    d.arrow([(CB + CW, yc(5) + 14), (800, yc(5) + 14), (800, 750), (856, 750)], OR, planned=True,
            label="OTLP (opt-in)", label_pos=(800, 716), aid="dd")

    d.legend(28, 808, ["external", "network", "platform", "security", "bus", "data"], cols=6, col_w=190,
             labels={"external": "client / k8s core", "data": "telemetry store"},
             flows=[("traffic", BL, False), ("admission / response", RO, False), ("telemetry, events", OR, False)])
    return d


DIAGRAMS = {
    "overview": overview,
    "cluster-lifecycle": cluster_lifecycle,
    "trust-model": trust_model,
    "delivery": delivery,
    "runtime-security": runtime_security,
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
        print(f"{n}.svg  {size / 1024:.1f} KB  issues: {len(issues)}")
        for s in issues:
            print("   -", s)
        bad += len(issues)
        if png_dir:
            os.makedirs(png_dir, exist_ok=True)
            subprocess.run(["rsvg-convert", "-w", "1200", "-o", os.path.join(png_dir, f"{n}.png"), path],
                           check=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
