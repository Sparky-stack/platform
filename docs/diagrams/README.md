# Diagrams

Generated, animated SVGs, safe to embed in GitHub READMEs (rendered through `<img>`: no scripts, no
`foreignObject`, no external fonts, images or CSS):

```html
<img src="docs/diagrams/architecture.svg" alt="koorikla/platform architecture" width="100%">
```

| Diagram | One idea | Owning doc |
|---|---|---|
| [architecture.svg](architecture.svg) | git → mgmt → workload clusters: where every part runs | [architecture.md](../architecture.md) |
| [security.svg](security.svg) | supply chain, admission, runtime detection and response | [supply-chain.md](../supply-chain.md), runtime: [observability.md](../observability.md#falco-response) |
| [network.svg](network.svg) | a request in (kgateway, mesh), its telemetry out to the management cluster | [networking.md](../networking.md) |
| [observability.svg](observability.svg) | every signal lands in the observability plane | [observability.md](../observability.md) |
| [sdlc.svg](sdlc.svg) | build once in-cluster; every environment repeats merge → sync → deploy → admit; the gate links staging to production | [promotion.md](../promotion.md) |
| [cluster-lifecycle.svg](cluster-lifecycle.svg) | add, upgrade, remove a cluster by editing one file | [providers.md](../providers.md) |
| [trust.svg](trust.svg) | who signs what (agent CAs, OpenBao mesh CA) and how it renews | [runbooks/certificates-and-secrets.md](../runbooks/certificates-and-secrets.md) |
| [backup.svg](backup.svg) | what is stateful where, and the restore order | [runbooks/backup-restore.md](../runbooks/backup-restore.md) |
| [upgrade.svg](upgrade.svg) | every upgrade is a PR: Renovate → CI → merge → Argo CD, dev before prod | [runbooks/upgrades.md](../runbooks/upgrades.md) |
| [delivery-lanes.svg](delivery-lanes.svg) | three delivery lanes (apps, infra, extensions), one pattern: CI → signed artifact by digest → git → reconciler → admission | [devops-guide.md](../devops-guide.md) |
| [lane-apps.svg](lane-apps.svg) | apps lane: reusable CI signs one image, its digest goes back to the app repo, OpenChoreo rolls it out, Kyverno verifies it | [devops-guide.md](../devops-guide.md) |
| [lane-infra.svg](lane-infra.svg) | infra lane: pinned upstream charts, CI, Argo CD by cluster label, Cluster API; signatures stop at the image layer | [devops-guide.md](../devops-guide.md) |
| [lane-extensions.svg](lane-extensions.svg) | extensions lane: a Crossplane package built and signed like an image, promoted by its pinned digest (signature check planned) | [devops-guide.md](../devops-guide.md) |
| [app-database-map.svg](app-database-map.svg) | app + database: Component, Workload, postgresql Resource and SecretReference → cell namespace → Crossplane → CloudNativePG → secrets → pods | [devops-guide.md](../devops-guide.md) |

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
  lists below are the same text (`build.py` fails when they differ). Exception: the SDLC view is a swimlane (actors
  as rows, environments as columns) whose arrows follow the change from one lane to the next; its legend says so
  (`flow_label`), and `MANUAL` chips (explained in the legend, `legend_chip`) mark where a person merges.
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
4. Cluster API creates each workload cluster: k3s nodes on docker, AWS or Hetzner, or managed GKE
5. Argo CD installs the addons and the cluster-agent on every cluster whose labels match
6. The cluster-agent dials out to OpenChoreo and pulls the app releases
7. The agent submits the apps to the cluster
8. Kyverno, one of the addons, admits only apps with signed images and safe settings before they start
9. Apps claim a database through an OpenChoreo resource binding; the claim goes to Crossplane on the same cluster
10. Crossplane composes the claim into objects for an in-cluster operator where there is no managed database: CloudNativePG for PostgreSQL, MOCO for MySQL
11. Crossplane's cloud providers create it outside the cluster instead on cloud installations: RDS or Aurora, Cloud SQL or Azure Flexible Server

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
2. kgateway, itself in the service mesh, routes it to the app pods
3. Inside the Istio ambient service mesh, ztunnel encrypts every hop, from the gateway to the app pods and between them; app namespaces refuse unencrypted traffic and callers from other apps' namespaces
4. The collectors on each node gather the pods' logs and metrics: Fluent Bit tails their log files, the Prometheus agent scrapes their metrics
5. The app pods send their traces to the OpenTelemetry collector
6. The collectors dial out and ship everything to the observability plane on the management cluster

### Observability ([observability.svg](observability.svg))

1. Fluent Bit ships container logs, security alerts included, to OpenSearch
2. The OpenTelemetry collector sends app traces and events to OpenSearch and app metrics to Prometheus
3. The Prometheus agent collects container and cluster metrics and sends them to Prometheus
4. Backstage, the promotion gate and the opt-in AI agents query the observer API, which reads both stores behind one login

### SDLC ([sdlc.svg](sdlc.svg))

1. A developer merges a reviewed PR to main in the app repo
2. The new commit reaches Build & sign within a minute (it polls main)
3. Build & sign tests, scans and signs the image with the platform key and pushes it to Harbor
4. Build & sign commits the image digest to `deploy/` on main, which starts no new build
5. The digest commit is synced by Argo CD; OpenChoreo cuts one immutable release
6. OpenChoreo deploys it to development
7. Kyverno in development checks the image signature and attestations, and only warns
8. The team opens and merges a staging PR that picks the release verified in development
9. The merged staging PR is synced by Argo CD
10. OpenChoreo deploys the same release to staging
11. Kyverno in staging checks them the same way, and only warns
12. Staging's finished rollout starts the promotion gate: readiness, smoke tests, alerts, 5xx rate, freeze window
13. The promotion gate opens a production PR only if every check passes
14. A code owner approves and merges the production PR
15. The merged production PR is synced by Argo CD, after the freeze window if one is active
16. OpenChoreo deploys the same release to production
17. Kyverno in production blocks any pod whose image signature, attestations or digest do not verify

Freeze window: the gate opens no production PR (re-run it afterwards) and Argo CD holds a production PR merged anyway until the window ends; break glass by changing the window in git. A failed scan stops the build, a failed gate check the promotion. Roll back by reverting the production PR.

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
4. The operator restores OpenBao's volume copy (opt-in): app secrets and the mesh CA keys
5. OpenBao fetches its unseal key from the secret backend, which lives outside the clusters (on a local setup, re-create it with `task secrets`)
6. The operator restores Harbor's volume copy, or new builds push the images again
7. Argo CD re-syncs everything else from Git
8. The databases (opt-in) restore themselves from object storage, only if a workload cluster is lost too

Telemetry is not backed up: it starts empty.

### Upgrade flow ([upgrade.svg](upgrade.svg))

1. Renovate opens a pull request: a Helm chart, a k3s release, an image or a tool version
2. GitHub runs CI on the pull request: every changed chart rendered and tested (all of them nightly, on Linux, macOS and Windows); a maintainer reviews and merges it into main
3. Argo CD reads main for every cluster that follows it
4. Argo CD syncs the dev clusters first, each app in a fixed order
5. Dev clusters are verified: every app synced and healthy
6. A maintainer opens and merges a second pull request in GitHub that moves the prod clusters to the verified commit
7. Argo CD syncs the prod clusters to that commit

Kubernetes versions: a `kubernetesVersion` bump in a fleet file rolls through Cluster API instead, one server at a time, dev before prod (see the cluster lifecycle view).

These five views follow the change, not the actor (like the SDLC view): each arrow carries the change or object to the next component, and the legend says so.

### Delivery lanes ([delivery-lanes.svg](delivery-lanes.svg))

1. App CI builds, scans and signs one image per merge (keyless cosign, attestations) and pushes it by digest
2. Signed image's digest is committed to the app repo's deploy folder by the bump job
3. Deploy folder is synced by Argo CD into OpenChoreo, which releases it to each environment through the cluster-agent
4. OpenChoreo's environments run Kyverno, which admits only the signed digest: it blocks in production and warns in development and staging
5. Infra CI renders and tests every chart against its pinned upstream version; Renovate opens the bump pull requests
6. Upstream charts stay pinned by version (and digest where possible) on main after review
7. Main branch is synced by Argo CD to every cluster whose labels match; Cluster API builds the clusters
8. Argo CD's addons pass Kyverno for pod settings; their images are pinned by digest, chart signatures are not checked yet
9. Package CI renders, tests, signs and pushes each Crossplane package by digest
10. Signed package's digest is pinned in addon crossplane by a reviewed Renovate pull request
11. Package pin is synced by Argo CD; Crossplane (opt-in) pulls the package and installs the API
12. Crossplane's package signature check is planned: packages are signed, verification waits for cosign v3 support

### Apps lane ([lane-apps.svg](lane-apps.svg))

1. App repo: a merge to main runs the reusable CI workflow it pins by commit (app-go.yaml and the other stacks, each calling app-container.yaml): lint, tests, vulnerability scan, multi-arch build
2. Reusable CI pushes the image to ghcr.io and signs it keyless with cosign, with SBOM, provenance and vulnerability attestations
3. Registry digest goes into the app repo: app-workload-bump.yaml commits the image digest to the Workload in deploy/ ([skip ci])
4. Deploy folder is synced by Argo CD (the team's Application) into OpenChoreo: Component, Workload, ReleaseBinding
5. Argo CD hands them to the OpenChoreo control plane, which cuts one immutable release and binds it to development
6. OpenChoreo passes the release to the cluster-agent over the connection the agent opened from the workload cluster
7. cluster-agent applies the release in the environment's namespace, where Kyverno sees every pod first
8. Kyverno verifies the image signature, attestations and digest before the pod starts: it blocks in production and only warns in development and staging

Promotion: the same release moves to staging and production by pull requests, the promotion gate opens the production one (see the SDLC view, which also shows the in-cluster build path with Harbor and the platform key).

### Infra lane ([lane-infra.svg](lane-infra.svg))

1. A pull request to the platform repo, from Renovate (a new upstream release) or a person, changes a chart pin, addon values or a fleet file and runs ci.yaml, scoped to what changed
2. CI fetches the pinned upstream charts (versions in Chart.yaml and Chart.lock, sha256 pins for the mesh) and lints, renders and unit-tests every changed chart
3. CI must pass before a maintainer merges: main then declares the versions, in the addon charts, the ApplicationSets and the installation values
4. Main branch is read by Argo CD: dev clusters follow main, prod clusters a verified commit
5. Argo CD renders each fleet file into a cluster for Cluster API, which creates and upgrades its k3s nodes
6. Argo CD installs the addons on every cluster whose labels match, in a fixed order
7. Kyverno admits the addon pods with safe settings only; their images are pinned by digest in git (a test checks it), not signature-verified: Argo CD cannot verify Helm or OCI chart signatures

Planned: verify upstream chart signatures in the Renovate pull request and mirror the charts into an internal registry, once upstreams sign them (few do today). release-please tags each platform release.

### Extensions lane ([lane-extensions.svg](lane-extensions.svg))

1. A pull request to packages/<api> runs package-<api>.yaml, which calls app-crossplane-configuration.yaml: schema checks and render tests for every backend
2. Package CI pushes the Configuration package and its embedded function to ghcr.io on main and on release tags, signed keyless with cosign, with SLSA provenance
3. Registry tag and digest are pinned in addon crossplane's values (or one installation's) by a Renovate pull request; merging it is the promotion
4. Package pin on main is synced by Argo CD to every cluster that runs addon crossplane (opt-in)
5. Argo CD applies the Configuration at that digest; Crossplane's package manager pulls it and its function from the registry
6. Crossplane will verify the package signature before installing it: the switch is on main but stays off until Crossplane reads cosign v3 signatures
7. Crossplane installs the API definition, its composition and function: apps can now claim the API, for example a PostgreSQL database

The other extension points ride the other lanes: OpenChoreo component types, traits and resource types are files of the openchoreo-platform addon (infra lane), Backstage templates are read from git by the catalog, Backstage plugins come with its image.

### App + database map ([app-database-map.svg](app-database-map.svg))

1. Component (with the keda-scaler trait), Workload, Resource of type postgresql and SecretReference are synced from the app repo by Argo CD into OpenChoreo
2. OpenChoreo renders the Resource into the cell namespace as a PostgreSQL claim (platform.koorikla.io, a namespaced Crossplane XR)
3. OpenBao's value behind the SecretReference lands in the app secret: External Secrets reads the project's own mount through the cell's SecretStore
4. PostgreSQL claim is composed by Crossplane with the Composition of the Configuration package; the EnvironmentConfig platform-postgresql picks the backend
5. Crossplane creates a CloudNativePG Cluster on a local cluster (RDS or Aurora, Cloud SQL, Azure Flexible Server in the cloud)
6. CloudNativePG creates the database and its owner and writes the connection secret <name>-app next to the workload
7. App secret reaches the app pods as env, from secretKeyRef or envFrom
8. Connection secret reaches the app pods, which OpenChoreo deployed from the Workload: host, port and database as values, user, password and URI as secret references; KEDA scales them

Planned: the same map for the event bus and its topics. Production asks for high availability and backups (admission policy); credentials never leave the workload cluster.

## Editing

The SVGs are generated. Do not hand-edit them; change `src/build.py` and regenerate:

```bash
python3 docs/diagrams/src/build.py                 # writes docs/diagrams/*.svg, prints issues, exit 1 if any
python3 docs/diagrams/src/build.py --check         # writes nothing; also fails when a committed SVG is stale
python3 docs/diagrams/src/build.py --png /tmp/d    # also renders static PNGs (rsvg-convert) for review
python3 docs/diagrams/src/build.py network         # one diagram
```

`hack/tests/test_diagrams.sh` (part of `task test`) runs `--check`, proves the output is deterministic and feeds
planted defects to the checker. `hack/tests/test_diagram_labels.sh` runs `hack/check-diagram-labels.py`: every box
title must appear in the doc(s) of the "Owning doc" column above (or the doc's own term for it, listed in the script's
`ALIASES`; `DIAGRAM_ONLY` holds the few boxes with a reason no doc names them), so a renamed or dropped component
fails until the diagram or the doc follows. Mermaid fences are rejected by `hack/check-docs.py` (one diagram system).

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
