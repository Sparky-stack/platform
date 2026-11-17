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
  13, step key 13.5, legend 13. Floor: 13 px for every text except the 12 px uppercase status chips.
- **Colour**: one accent, amber `#fbbf24`, used only for the numbered flow (arrows, discs, motion). Box and zone
  colour says one thing per diagram, where it runs: teal management cluster, sky workload cluster, slate outside the
  clusters (backup uses violet for state that must be restored instead). Text contrast is at least 4.5:1, box detail
  lines, chips and step numbers included (checked).
- **Shapes**: boxes are components (at most 12 per diagram; zones, legend and key do not count), each drawn once.
  Every box is on the numbered flow or marked context (grey, borderless, "context, not a step" in the legend). Zones
  are clusters, labelled in caps where no arrow crosses their border. Dashed + `OPT-IN` chip = on `main`, off by
  default; dimmed + `PLANNED` chip = not on `main`. Box titles name the component; detail lines say what it is in
  plain words; identifiers, abbreviations and resource kinds belong in the owning doc, not on the canvas.
- **Numbered steps**: an amber disc on an arrow, or at the left of a box for a step that happens at that component
  (a restore, a check). Numbers increase in reading order: left to right, then the next row down (`columns` diagrams:
  top to bottom, then the next column). Every number appears once: a step that reaches several boxes forks or joins
  at a dot. An arrow points from the component that acts (opens the connection, does the work) to the one it acts
  on, and the step text names that component first: Argo CD reads Git, so its arrow points at Git; the cluster-agent
  dials out, so its arrow leaves the workload cluster (labelled "dials out"). The key under every diagram and the
  lists below are the same text (`build.py` fails when they differ).
- **Motion** only on the numbered flow: a light particle runs along each step's arrow, in step order, then rests.
  `@media (prefers-reduced-motion: reduce)` stops it. Every animated element is an overlay with static opacity 0,
  so a static frame (rsvg-convert, PDF, reduced motion) is the complete diagram.
- **Phone**: GitHub scales the image to the screen; the step lists below are the phone-friendly text, and tapping
  the image opens it full size (at 2x zoom on a 390 px phone every box label and step is at least 10 px).
- **Legend**: generated from what the diagram uses, so it never lists a colour or style that is not on the canvas.

## Steps

The numbered flow of each diagram, word for word.

### Architecture ([architecture.svg](architecture.svg))

1. Argo CD reads Git: fleet files, the addon catalog, teams and app repos
2. Argo CD turns each fleet file into a cluster for Cluster API to build
3. Argo CD hands each app's release to OpenChoreo
4. Cluster API creates the cluster's k3s nodes on docker, AWS or Hetzner
5. Argo CD installs the addons and the cluster-agent on every cluster whose labels match
6. The cluster-agent dials out to OpenChoreo and pulls the app releases
7. The agent deploys the apps
8. Kyverno, one of the addons, admits only apps with signed images and safe settings

### Security ([security.svg](security.svg))

1. Build & sign scans the image for known vulnerabilities, then cosign signs it with its build record
2. Build & sign pushes the image and its signature to the registry
3. Kyverno fetches the signature from the registry before any pod starts
4. Kyverno admits only signed images with safe pod settings: it blocks in production and warns in dev and staging
5. Falco watches what every pod does at runtime, on every node
6. Falco Talon stops or labels an offending pod as soon as Falco alerts it
7. Falco escalates critical alerts to a response workflow on the management cluster

### Network ([network.svg](network.svg))

1. A client opens the app URL; kgateway takes the request
2. kgateway routes it into the service mesh
3. The service mesh delivers it to the app pods and encrypts every hop between pods
4. The app pods send their logs, metrics and traces to the collectors
5. The collectors dial out and ship them to the observability plane on the management cluster

### Observability ([observability.svg](observability.svg))

1. Fluent Bit ships container logs, security alerts included, to OpenSearch
2. The OpenTelemetry collector sends app traces and events to OpenSearch and app metrics to Prometheus
3. The Prometheus agent collects container and cluster metrics and sends them to Prometheus
4. Backstage, the promotion gate and the opt-in AI agents query the observer API, which reads both stores behind one login

### SDLC ([sdlc.svg](sdlc.svg))

1. A push to the app repo starts a build on the OpenChoreo workflow plane, or GitHub Actions
2. Build & sign scans and signs the image and pushes it to the registry (it also commits the new version to `deploy/`)
3. Argo CD reads the `deploy/` folder of the app repo
4. Argo CD applies it to OpenChoreo, which snapshots an immutable release
5. The release deploys to development automatically
6. The promotion gate checks development: readiness, smoke tests, alerts, change freezes
7. The promotion gate opens the pull request that promotes the release to staging once development is healthy; Argo CD applies it
8. The promotion gate opens the production pull request only after staging; it also needs code-owner approval, and Kyverno admits only signed images pinned by digest

### Cluster lifecycle ([cluster-lifecycle.svg](cluster-lifecycle.svg))

1. Argo CD reads the fleet file `clusters/<name>.yaml`
2. Argo CD renders the cluster chart and hands the cluster to Cluster API, with the agent's certificate request and its OpenChoreo data plane
3. Cluster API creates the machines and installs k3s
4. Argo CD installs every addon whose labels match, as soon as the cluster's access secret exists
5. cert-manager issues the agent's certificate from this cluster's own CA; Cluster API copies it into the cluster
6. The cluster-agent dials out to OpenChoreo, which accepts only this cluster's CA

Upgrade: bump `kubernetesVersion` in the fleet file; Cluster API replaces the nodes one at a time. Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.

### Trust & certificates ([trust.svg](trust.svg))

1. cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it a month before it expires
2. cert-manager's certificate is copied into the cluster by Cluster API; the CA's private key stays on the management cluster
3. cert-manager gives cluster-gateway that cluster's CA, the only one it accepts for that cluster
4. The cluster-agent dials out with its certificate and restarts by itself when the certificate renews
5. Separately, OpenBao (opt-in) creates a root and an intermediate CA for each group of clusters; the keys never leave it
6. The mesh proxies ask istio-csr for short-lived certificates: 24 hours, renewed at half-life (without the opt-in, istiod signs them)
7. istio-csr dials out to OpenBao, logs in with its service account and gets each request signed

### Backup & restore ([backup.svg](backup.svg))

1. Restore the management cluster's etcd from its latest snapshot: Cluster API keeps its clusters and the CA keys come back
2. The secret backend is outside the clusters and keeps its own backups; on a laptop, re-seed it with `task secrets`
3. Restore Thunder's volumes: users, sign-in clients, signing keys
4. OpenBao (opt-in) restores a cold copy of its data and fetches its unseal key from the secret backend
5. Harbor's images come back from its volumes or from new builds; telemetry starts empty
6. Argo CD re-syncs everything else from Git
7. The databases (opt-in) restore themselves from object storage if a workload cluster is lost too

### Upgrade flow ([upgrade.svg](upgrade.svg))

1. Renovate opens a pull request: a Helm chart, a k3s release, an image or a tool version
2. The pull request runs CI: every chart rendered and tested on Linux, macOS and Windows, x86 and arm
3. CI gates the merge: once it passes and a maintainer approves, the pull request is merged into main
4. Argo CD reads main for every cluster that follows it
5. Argo CD syncs the dev clusters first, each app in a fixed order
6. Dev clusters are verified: every app synced and healthy
7. Argo CD syncs the prod clusters only after a second pull request moves them to the verified commit
8. Argo CD hands a Kubernetes version bump to Cluster API, which replaces servers one at a time, dev before prod

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

- more than 12 boxes, boxes closer than 6 px, a box across a zone border, anything outside the card, two boxes with
  the same title, a title that does not start with a capital (unless the product spells itself in lower case);
- text overflowing its box (8 px padding, from the generator's own width estimate: Arial metrics plus a margin for
  wider fallback fonts), overlapping text, text on a box it does not belong to, text below the 13 px floor, contrast
  below 4.5:1 for any text (box detail lines, chips, step numbers, dimmed boxes composited);
- jargon in box detail lines (`dp-*`, ESO, CRS, JWT, resource kinds, ...), placeholders such as `<name>` or issue
  numbers anywhere on the canvas;
- arrows within 6 px of text, crossing chips, badges or unrelated boxes, running along a zone border (< 10 px), with a
  cramped bend (inner segment < 24 px), meeting a box closer than 14 px to a corner, or with ends not on a box or zone
  edge;
- badges and chips closer than 6 px to text, boxes, chips or zone borders; step numbers that are not 1..n, a badge
  without a key entry or a key entry without a badge; steps out of reading order; steps that differ from this README;
- a box neither on the numbered flow nor marked context; a step whose arrow does not start at the first component its
  text names; a "dials out" step whose arrow does not start inside a cluster and point out of it;
- required components missing (each diagram lists them with `d.require(...)`), box labels missing from the SVG;
- no `@keyframes`, an animation without keyframes, no `prefers-reduced-motion` rule, a numbered flow without an
  animated overlay;
- anything unsafe for a README image (scripts, `foreignObject`, event handlers, external URLs, `<image>`), SVGs over
  80 KB.
