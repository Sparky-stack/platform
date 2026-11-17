# Diagrams

Generated, animated SVGs, safe to embed in GitHub READMEs (rendered through `<img>`: no scripts, no
`foreignObject`, no external fonts, images or CSS):

```html
<img src="docs/diagrams/architecture.svg" alt="koorikla/platform architecture" width="100%">
```

| Diagram | One idea | Owning doc |
|---|---|---|
| [architecture.svg](architecture.svg) | git → mgmt → workload clusters: where every part runs | [architecture.md](../architecture.md) |
| [security.svg](security.svg) | supply chain, admission, runtime detection and response | [supply-chain.md](../supply-chain.md) |
| [network.svg](network.svg) | a request in (kgateway, mesh), its telemetry out to the management cluster | [networking.md](../networking.md) |
| [observability.svg](observability.svg) | every signal lands in the observability plane | [observability.md](../observability.md) |
| [sdlc.svg](sdlc.svg) | git push → signed image → environments → gated production | [promotion.md](../promotion.md) |
| [cluster-lifecycle.svg](cluster-lifecycle.svg) | add, upgrade, remove a cluster by editing one file | [providers.md](../providers.md) |
| [trust.svg](trust.svg) | who signs what (agent CAs, OpenBao mesh CA) and how it renews | [runbooks/certificates-and-secrets.md](../runbooks/certificates-and-secrets.md) |
| [backup.svg](backup.svg) | what is stateful where, and the restore order | [runbooks/backup-restore.md](../runbooks/backup-restore.md) |
| [upgrade.svg](upgrade.svg) | every upgrade is a PR: Renovate → CI → merge → Argo CD, dev before prod | [runbooks/upgrades.md](../runbooks/upgrades.md) |

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
4. Cluster API creates each workload cluster's k3s nodes on docker, AWS or Hetzner
5. Argo CD installs the addons and the cluster-agent on every cluster whose labels match
6. The cluster-agent dials out to OpenChoreo and pulls the app releases
7. The agent submits the apps to the cluster
8. Kyverno, one of the addons, admits only apps with signed images and safe settings before they start

### Security ([security.svg](security.svg))

1. Build & sign scans the image for known vulnerabilities, then cosign signs it with its build record
2. Build & sign pushes the image and its signature to the registry
3. Admission control (Kyverno) fetches the signature from the registry before any pod starts
4. Admission control admits only signed images with safe pod settings: it blocks in production and warns in dev and staging
5. Detection (Falco) watches what every pod does at runtime, on every node
6. Detection sends every alert to Auto-response (Falco Talon)
7. Auto-response stops or labels the offending pod when an alert matches one of its rules
8. Detection also escalates critical alerts to an incident workflow on the management cluster (Argo Events), which finds the affected app and records the incident on it

### Network ([network.svg](network.svg))

1. A client opens the app URL; kgateway takes the request
2. kgateway routes it to the app pods
3. Inside the Istio ambient service mesh, ztunnel encrypts every hop between the app pods
4. The collectors on each node gather the pods' logs and metrics: Fluent Bit tails their log files, the Prometheus agent scrapes their metrics
5. The app pods send their traces to the OpenTelemetry collector
6. The collectors dial out and ship everything to the observability plane on the management cluster

### Observability ([observability.svg](observability.svg))

1. Fluent Bit ships container logs, security alerts included, to OpenSearch
2. The OpenTelemetry collector sends app traces and events to OpenSearch and app metrics to Prometheus
3. The Prometheus agent collects container and cluster metrics and sends them to Prometheus
4. Backstage, the promotion gate and the opt-in AI agents query the observer API, which reads both stores behind one login

### SDLC ([sdlc.svg](sdlc.svg))

1. A developer merges reviewed code to main in the app repo
2. Build & sign polls main every minute and builds each new commit in-cluster, on the management cluster
3. Build & sign scans the image, signs it with the platform key and pushes it to Harbor
4. Build & sign commits the image digest to `deploy/` on main; `deploy/` changes never start a build
5. Argo CD reads the new digest on main and OpenChoreo cuts one immutable release
6. OpenChoreo deploys the new release to development automatically
7. The team merges a staging PR that picks the release running in development
8. Argo CD reads `staging.yaml` on main
9. OpenChoreo deploys the same release to staging
10. The promotion gate starts when the staging rollout succeeds and checks staging: readiness, smoke tests, alerts, 5xx error rate, freeze windows
11. The promotion gate opens a production PR with that release only if every check passes
12. A code owner approves and merges the production PR
13. Argo CD reads `production.yaml` on main, outside freeze windows
14. OpenChoreo submits the same release to production
15. Kyverno in every environment checks each image's signature, attestations and digest in Harbor against the platform key: it warns in development and staging and blocks unverified pods in production

Roll back by reverting the production PR. A failed scan, gate check or admission check stops the release where it is.

### Cluster lifecycle ([cluster-lifecycle.svg](cluster-lifecycle.svg))

1. Argo CD reads the fleet file `clusters/<name>.yaml`
2. Argo CD renders the cluster chart: the cluster for Cluster API, the agent certificate for cert-manager (and the data plane record for OpenChoreo)
3. Cluster API creates the machines and installs k3s
4. Cluster API copies the agent certificate into the cluster; the CA key stays on the management cluster
5. Once the cluster is up, Argo CD installs its addons, cluster-agent included
6. The cluster-agent dials out to OpenChoreo, which accepts only this cluster's CA

Upgrade: bump `kubernetesVersion` in the fleet file; Cluster API replaces the nodes one at a time. Remove: delete the file; Argo CD prunes, Cluster API deletes the cluster and its CA goes with it.

### Trust & certificates ([trust.svg](trust.svg))

1. cert-manager issues each cluster's agent certificate from that cluster's own CA and renews it a month before it expires
2. Cluster API copies the agent certificate into the cluster; the CA's private key stays on the management cluster
3. cert-manager gives cluster-gateway that cluster's CA, the only one it accepts for that cluster
4. The cluster-agent dials out with its certificate and restarts by itself when the certificate renews
5. Separately, OpenBao (opt-in) creates a root and an intermediate CA for each group of clusters; the keys never leave it
6. The mesh proxies ask istio-csr for short-lived certificates: 24 hours, renewed at half-life
7. istio-csr dials out to OpenBao, logs in with its service account and gets each request signed

### Backup & restore ([backup.svg](backup.svg))

1. The operator fetches the latest backup copies from off the host: etcd snapshots and volume copies
2. The operator restores the management cluster's etcd from its latest snapshot: the workload clusters' records and the CA keys come back
3. The operator restores Thunder's volumes from their copy: users, sign-in clients, signing keys
4. The operator restores OpenBao's volume copy (opt-in): secrets and the mesh CA keys
5. OpenBao fetches its unseal key from the secret backend, which lives outside the clusters (on a local setup, re-create it with `task secrets`)
6. The operator restores Harbor's volume copy, or new builds push the images again
7. Argo CD re-syncs everything else from Git
8. The databases (opt-in) restore themselves from object storage, only if a workload cluster is lost too

Telemetry is not backed up: it starts empty.

### Upgrade flow ([upgrade.svg](upgrade.svg))

1. Renovate opens a pull request: a Helm chart, a k3s release, an image or a tool version
2. GitHub runs CI on the pull request, every chart rendered and tested on Linux, macOS and Windows, x86 and arm; a maintainer reviews and merges it into main
3. Argo CD reads main for every cluster that follows it
4. Argo CD syncs the dev clusters first, each app in a fixed order
5. Dev clusters are verified: every app synced and healthy
6. A maintainer opens and merges a second pull request in GitHub that moves the prod clusters to the verified commit
7. Argo CD syncs the prod clusters to that commit

Kubernetes versions: a `kubernetesVersion` bump in a fleet file rolls through Cluster API instead, one server at a time, dev before prod (see the cluster lifecycle view).

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
