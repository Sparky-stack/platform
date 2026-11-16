# AGENTS.md

Rules for every AI agent (Claude Code, Antigravity, Gemini CLI, Hermes) and human working on this repo. `CLAUDE.md` and
`GEMINI.md` are symlinks to this file.

## Read first
- [docs/conventions.md](docs/conventions.md): the contracts. Invariants, labels, names, secret keys, layout, tooling
  rules and "Current practice only" apply to every change; this file does not repeat them.
- [docs/architecture.md](docs/architecture.md): the design and the reasons for it.
- The doc of the area you touch (index: [README.md](README.md#documentation)).

## Guardrails
- Never deploy to, or delete in, the kubectl context `koorikla` (homelab, runs other production workloads). Only the
  local mgmt context `k3d-platform-mgmt` and the CAPD clusters it creates are fair game.
- Git is the source of truth: no `kubectl apply` for platform resources; changes reach clusters through `main` and
  Argo CD.
- Never commit secret values, never print tokens. Seed local secrets only with `task secrets`.
- Never push to `main`. Work on a branch, open a PR; the maintainer merges.

## Before you push
- `task lint` and `task test` pass: helm lint and template of every chart with every installation, kubeconform with
  CRD schemas, helm-unittest, contract tests in `hack/tests/`, shellcheck, the Markdown check (`hack/check-docs.py`).
- New behaviour has a test; a security fix has a negative test.
- Diagrams changed: `python3 docs/diagrams/src/build.py` reports 0 issues.
- Docs: update the one doc that owns the topic. Backlog, follow-ups and "verify later" items go into GitHub issues,
  not into docs; link the issue instead.
- Conventional commits (`feat(cluster): …`, `fix(harbor): …`, `docs: …`).

## Claims
- `task test` passing is necessary, not sufficient. Before claiming something works, show live evidence (Argo CD app
  Synced/Healthy, `kubectl get clusters -n fleet`, `curl` of the app endpoint).
- `grep -rn VERIFY` lists values inferred but not yet confirmed live; say so when you rely on one.

## Current practice only
No legacy patterns: current stable APIs and upstream-recommended practice only; anything legacy found in review is
replaced, not copied. The concrete list: [docs/conventions.md](docs/conventions.md#current-practice-only).
