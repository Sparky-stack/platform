# Wiki Log — koorikla/platform

> Chronological record of wiki actions. Append-only.
> Format: `## [YYYY-MM-DD] action | subject`
> Actions: `create`, `ingest`, `update`, `query`, `lint`, `archive`, `delete`

## [2026-11-18] create | Initialize and seed koorikla/platform LLM wiki
- Created `wiki/SCHEMA.md`, `wiki/index.md`, and `wiki/log.md` following the `llm-wiki` pattern adapted for in-repo GitHub Markdown and `hack/check-docs.py`.
- Seeded 10 decision pages in `wiki/decisions/` covering OpenBao mesh CA + pluggable cloud CA, OSS `crossplane-contrib` Upjet providers, local lab scope + single-cluster profile + BYO + untested cloud examples, Talos on Hetzner (#189), merging `clusterclasses` into `charts/cluster` (#116), build trigger polling/webhook + GitHub App tokens, PR preview environments (#168), Helm/Crossplane/OpenChoreo building blocks, folding `koorikla/ci` + `mise` (#213), and re-bootstrap over live repair.
- Seeded 9 gotcha pages in `wiki/gotchas/` covering Argo CD `DeletingPolicy` and unmatched CRS health, sync-wave ordering + `retry.limit: -1`, OpenChoreo `ReleaseBinding` ordering + fresh Harbor digests, Istio ambient port `15008` + telemetry `*.localhost` DNS, OpenSearch `ActiveProcessorCount` in k3d, Docker network pool exhaustion from `crossplane render`, `mise` global vs repo versions, OpenBao init vs policy reconciler, and Gemini transcript ceiling discipline.
- Seeded 2 concept pages in `wiki/concepts/` covering cluster onboarding and the OpenChoreo SDLC/promotion flow.

## [2026-11-19] update | charts/cluster absorbs capi-providers + clusterclasses (#116)
- Updated `decisions/merge-clusterclasses-into-charts-cluster.md`: `templates/<provider>/` (not `providers/<provider>/`), `scope: fleet|cluster`, catalog entry `cluster-fleet`.

## [2026-11-19] create | OpenChoreo SecretReference rotation and scope (#250)
- Added `gotchas/openchoreo-secretreference-rotation-and-scope.md`.

## [2026-11-19] create | Argo CD server-side diff and atomic CRD spec (#184)
- Added `gotchas/argocd-server-side-diff-atomic-crd-spec.md`.

## [2026-11-19] update | Argo CD never diffs hook resources (#221)
- Updated `gotchas/argocd-server-side-diff-atomic-crd-spec.md`: hook inputs get a checksum in a normal `hook-inputs` ConfigMap; `hack/tests/test_hook_kinds.sh`.

## [2026-11-19] update | Ambient kubelet probes vs cell NetworkPolicy
- Updated `gotchas/istio-ambient-port-15008-and-telemetry-dns.md`: istio-cni SNATs kubelet probes to `169.254.7.127`, Cilium drops them as `world`; `platform-mesh-hbone` now admits that source.

## [2026-11-19] create | Helm library chart koorikla-lib (#116)
- Added `gotchas/helm-library-chart-koorikla-lib.md`: values-scope leak into `.Values`, stale `file://` tarballs, library charts only load partials (test harness `charts/lib-test`), helm-docs needs `values.yaml`; Argo CD builds `file://` deps.

## [2026-11-19] create | Helm values.schema.json vs template required (#116)
- Added `gotchas/helm-values-schema-vs-template-required.md`: schema errors fail `helm lint` with chart defaults, template `fail` does not; where presence checks stay; errorPattern for moved unittest asserts.

## [2026-11-20] create | Preview cells: tenant secrets and CNPG under Cilium (#267, #331)
- Added `gotchas/preview-cells-tenant-secrets-and-cnpg.md`: preview namespaces bound per Kyverno descriptor with the namespace computed by the reconcile; quota vs postgresql minimum; Cilium ipBlock never matches the API server; CNPG job pods need the API too.

## [2026-11-20] update | Missing-digest rebuild killed by a k3s restart
- `gotchas/openchoreo-releasebinding-and-fresh-registry.md`: etcd stall -> k3s leader-lease loss kills every pod (exit 255); build steps retry infra kills, auto-build retries a failed rebuild (-r2/-r3) then reports.

## [2026-11-20] create | Preview teardown leaks (stuck RRB, re-created OpenBao descriptor)
- Added `gotchas/preview-teardown-leaks.md`: RenderedRelease cleanup needs the Environment (blockOwnerDeletion + foreground TTL delete); Kyverno re-generated the descriptor on the terminating binding's finalizer-removal UPDATE (matchCondition on deletionTimestamp).

## [2026-11-20] create | OpenChoreo developer authz per project
- Added `gotchas/openchoreo-authz-per-project-developers.md`: deny is resolved per entitlement value; `developers` org-wide read-only, tenant developer groups get `developer` scoped to their project with the gated-env condition in the allow (#335).

## [2026-11-20] update | Cell AuthorizationPolicy (#324)
- `gotchas/istio-ambient-port-15008-and-telemetry-dns.md`: STRICT authenticates but admits any mesh identity; per-cell AuthorizationPolicy `platform-cell-peers` admits the cell + platformPeers; read principals from ztunnel metrics; permissive cells need allow-all.
