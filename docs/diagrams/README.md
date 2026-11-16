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
| [trust.svg](trust.svg) | who signs what (agent CAs, OpenBao mesh CA) and how it renews | [multicluster.md](../multicluster.md) |
| [backup.svg](backup.svg) | what is stateful where, and the restore order | [dev-environment.md](../dev-environment.md) |
| [upgrade.svg](upgrade.svg) | every upgrade is a PR: Renovate → CI → Argo CD → verify | [conventions.md](../conventions.md) |

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

1. Argo CD syncs git: fleet files, the addon catalog, tenants
2. Each fleet file becomes a Cluster API cluster on mgmt
3. Cluster API creates the k3s cluster on docker, AWS or Hetzner
4. Argo CD pushes the addons to every cluster whose labels match
5. OpenChoreo sends app releases down the connection the cluster-agent dials out (mTLS)
6. The agent applies them; every pod passes Kyverno admission first
7. Kyverno admits only signed images and Pod Security baseline pods into `dp-*` namespaces

### Security ([security.svg](security.svg))

1. The build scans (Trivy) and writes an SBOM and SLSA provenance
2. cosign signs and attests: platform key in-cluster, keyless (Fulcio) on GitHub
3. Kyverno verifies signature and attestations: Deny in production, Audit in dev and staging
4. Only verified images and Pod Security baseline pods start
5. Falco sees every pod's syscalls (modern eBPF on each node)
6. Falco Talon responds in place: terminate or label the pod
7. ≥ Critical escalates to mgmt: falcosidekick → argo-events → falco-response

### Network ([network.svg](network.svg))

1. Kyverno enrols every OpenChoreo `dp-*` namespace in Istio ambient (before any traffic)
2. A client calls the app URL; kgateway (Gateway API) takes it
3. An HTTPRoute sends it to the app Service (through a waypoint if opted in)
4. Every pod-to-pod hop rides ztunnel's HBONE mTLS with SPIFFE identities
5. Packets travel on the CNI: Cilium (eBPF) or flannel, chosen per cluster
6. The cluster-agent dials out to mgmt on :8443 (TLS passthrough, SNI)
7. cluster-gateway accepts only that cluster's client certificate
8. Collectors ship logs, metrics and traces through the observability plane's Gateway

### Observability ([observability.svg](observability.svg))

1. Fluent Bit tails container logs, Falco alerts included, into OpenSearch
2. Apps send OTLP to the OTel Collector on their node: traces and k8s events to OpenSearch, metrics to Prometheus
3. The Prometheus agent scrapes cAdvisor and kube-state-metrics and remote-writes
4. Both stores feed the observer API, one query API behind Thunder auth
5. It serves Backstage, the promotion gate and the opt-in AI agents

### SDLC ([sdlc.svg](sdlc.svg))

1. A push to main starts a build on the OpenChoreo workflow plane (or GitHub Actions)
2. The build scans, writes SBOM + SLSA provenance, signs with cosign and pushes
3. It commits the new image ref to `deploy/` in the app repo
4. Argo CD syncs the app's Component and Workload into OpenChoreo
5. OpenChoreo snapshots them as an immutable ComponentRelease
6. autoDeploy binds the release to development
7. The promotion gate checks the edge (readiness, smoke, alerts, freezes) and opens a PR for staging
8. Production needs the gate and CODEOWNERS; a ValidatingAdmissionPolicy lets only Argo CD write it
9. On prod1 Kyverno denies unsigned or unpinned images

### Cluster lifecycle ([cluster-lifecycle.svg](cluster-lifecycle.svg))

1. Add `clusters/<name>.yaml`: ApplicationSet fleet creates Application `cluster-<name>`
2. `charts/cluster` renders the CAPI Cluster, its ExternalSecrets and the agent PKI on mgmt
3. Cluster API creates the machines and installs k3s
4. ESO turns CAPI's kubeconfig into an Argo CD cluster secret with the fleet labels
5. Addon ApplicationSets select the cluster by its labels
6. Argo CD pushes every selected addon to the new cluster
7. A ClusterResourceSet delivers the agent's cert; the CA key never leaves mgmt
8. The cluster-agent dials out; the gateway accepts only that cluster's CA
9. Remove: delete the file; Argo CD prunes, CAPI deletes the cluster, its CA goes with it
10. Upgrade: bump `kubernetesVersion` in the fleet file; CAPI replaces nodes one at a time

### Trust & certificates ([trust.svg](trust.svg))

1. cert-manager issues each cluster's agent cert (`CN=<name>`) from that cluster's own CA
2. ESO and a ClusterResourceSet copy cert, key and the public gateway CA to the cluster
3. The agent dials out with mTLS; cluster-gateway accepts only that cluster's CA
4. OpenBao publishes each group root; its keys stay inside OpenBao
5. ESO and a ClusterResourceSet deliver the root and OpenBao's CA to every member
6. istio-csr logs in with a projected token (its own JWT mount) and gets certs signed by the group intermediate
7. ztunnel and gateways get 24h workload certs, istiod 48h, renewed at half-life
8. Rotation: certs renew 30 days before expiry; restart the agent to load them (#50)
9. Root rotation is planned: new root beside the old one, trust bundle, switch, drop (#71)

### Backup & restore ([backup.svg](backup.svg))

1. The secret backend lives outside the clusters; locally re-seed it with `task secrets`
2. Restore mgmt etcd from a k3s snapshot: CAPI keeps its clusters and the CA keys come back
3. Restore OpenBao's raft snapshot; it unseals with the key from the backend
4. Restore Thunder's database (users, OAuth clients)
5. Argo CD re-syncs everything else from git; Harbor and telemetry refill
6. Databases restore from object storage (CNPG `bootstrap.recovery`)

### Upgrade flow ([upgrade.svg](upgrade.svg))

1. Renovate opens a PR: a Helm chart, a k3s release, an image digest or a tool pin
2. CI renders every chart for every installation and runs lint, kubeconform, unit and contract tests on Linux x86 and arm, macOS, Windows and the devcontainers
3. Review, then squash merge to main
4. Argo CD picks up main for every cluster that follows HEAD (`addonsRevision`)
5. Dev clusters sync first; sync waves order each app (e.g. istiod before ztunnel)
6. Verify: Argo CD apps Synced/Healthy and `task status`
7. Prod follows when its `addonsRevision` moves to the verified ref (a PR to its fleet file)
8. A `kubernetesVersion` bump makes Cluster API replace servers one at a time (3 keep quorum)

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
