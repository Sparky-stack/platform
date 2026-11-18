---
title: mise Global vs Repo Tool Versions and Python Env Var Leakage
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [ci, agents, supply-chain]
confidence: high
---

# mise Global vs Repo Tool Versions and Python Env Var Leakage

## Symptom
1. Running `./hack/image-audit.sh` or `./hack/test.sh` from a subagent or non-interactive shell started in `$HOME` fails with `yq` expression errors or unexpected `helm` template output (PR #171).
2. The Python probe in `./hack/test.sh` fails inside background agent processes even after `mise install`.

## Cause
- **Global vs worktree `mise` pins:** Non-interactive shells started outside the worktree (or in an untrusted worktree where `mise trust` was not run) resolve `$HOME` global tool versions (`yq 4.53.6`, `helm 4.3.0`) instead of the repository's `mise.toml` pins.
- **Agent runtime Python variables:** Background agent runners sometimes export `PYTHONHOME`, `PYTHONPATH`, or `PYTHON`, which breaks system `/usr/bin/python3` imports used by `hack/check-docs.py` and diagram/test scripts.

## Fix
- Run `mise trust` once in every new git worktree.
- Always invoke repo scripts from inside the worktree via:
  `env -u PYTHONHOME -u PYTHONPATH -u PYTHON PATH=/usr/bin:$PATH mise exec -- ./hack/test.sh`
- Avoid version-fragile `yq` `if/then/else` constructs in `hack/` scripts and print the offending file name on parse failures (PR #171).

## Where enforced
- `mise.toml`, `hack/image-audit.sh`, and `hack/test.sh`.

## Links
- PR #171
- Authoritative docs: [docs/dev-environment.md](../../docs/dev-environment.md)
- Related wiki: [Fold koorikla/ci into platform repo and pin tooling with mise](../decisions/fold-ci-into-platform-and-mise-toolchain.md), [Gemini transcript ceiling for agents](gemini-transcript-ceiling-for-agents.md)
