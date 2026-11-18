---
title: Gemini Transcript Ceiling and Token Discipline for Subagents
created: 2026-11-18
updated: 2026-11-18
type: gotcha
tags: [agents, ci, docs]
confidence: high
---

# Gemini Transcript Ceiling and Token Discipline for Subagents

## Symptom
Autonomous subagents running on Gemini models (`gemini-4-argon`, `gemini-4-carbon`) abruptly cut off mid-turn or fail after ~40-60 tool calls with a transcript/context ceiling error before committing or opening their PR.

## Cause
- Reading entire large files (`HANDOFF.md`, vendored chart values, or all 60 GitHub issue bodies), running unfiltered `./hack/test.sh` repeatedly during iteration, or opening upstream OpenChoreo skill references about Flux/Kustomize rapidly bloats the conversation transcript.
- Waiting until the very end of a task to make a single monolithic commit loses all work if the session hits the transcript ceiling or an approval timeout.

## Fix
- **Orient via `wiki/index.md` first** instead of re-grepping history from scratch.
- **Read small slices:** Use `offset`/`limit` on `read_file`, query `gh issue list --json number,title` before viewing individual issues, and skip Flux/Kustomize references in upstream OpenChoreo skills.
- **Keep writes and test outputs small:** Keep individual file writes `< 80` lines where practical, run only the targeted `helm unittest` or single `hack/tests/test_*.sh` while iterating, and run full `./hack/test.sh` at most once before pushing.
- **Commit after every meaningful step** and wrap up into a PR within ~30 tool calls.

## Where enforced
- Agent briefs (`gemini-batch.md`), skill `koorikla-openchoreo-gitops`, and `wiki/SCHEMA.md`.

## Links
- Date: 2026-11-18
- Authoritative docs: [AGENTS.md](../../AGENTS.md), [docs/dev-environment.md](../../docs/dev-environment.md)
- Related wiki: [Helm, Crossplane, and OpenChoreo building blocks](../decisions/building-blocks-helm-crossplane-openchoreo.md), [mise global vs repo tool versions](mise-global-vs-repo-tool-versions.md)
