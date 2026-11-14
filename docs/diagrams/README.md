# Diagrams

Standalone SVGs (dark background baked in, no scripts, no external fonts or CSS), safe to embed in GitHub READMEs:

```html
<img src="docs/diagrams/overview.svg" alt="koorikla/platform architecture overview" width="100%">
```

| Diagram | Shows | Source of truth |
|---|---|---|
| [overview.svg](overview.svg) | Repos → mgmt cluster (Argo CD, CAPI, ESO, cert-manager, OpenChoreo planes, Harbor, Kyverno, Falco) → workload clusters dev1/prod1, with the eight key flows and the cloud providers (docker tested, aws/hetzner rendered only). | [architecture.md](../architecture.md) |
| [cluster-lifecycle.svg](cluster-lifecycle.svg) | Adding a cluster = one fleet file: ApplicationSet `fleet` → `charts/cluster` → CAPI Cluster → kubeconfig → ESO → Argo cluster secret (labels) → addon ApplicationSets and value layering; plus the per-cluster OpenChoreo identity (agent CA → CRS → agent cert, ClusterDataPlane, Environments). | [architecture.md](../architecture.md) "Adding a cluster", [providers.md](../providers.md), [openchoreo.md](../openchoreo.md) |
| [trust-model.svg](trust-model.svg) | What crosses which boundary, by concern: PKI (CA keys stay on mgmt, per-cluster agent CA, public gateway CA), secret stores and backends, SSO federation, signing identities checked by Kyverno. | [openchoreo.md](../openchoreo.md) "Trust model", [architecture.md](../architecture.md) "Secrets", [conventions.md](../conventions.md) |
| [delivery.svg](delivery.svg) | App path from `git push` to data planes (CI → image → tag commit → Argo CD tenant AppProject → Component/Workload → ComponentRelease → ReleaseBindings per environment), and the Crossplane package promotion pipeline gated by Argo CD commit statuses. | [openchoreo.md](../openchoreo.md) "Tenants", "App repo contract"; promotion and supply-chain docs (planned) |
| [runtime-security.svg](runtime-security.svg) | Security layers on every workload cluster: kgateway north-south, Istio ambient, Cilium, Kyverno admission, Falco → Talon / falcosidekick → OTel → observability plane / Datadog, escalation → Argo Events → `falco-response` workflow on mgmt. | docs/networking.md, observability docs |

`../images/hero.png` is the README banner, generated with Gemini's image model. It is abstract and has no text in it.

## Conventions

- **Solid border = built** (on `main`), **dashed border / dashed arrow = planned** (target architecture, not built
  yet). The `aws` and `hetzner` providers are drawn solid with "rendered only": the code exists but no cluster has
  been booted on them.
- Colour = concern: emerald GitOps & lifecycle, cyan OpenChoreo, blue networking, rose security / secrets / mTLS,
  violet registries & artifacts, orange telemetry & events, slate external, amber cloud / infrastructure. Neutral
  blue-grey outlines are cluster or trust-zone boundaries.
- In the overview and trust model, arrows point from **initiator to target** (who opens the connection or does the
  pull). In the lifecycle and delivery diagrams, arrows follow the data or release flow.

## Editing

The SVGs are generated. Do not hand-edit them; change `src/build.py` and regenerate:

```bash
python3 docs/diagrams/src/build.py                 # writes docs/diagrams/*.svg, prints layout issues
python3 docs/diagrams/src/build.py --png /tmp/d    # also renders PNGs (rsvg-convert) for review
python3 docs/diagrams/src/build.py delivery        # one diagram
```

`src/svglib.py` is a small layout helper. It registers every box, label and arrow segment, and it reports
overlapping boxes, overlapping text, text overflowing its box, arrows crossing text or unrelated boxes, and legends
that touch a boundary. The script exits non-zero when it finds any of these. Keep every SVG under 100 KB.
