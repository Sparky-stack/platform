# Wiki Schema — koorikla/platform

> [!WARNING]
> **LLM wiki: AI-agent working memory, not human documentation.** It may be stale or wrong. Human docs live in [docs/](../docs/) and win on any conflict. See [README.md](README.md).

## Purpose & Authority Rule
This `wiki/` is the compounding synthesis layer for AI agents working on `koorikla/platform`: architectural **decisions** (why we chose X and rejected Y), operational **gotchas** (non-obvious failure modes learned live), **concepts** (high-level mental models), and **queries** (reusable investigations).

**Not a second source of truth:**
- The authoritative sources of truth are [AGENTS.md](../AGENTS.md), [docs/](../docs/conventions.md) (including [docs/runbooks/](../docs/operations.md) and addon/chart `README.md` files), and the code itself.
- The wiki must **never contradict** authoritative docs or code. If a contract, value, or behavior changes, update the authoritative doc/code **and** the affected wiki page in the **same PR**.

## Session Orientation (Read First)
Before planning or editing in `koorikla/platform`:
1. Read `wiki/SCHEMA.md` and `wiki/index.md`.
2. Scan the bottom of `wiki/log.md` for recent decisions and pitfalls.
3. Open relevant `decisions/` or `gotchas/` pages before touching an area.
4. When you make a non-trivial design choice or uncover a live pitfall, add or update a page here, list it in `wiki/index.md`, and append to `wiki/log.md` in the same PR.

## Conventions & Link Rules
- **File names:** lowercase, hyphen-separated (`wiki/<type>/<slug>.md`). Keep pages concise (`< 80` lines).
- **Links:** Use plain relative Markdown links (e.g. `[OpenBao mesh CA](../decisions/openbao-mesh-ca-and-pluggable-cloud-ca.md)` or `[docs/conventions.md](../../docs/conventions.md)`), **never** `[[wikilinks]]`, so GitHub renders them and `hack/check-docs.py` verifies every link target and heading anchor.
- **Cross-references:** Every content page links to at least 2 other wiki pages plus its authoritative doc or code path.
- **Validation:** `hack/check-docs.py` validates `wiki/**/*.md` on every `task lint` / `task test` run.

## Frontmatter
Every page under `decisions/`, `gotchas/`, `concepts/`, and `queries/` starts with YAML frontmatter:

```yaml
---
title: Short Descriptive Title
created: YYYY-MM-DD
updated: YYYY-MM-DD
type: decision | gotcha | concept | query
tags: [from taxonomy below]
confidence: high | medium | low
---
```

## Page Types
- **`decisions/`** — ADR-style record:
  - `## Context` (problem and constraints)
  - `## Decision` (what we do and where it lives)
  - `## Alternatives rejected` (what we ruled out and why)
  - `## Consequences` (trade-offs, follow-ups, invariants)
  - `## Links` (date, issues/PRs, authoritative docs, related wiki pages)
- **`gotchas/`** — Live/CI failure pattern:
  - `## Symptom` -> `## Cause` -> `## Fix` -> `## Where enforced` -> `## Links`
- **`concepts/`** — Short synthesis explainer connecting multiple subsystems and linking to authoritative `docs/*.md`.
- **`queries/`** — Filed answers to recurring architectural or debugging questions.

## Tag Taxonomy
Every tag in frontmatter must come from this fixed domain set:
- `capi` — Cluster API, ClusterClasses, providers (`docker`, `aws`, `hetzner`, `gcp-gke`, `byo`), Talos/k3s
- `openchoreo` — OpenChoreo control/data/workflow/observability planes, bindings, traits, Thunder, Backstage
- `argocd` — Argo CD ApplicationSets, sync waves, custom health checks, server-side apply
- `secrets` — External Secrets Operator (ESO), OpenBao KV/PKI, SecretStores, PushSecrets
- `mesh` — Istio ambient mesh, `ztunnel`, `istio-csr`, kgateway, east-west gateways, mTLS, NetworkPolicies
- `supply-chain` — BuildKit, Harbor, Cosign, Kyverno admission verification, SLSA/SBOM
- `observability` — OpenSearch, Prometheus, OpenTelemetry, Fluent Bit, Hubble, Falco, Talon
- `data` — Crossplane v2 XRDs/Compositions, CloudNativePG, Strimzi, KEDA
- `bootstrap` — `bootstrap/`, `task up` / `task down`, k3d mgmt, nightly clean-bootstrap rehearsals
- `ci` — GitHub Actions, reusable workflows, `mise`, `Taskfile.yml`, `prek`, offline test suites
- `docs` — Documentation contracts, diagrams, runbooks, `hack/check-docs.py`
- `agents` — AI coding agents, subagent constraints, skills, worktrees
- `upstream` — Upstream bugs, missing upstream features, version pins
