# GitHub repository governance

Repository settings, the default-branch ruleset and collaborators are declared in git and reconciled by Crossplane on
mgmt, so they cannot drift unnoticed (#100). The Backstage scaffolder creates a repository's content on day 0; from day 1
its GitHub settings are a `GitHubRepository` object here.

| Piece | Where |
|---|---|
| Declarations (one entry per repository) | `installations/<inst>/addons/crossplane/cluster-<mgmt>.yaml`, `githubRepos.repositories` |
| API (XRD) and Composition | `addons/crossplane/files/github-repository/{definition,composition}.yaml` |
| Provider | `provider-upjet-github` (crossplane-contrib, `githubRepos.package`, pinned `tag@sha256`), addon crossplane on mgmt |
| Credential | GitHub App **koorikla-repo-admin**, store key `github-repo-admin` ([forking.md](forking.md#what-needs-which-credential) (c3)) |
| Objects | namespace `crossplane-system` on mgmt: `GitHubRepository` XRs, their composed `Repository`, `RepositoryRuleset`, `RepositoryCollaborator` |

Installation `local` governs `Sparky-stack/platform` and `Sparky-stack/hello-world`. Exactly one mgmt per GitHub account turns
`githubRepos.enabled` on: two would fight over the same repositories.

## What a repository looks like

The Composition renders, for each `GitHubRepository`:

- **Repository settings:** squash merges only (the PR title becomes the commit message release-please reads), head
  branches deleted on merge, Dependabot alerts, secret scanning with push protection, issues on, wiki/projects off.
- **Ruleset `main-protection` on the default branch:** no deletion, no force push, linear history; changes through a
  pull request with 0 required approvals but code-owner review, stale reviews dismissed on push, last-push approval and
  resolved threads; squash merge; the status checks in `spec.requiredChecks`, pinned to the GitHub Actions app (15368).
- **Collaborators:** `spec.collaborators` get write access. A personal account has no teams and no other role; on an
  organisation only the Composition changes (teams, repository roles), not the XRD.

The spec is small:

| Field | Meaning |
|---|---|
| `management` | `Observe` or `Full`, required, no default (see below) |
| `description`, `visibility` | Shown on GitHub; `visibility` defaults to `public` |
| `requiredChecks` | Check-run names from GitHub Actions that must pass before a merge |
| `bypassApps` | GitHub App IDs that may push to the default branch without a pull request |
| `collaborators` | GitHub users with write access |
| `rulesetId` | An existing ruleset to observe, and to rewrite in place under `Full` (no second ruleset) |

### Who may bypass the ruleset

| Actor | Mode | Why |
|---|---|---|
| `bypassApps` (local: `koorikla-promotion-gate`, App 5788333) | always | It writes the GitOps hand-off commits into app repos through the contents API ([build-plane.md](build-plane.md#gitops-hand-off)), runs release-please (`.github/workflows/release.yaml`, `RELEASE_APP_ID`) and opens promotion PRs. Its commits are signed by GitHub. A ruleset cannot reliably exempt `github-actions[bot]`, so CI bump commits must come from this App |
| Repository admin (role 5) | pull requests only | Break-glass: the owner can merge a PR the rules block (e.g. their own production change that needs a code-owner review), never push directly |

release-please pushes to its own `release-please--branches--*` branch and creates tags; the ruleset targets only the
default branch, so it does not block either. Renovate and Dependabot open ordinary PRs.
`openchoreo/promotion-gate` is not a required check: it would block every PR that does not touch production. The
planned always-running `promotion-gate-guard` job ([#59](https://github.com/Sparky-stack/platform/issues/59)) goes into
`requiredChecks` once it exists.

## Observe and Full

`management: Observe` composes every object with `managementPolicies: [Observe]`: Crossplane only reads GitHub and
writes what it sees into each object's `status.atProvider`. Nothing on GitHub changes. The ruleset is composed in
Observe only when `rulesetId` names an existing one.

`management: Full` adds `Create`, `Update` and `LateInitialize`: Crossplane creates what is missing (a new repository,
the ruleset, collaborators), enforces the declared settings and reverts changes made in the GitHub UI. `Delete` is never
granted: removing an entry leaves the repository, its ruleset and collaborators on GitHub. A repository is never fully
managed by default: the XRD, the values schema and `hack/tests/test_github_repos.sh` require `management` to be written
down, and the test checks that an `Observe` repository composes read-only objects only.

## Day 2

All commands read mgmt; changes go through git.

### Read the observed state

```bash
kubectl --context k3d-platform-mgmt -n crossplane-system get githubrepositories
kubectl --context k3d-platform-mgmt -n crossplane-system get repositories.repo.github.m.upbound.io,repositoryrulesets.repo.github.m.upbound.io
```

`READY=True` means the provider authenticated and found the object on GitHub. For one repository, compare what git
wants (`spec.forProvider`) with what GitHub has (`status.atProvider`):

```bash
kubectl --context k3d-platform-mgmt -n crossplane-system get repositories.repo.github.m.upbound.io \
  -l crossplane.io/composite=hello-world -o yaml | yq '.items[0] | {"desired": .spec.forProvider, "observed": .status.atProvider}'
```

The same works for `repositoryrulesets.repo.github.m.upbound.io`. Every difference is something `Full` would change on
GitHub.

### Add a repository

1. Add an entry under `githubRepos.repositories` in `installations/<inst>/addons/crossplane/cluster-<mgmt>.yaml`. The key
   is the repository name. An existing repository starts with `management: Observe`. A new one can start with
   `management: Full`: Crossplane then creates it.
2. Install the GitHub App on it: GitHub, Settings, Applications, koorikla-repo-admin, Configure, Repository access.
   Without that the objects report `Resource not accessible by integration`.
3. Merge; Argo CD syncs addon crossplane on mgmt (`crossplane-mgmt`). Check `READY=True` as above.

### Switch to full management

1. Read the observed-vs-desired diff above for the repository and its ruleset. Adjust the entry until the diff contains
   only changes you want. For a hand-made ruleset, set `rulesetId` so Full rewrites it instead of adding a second one.
2. Make sure the App that writes to the default branch is in `bypassApps` and the names in `requiredChecks` are check
   runs that report on every PR. A required check that never reports blocks every merge.
3. Change one line, `management: Observe` to `management: Full`, and merge. Once Argo CD has synced, the changed objects
   reconcile at once and GitHub shows the declared settings and the ruleset `main-protection`.

### How drift is reverted

Under `Full` the provider compares GitHub with the declaration on every poll (every 10 minutes, the provider's default
`--poll`, and at once on every change to the object). A setting changed in the GitHub UI is set back on the next poll; the object's `Synced` condition shows
the update and its errors. Under `Observe` drift is only visible: `status.atProvider` follows GitHub, nothing is
reverted. To change a setting for good, change git (the entry, or the Composition for every repository).

### Roll back

Set `management: Observe` again: Crossplane stops writing at once and leaves GitHub as it is. To undo a change it
made, fix the declaration under `Full`, or change the setting in the GitHub UI while `Observe`.

### Troubleshooting

- `ExternalSecret github-repo-admin` not Ready: the store key is not seeded (`GITHUB_REPO_ADMIN_APP_*`,
  [forking.md](forking.md#seeding-locally-task-secrets)); every object then reports `cannot get credentials`.
- `401` or `Bad credentials`: App ID, installation ID or key do not match; re-seed with `task secrets`.
- `403 Resource not accessible by integration`: the App is not installed on that repository, or lacks
  Administration: write (rulesets, settings, collaborators).

## Not covered yet

Actions variables, GitHub environments with required reviewers, and App installation membership (the provider's
`AppInstallationRepository` needs an organisation installation) are later additions to the Composition. Signed commits
(`required_signatures`, #42) wait until every writer signs.
