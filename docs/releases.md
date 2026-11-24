# Releases

Two release lines, both cut by [release-please](https://github.com/googleapis/release-please) from the
conventional-commit titles of squash-merged PRs (`feat:` minor, `fix:` patch, `feat!:` / `BREAKING CHANGE:` major;
before 1.0.0 a breaking change bumps the minor).

| Line | Tag | Covers | Changelog | Who consumes it |
|---|---|---|---|---|
| platform | `vX.Y.Z` (from `v0.1.0`) | everything except `ci/` | [CHANGELOG.md](../CHANGELOG.md) | forks / installations tracking a platform release |
| ci | `ci-vX.Y.Z` (from `ci-v1.0.0`) | `ci/` (scripts, toolbox, fixtures) | [ci/CHANGELOG.md](../ci/CHANGELOG.md) | app repos: `uses: Sparky-stack/platform/.github/workflows/app-<stack>.yaml@<sha> # ci-vX.Y.Z`, Kyverno `imageVerification.github.workflowRef` |

## How a release happens

1. PRs merge to `main` with conventional-commit titles (the prek `conventional-commit` hook warns locally).
2. [`.github/workflows/release.yaml`](../.github/workflows/release.yaml) keeps one open PR `chore: release main` with
   the next versions and changelog entries.
3. Merging that PR creates the tags and GitHub Releases.
4. A new `ci-v*` tag: Renovate opens PRs moving the Kyverno `workflowRef` and the app repos' `uses:` pins to its commit
   (both carry the tag as a `# ci-vX.Y.Z` comment). Merge the platform PR first so new images are admitted.

The workflow authenticates as the `koorikla-promotion-gate` GitHub App (repository variable `RELEASE_APP_ID`, secret
`RELEASE_APP_PRIVATE_KEY`), because PRs opened with `GITHUB_TOKEN` don't trigger CI.

Config: [release-please-config.json](../release-please-config.json), current versions:
[.release-please-manifest.json](../.release-please-manifest.json). Limitation: release-please assigns commits by path,
so a PR that only touches `.github/workflows/app-*.yaml` counts for the platform line; put `Release-As: x.y.z` in the
release PR or touch `ci/` (e.g. `ci/CHANGELOG.md`) when a workflow-only change must cut a `ci-v*` release.
