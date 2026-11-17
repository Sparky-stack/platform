# Diagrams

Generated, animated SVGs, safe to embed in GitHub READMEs (rendered through `<img>`: no scripts, no
`foreignObject`, no external fonts, images or CSS):

```html
<img src="docs/diagrams/architecture.svg" alt="koorikla/platform architecture" width="100%">
```

| Diagram | One idea | Owning doc |
|---|---|---|
| [architecture.svg](architecture.svg) | git → mgmt → workload clusters: where every part runs | [architecture.md](../architecture.md) |
| [security.svg](security.svg) | four layers: supply chain, admission, runtime, foundations | [supply-chain.md](../supply-chain.md) |
| [network.svg](network.svg) | a request in (kgateway, ambient, CNI), the agents out to mgmt | [networking.md](../networking.md) |
| [observability.svg](observability.svg) | every signal lands in the observability plane | [observability.md](../observability.md) |
| [sdlc.svg](sdlc.svg) | git push → signed image → environments → gated production | [promotion.md](../promotion.md) |
| [cluster-lifecycle.svg](cluster-lifecycle.svg) | add, upgrade, remove a cluster by editing one file | [providers.md](../providers.md) |
| [trust.svg](trust.svg) | who signs what (agent CAs, OpenBao mesh CA) and how it renews | [runbooks/certificates-and-secrets.md](../runbooks/certificates-and-secrets.md) |
| [backup.svg](backup.svg) | what is stateful where, and the restore order | [runbooks/backup-restore.md](../runbooks/backup-restore.md) |
| [upgrade.svg](upgrade.svg) | every upgrade is a PR: Renovate → CI → Argo CD → verify | [runbooks/upgrades.md](../runbooks/upgrades.md) |

`../images/hero.png` is the README banner, generated with Gemini's image model; it is abstract and has no text in it.

## Visual system

Audience: a demo for the team and management, and engineers doing day-2 operations. Surface: **Decide / Learn**:
one idea per diagram, read top-left to bottom-right, the numbered flow carries the story.

- **Canvas** 960 px wide (GitHub's README column is 1012 px, so text renders at least 1:1), an opaque dark card so the
  same file reads on GitHub's light and dark themes. Height follows the content.
- **Type**: the platform sans stack (`Segoe UI`, Helvetica Neue, Arial / Liberation Sans) for words, a mono stack
  only for identifiers such as `clusters/<name>.yaml`. README images cannot load web fonts, so the stack is chosen,
  not defaulted. Scale: title 24 bold, lede 14, zone label 13 bold tracked caps, box title 15 semibold, box detail
  13, step key 13.5, legend 13. Floor: 13 px for every text except the 11 px uppercase status chips.
- **Colour**: one accent, amber `#fbbf24`, used only for the numbered flow (arrows, badges, motion). Every other
  colour is a plane: teal mgmt cluster, sky workload cluster, rose security & trust, violet stateful data, slate git /
  GitHub / outside. Neutral grey arrows are secondary relations. Text contrast is at least 4.5:1 (checked).
- **Shapes**: boxes are components (at most 12 per diagram; zones, legend and key do not count). A second outline
  marks the focus of a view (Kyverno where admission is the point). Zones are clusters, labelled in caps.
  Dashed + `OPT-IN` chip = on `main`, off by default; dimmed + `PLANNED` chip = not on `main`.
- **Numbered steps**: an amber disc on an arrow is a step of the flow; an amber ring inside a box is a step that
  happens at that component (a restore, a rotation, a removal). Every step number appears once: a step that reaches
  several boxes forks or joins at a dot. Arrows that carry a number keep 80 px of shaft so the disc never hides the
  direction. The key under every diagram and the lists below are the same text (`build.py` fails when they differ).
  Arrows follow what moves (config, data, requests, certificates); who opens the connection is said in the step text
  where it matters ("dials out"). Grey arrows are secondary relations, named in the legend.
- **Motion** only on the numbered flow: a light particle runs along each step's arrow, in step order, then rests.
  `@media (prefers-reduced-motion: reduce)` stops it. Every animated element is an overlay with static opacity 0,
  so a static frame (rsvg-convert, PDF, reduced motion) is the complete diagram.
- **Phone**: GitHub scales the image to the screen; the step lists below are the phone-friendly text, and tapping
  the image opens it full size (at 2x zoom on a 390 px phone every box label and step is at least 10 px).
- **Legend**: generated from what the diagram uses, so it never lists a colour or style that is not on the canvas.

## Steps

The numbered flow of each diagram, word for word.

### Architecture ([architecture.svg](architecture.svg))

1. Git holds everything: fleet files, the addon catalog, teams and app repos; Argo CD syncs it
2. Argo CD hands each app's release to OpenChoreo
3. Argo CD turns each fleet file into a Cluster API cluster
4. Cluster API creates a workload cluster per fleet file, on docker, AWS or Hetzner
5. Argo CD installs the addons on every cluster whose labels match: network, mesh, policy, telemetry
6. The cluster-agent dials out to OpenChoreo (mTLS); the releases come back over that connection
7. The agent deploys the apps
8. Apps start only after Kyverno admits them: signed images, safe pod settings

### Security ([security.svg](security.svg))

1. The build scans the image (Trivy), writes an SBOM and SLSA provenance and hands the digest to cosign
2. cosign signs and attests the image and stores both next to it in the registry (Harbor or GHCR)
3. The registry serves image, signature and attestations to Kyverno at admission
4. Kyverno admits only verified images whose pods meet the Pod Security baseline: it blocks in production and only warns in dev and staging
5. App pods' system calls are watched by Falco (eBPF on every node)
6. Falco alerts Falco Talon, which stops or labels the offending pod
7. Falco escalates critical alerts to the response workflow on the management cluster (falcosidekick, argo-events)

### Network ([network.svg](network.svg))

1. A client opens the app URL; kgateway (Gateway API) takes the request
2. kgateway routes it into the service mesh (HTTPRoute; a waypoint adds L7 policy if opted in)
3. The service mesh delivers it to the app pods: ztunnel encrypts every hop with mTLS and a workload identity, no sidecars
4. The service mesh rides the cluster network: Cilium (eBPF, WireGuard) or flannel, chosen per cluster
5. Separately, the cluster-agent dials out to the management cluster on port 8443; cluster-gateway accepts only that cluster's certificate
6. The collectors (OTel Collector, Fluent Bit, Prometheus agent) dial out too and ship logs, metrics and traces to the observability plane

### Observability ([observability.svg](observability.svg))

1. Fluent Bit ships container logs, Falco security alerts included, to OpenSearch
2. The OTel Collector sends app traces and Kubernetes events to OpenSearch and app metrics to Prometheus
3. The Prometheus agent scrapes container and cluster metrics (cAdvisor, kube-state-metrics) and remote-writes them to Prometheus
4. OpenSearch and Prometheus answer the observer API: one query API behind one login (Thunder)
5. The observer API answers Backstage, the promotion gate and the opt-in AI agents

### SDLC ([sdlc.svg](sdlc.svg))

1. A push to the app repo starts a build on the OpenChoreo workflow plane (or GitHub Actions)
2. Build & sign scans the image (Trivy), writes SBOM and SLSA provenance, signs with cosign, pushes it to the registry and commits the new image ref to `deploy/`
3. The app repo's `deploy/` folder is synced by Argo CD
4. Argo CD applies it to OpenChoreo, which snapshots an immutable release (ComponentRelease)
5. The release deploys to development automatically
6. Development's health (readiness, smoke tests, alerts, freezes) is checked by the promotion gate
7. The promotion gate opens the pull request that promotes the release to staging; Argo CD applies it once merged
8. Staging is promoted to production the same way, plus CODEOWNERS approval; only Argo CD may write production
9. Production admits only signed images pinned by digest: Kyverno blocks the rest (in dev and staging it only warns)

### Cluster lifecycle ([cluster-lifecycle.svg](cluster-lifecycle.svg))

1. The fleet file `clusters/<name>.yaml` is synced by Argo CD (ApplicationSet fleet → Application `cluster-<name>`)
2. Argo CD renders `charts/cluster`: the Cluster API cluster, its secrets, the agent identity and the OpenChoreo data plane
3. Cluster API creates the machines and installs k3s
4. Cluster API's kubeconfig becomes an Argo CD cluster secret with the fleet labels (ESO)
5. The cluster secret's labels select the addon sets (ApplicationSets) that apply
6. The addon sets install every selected addon on the new cluster
7. The agent identity (its certificate) is delivered to the cluster; the CA key never leaves the management cluster
8. The cluster-agent dials out; the data plane tells the gateway to accept only this cluster's CA

Upgrade: bump `kubernetesVersion` in the fleet file; Cluster API replaces the nodes one at a time. Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.

### Trust & certificates ([trust.svg](trust.svg))

1. cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it 30 days before expiry
2. cert-manager delivers the certificate to the cluster through ESO and a ClusterResourceSet; the CA key stays on the management cluster
3. cert-manager gives cluster-gateway that cluster's CA: the only one it accepts for it
4. The cluster-agent dials out with its certificate (mTLS) and restarts by itself when the certificate renews
5. OpenBao (opt-in) creates a root and an intermediate CA per group of clusters; the keys never leave it, the public root is copied to each member
6. istio-csr (opt-in) dials out to OpenBao through cert-manager's OpenBao issuer, logs in with its service account and gets mesh certificates signed
7. istio-csr hands short-lived certificates to the mesh: 24 h for ztunnel and gateways, 48 h for istiod, renewed at half-life

### Backup & restore ([backup.svg](backup.svg))

1. The secret backend (AWS Secrets Manager, Vault) lives outside the clusters; locally, re-seed it with `task secrets`
2. Restore the management cluster's etcd from a k3s snapshot (every 12 h, 5 kept): Cluster API keeps its clusters, the CA keys come back
3. The secret backend gives OpenBao (opt-in) its unseal key; OpenBao's data comes back from a cold volume copy
4. Restore Thunder's volumes: users, OAuth clients, signing keys
5. Git re-creates everything else through Argo CD
6. Harbor's images come back from its volumes or from new builds; telemetry starts empty
7. Object storage restores the databases (opt-in CNPG) if a workload cluster is lost too

### Upgrade flow ([upgrade.svg](upgrade.svg))

1. Renovate opens a pull request: a Helm chart, a k3s release, an image digest or a tool pin
2. The pull request runs CI: every chart rendered for every installation; lint, schema, unit and contract tests on Linux (x86, arm), macOS, Windows and the devcontainers
3. CI gates the merge: once it passes and a maintainer approves, the pull request is squash-merged into main
4. Main is synced by Argo CD for every cluster that follows it (`addonsRevision: HEAD`)
5. Argo CD syncs the dev clusters first; sync waves order each app (e.g. istiod before ztunnel)
6. Dev clusters are verified: every Argo CD app Synced and Healthy, `task status` green
7. Dev clusters' verified commit reaches the prod clusters through a second pull request that moves their `addonsRevision`
8. Argo CD hands a `kubernetesVersion` bump to Cluster API, which replaces servers one at a time, dev before prod (3 keep quorum)

## Editing

The SVGs are generated. Do not hand-edit them; change `src/build.py` and regenerate:

```bash
python3 docs/diagrams/src/build.py                 # writes docs/diagrams/*.svg, prints issues, exit 1 if any
python3 docs/diagrams/src/build.py --check         # writes nothing; also fails when a committed SVG is stale
python3 docs/diagrams/src/build.py --png /tmp/d    # also renders static PNGs (rsvg-convert) for review
python3 docs/diagrams/src/build.py network         # one diagram
```

`hack/tests/test_diagrams.sh` (part of `task test`) runs `--check`, proves the output is deterministic and feeds
planted defects to the checker.

`src/svglib.py` registers every box, label, chip, badge and arrow segment and reports:

- more than 12 boxes, boxes closer than 6 px, a box across a zone border, anything outside the card;
- text overflowing its box (8 px padding, from the generator's own width estimate: Arial metrics plus a margin for
  wider fallback fonts), overlapping text, text on a box it does not belong to, text below the 13 px floor, text
  contrast below 4.5:1;
- arrows crossing text, chips, badges or unrelated boxes, arrows whose ends are not on a box or zone edge;
- badges on text, boxes or other badges; step numbers that are not 1..n, a badge without a key entry or a key entry
  without a badge; steps that differ from this README;
- required components missing (each diagram lists them with `d.require(...)`, e.g. Kyverno), box labels missing from
  the SVG;
- no `@keyframes`, an animation without keyframes, no `prefers-reduced-motion` rule, a numbered flow without an
  animated overlay;
- anything unsafe for a README image (scripts, `foreignObject`, event handlers, external URLs, `<image>`), SVGs over
  80 KB.
