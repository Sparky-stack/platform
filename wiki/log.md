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
