---
title: Fold koorikla/ci into Platform Repo and Pin Tooling with mise
created: 2026-11-18
updated: 2026-11-18
type: decision
tags: [ci, supply-chain, docs]
confidence: high
---

# Fold koorikla/ci into Platform Repo and Pin Tooling with mise

## Context
Splitting reusable CI workflows, build scripts, and the `ci-toolbox` image into a separate `koorikla/ci` repository required two-repo coordination and dual-pin Kyverno transitions whenever a build script or language workflow changed (#128, #136). Meanwhile, host/CI drift across Linux, macOS, Windows, and devcontainers caused subtle YAML/Helm failures (#171).

## Decision
- **Pin all dev and CI tooling in `mise.toml`:** Use `mise` (`aqua` backends, locked for 6 OS/arch targets via `task tools:lock`) with `Taskfile.yml` entrypoints so local runs, `prek` git hooks, devcontainers, and GitHub Actions execute identical tool binaries.
- **Fold `koorikla/ci` into `koorikla/platform` (#213):** Import `koorikla/ci` with git history (`ci/` scripts, toolbox Dockerfile, tests, and `.github/workflows/app-<stack>.yaml` reusable workflows) so the lab consists solely of `koorikla/platform` plus the `koorikla/hello-world` app repo(s), then archive `koorikla/ci`.

## Alternatives rejected
- **Keeping `koorikla/ci` as a separate repository:** Every workflow SHA bump requires a Kyverno transition allowlist across two repositories and doubles keyless Cosign verification latency during transition (#136).
- **Per-OS package manager installs in CI (`apt`/`brew`/`choco`):** Drifts across runner updates and breaks offline tests.

## Consequences
- While migrating #213, `addons/kyverno-policies` will temporarily trust both old (`koorikla/ci`) and new (`koorikla/platform`) workflow signer identities until `hello-world` cuts a release signed by the in-repo workflow.
- Agents and scripts must always execute via `mise exec --` from inside the worktree ([mise global vs repo tool versions](../gotchas/mise-global-vs-repo-tool-versions.md)).

## Links
- Date: 2026-11-18 (Issues #128, #136, #213; PRs #65, #129, #171)
- Authoritative docs: [docs/dev-environment.md](../../docs/dev-environment.md), [docs/supply-chain.md](../../docs/supply-chain.md)
- Related wiki: [mise global vs repo tool versions](../gotchas/mise-global-vs-repo-tool-versions.md), [Build trigger polling and GitHub App tokens](build-trigger-polling-and-github-app-tokens.md)
