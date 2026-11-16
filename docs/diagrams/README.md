# Diagrams

Generated, animated SVGs, safe to embed in GitHub READMEs (rendered through `<img>`: no scripts, no
`foreignObject`, no external fonts, images or CSS):

```html
<img src="docs/diagrams/architecture.svg" alt="koorikla/platform architecture" width="100%">
```

| Diagram | Shows | Source of truth |
|---|---|---|
| [architecture.svg](architecture.svg) | The main picture. Repos (koorikla/platform, koorikla/ci, koorikla/hello-world, GitHub Actions, GHCR) → mgmt cluster (Argo CD, Cluster API, ESO, cert-manager, Thunder, OpenChoreo control plane, Backstage, workflow plane, Harbor, observability plane, Kyverno, Falco, argo-events; OpenBao planned) → workload clusters (OpenChoreo data plane, kgateway, Istio ambient, Cilium / flannel, Kyverno, Falco + Talon, telemetry, ESO; OBI opt-in; external-dns and east-west gateway planned) on docker / AWS / Hetzner, with the nine key flows. | [architecture.md](../architecture.md), `charts/platform/values.yaml` `addons` |
| [security.svg](security.svg) | Five rows × three trust zones: identity & trust (Thunder, GitHub Apps / OIDC, per-cluster agent CA → ESO + CRS → agent cert, cluster-gateway mTLS, OpenBao mesh CA planned), secrets (store `platform` namespace-scoped, read-only stores, store `default` on workload clusters), supply chain (koorikla/ci keyless + SBOM/SLSA/vuln → GHCR; workflow plane platform key → Harbor; Kyverno ImageValidatingPolicy, Audit dev/staging, Deny production), admission (Kyverno PSS, ValidatingAdmissionPolicy for gated bindings), runtime (Falco → falcosidekick → Talon / argo-events → falco-response). | [supply-chain.md](../supply-chain.md), [promotion.md](../promotion.md), [openchoreo.md](../openchoreo.md), [conventions.md](../conventions.md) |
| [network.svg](network.svg) | North-south (client → kgateway → HTTPRoute, opt-in waypoint), Istio ambient (Kyverno enrols `dp-*` namespaces, ztunnel HBONE, istiod), CNI fixed at birth (Cilium or flannel), CoreDNS local rewrites, cluster-agent wss + mTLS through the control-plane Gateway's TLS passthrough, collectors through the observability Gateway; east-west gateway and external-dns planned. | [networking.md](../networking.md) |
| [observability.svg](observability.svg) | OTel Collector fan-out (apps, OBI opt-in) → OpenSearch traces / Prometheus metrics, Fluent Bit logs and the k8s events collector → OpenSearch, Prometheus agent remote write, Falco escalation → argo-events, observer API → Backstage and the promotion gate; RCA / FinOps agents opt-in, agentgateway planned. | [observability.md](../observability.md) |
| [sdlc.svg](sdlc.svg) | Push → in-cluster build (WorkflowRun, rootless BuildKit, platform-key cosign → Harbor) or GitHub Actions with koorikla/ci (test, Trivy, build, Syft SBOM, cosign keyless, attest → GHCR) → image tag commit → Argo CD → Component/Workload → ComponentRelease → ReleaseBindings development → staging → production (promotion-gate checks, PR via its GitHub App, CODEOWNERS, ValidatingAdmissionPolicy) → cluster-agent → Kyverno admission on dev1 / prod1. | [build-plane.md](../build-plane.md), [promotion.md](../promotion.md) |
| [cluster-lifecycle.svg](cluster-lifecycle.svg) | Adding a cluster = one fleet file: ApplicationSet `fleet` → `charts/cluster` → CAPI Cluster → kubeconfig → ESO → Argo cluster secret (labels) → addon ApplicationSets and value layering; plus the per-cluster OpenChoreo identity (agent CA → CRS → agent cert, ClusterDataPlane, Environments). | [architecture.md](../architecture.md), [providers.md](../providers.md) |

The former overview, trust-model, delivery and runtime-security diagrams are folded into this set (architecture,
security, network, sdlc). `../images/hero.png` is the README banner, generated with Gemini's image model; it is
abstract and has no text in it.

## Conventions

- **Status** must match `main` (`charts/platform/values.yaml` catalog defaults, addon values, README "Status"):
  - **built**: solid outline. On `main` and on by default (or selected by the fleet file, like Cilium via `cni`).
    AWS and Hetzner are drawn built with "rendered only": the code exists, no cluster has been booted there.
  - **opt-in**: dashed outline + `opt-in` chip. On `main`, off by default (catalog `default: false` or a values
    switch), e.g. OBI, waypoints, the RCA / FinOps agents.
  - **planned**: dimmed, dashed, `planned` chip. Not on `main` (open PR or roadmap), e.g. OpenBao, external-dns,
    the east-west gateway, agentgateway.
  - Flows follow the same rule: solid + animated = built, dashed = opt-in, dimmed dashed = planned.
- Colour = concern: emerald GitOps & lifecycle, cyan OpenChoreo, blue networking, rose security / secrets / mTLS,
  violet registries & data stores, orange telemetry & events, slate external, amber cloud / infrastructure. Neutral
  blue-grey outlines are cluster or trust-zone boundaries.
- Arrows point from **initiator to target** (who opens the connection or does the pull) in architecture, security
  and network; in observability, SDLC and lifecycle they follow the data or release flow.
- Every diagram has a legend. The pulsing ring marks the component(s) a view is about.

## Animation

- CSS `@keyframes` in one inline `<style>` per SVG (GitHub serves repository images with a CSP that allows inline
  styles and blocks scripts; SMIL would also work but cannot honour reduced motion).
- Built flows carry a light "particle" overlay moving along the path. Flows light up one after another in the order
  of the numbered flow key, then stay faintly animated. The focus ring pulses slowly.
- `@media (prefers-reduced-motion: reduce)` stops every animation and hides the particle overlays.
- Every animated element is an overlay whose unanimated opacity is 0 (the focus ring: faint), so a static frame
  (rsvg-convert, PDF export, reduced motion) is the complete diagram.

## Light and dark themes

Each SVG paints its own opaque dark card (slate-950 with a 40 px grid and rounded corners). GitHub shows `<img>`
SVGs unchanged on both its light and dark themes, so the colours were picked once, for that card. Alternatives
rejected: `#gh-dark-mode-only` / `#gh-light-mode-only` pairs double the files and only work in GitHub Markdown (not
in IDE previews, other forges or the raw link); `prefers-color-scheme` inside the SVG follows the OS theme, not
GitHub's, so it can pick the wrong palette.

## Editing

The SVGs are generated. Do not hand-edit them; change `src/build.py` and regenerate:

```bash
python3 docs/diagrams/src/build.py                 # writes docs/diagrams/*.svg, prints issues, exit 1 if any
python3 docs/diagrams/src/build.py --png /tmp/d    # also renders static PNGs (rsvg-convert) for review
python3 docs/diagrams/src/build.py network         # one diagram
```

`src/svglib.py` is a small layout helper. It registers every box, label, chip and arrow segment and reports:

- overlapping boxes, overlapping text, text overflowing its box, status chips on text or other boxes;
- arrows crossing text, chips or unrelated boxes, and arrows whose start or end is not on a box or boundary edge;
- legends or flow keys touching a boundary, anything outside the canvas;
- required components missing (each diagram lists them with `d.require(...)`, e.g. Kyverno on mgmt and on the
  workload clusters), box labels missing from the rendered SVG;
- no `@keyframes`, an animation without keyframes, no `prefers-reduced-motion` rule, built flows without an
  animated overlay;
- anything unsafe for a README image (scripts, `foreignObject`, event handlers, external URLs, `<image>`), and SVGs
  over 150 KB.
