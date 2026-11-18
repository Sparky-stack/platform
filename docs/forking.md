# Run it from your own fork

The platform is GitOps all the way down: Argo CD on the management cluster reads **one git repo** and builds everything
else from it. To run your own copy you fork that repo, point the GitOps root at the fork, give the platform the
credentials it needs (and no more), and boot. This page takes a DevOps engineer from zero to a running local
installation, then shows what changes for AWS / Hetzner.

| Step | Command | Time |
|---|---|---|
| [1. Fork and clone](#1-fork-and-clone) | `gh repo fork koorikla/platform --clone` | 2 min |
| [2. Point the fork at itself](#2-point-the-fork-at-itself) | `task set-repo REPO=https://github.com/<you>/platform.git` | 1 min |
| [3. Credentials](#3-credentials) | env vars + `task secrets` (local) / your secret manager (cloud) | 0-15 min |
| [4. Boot](#4-boot) | `task up` | 20-30 min (first boot; image pulls dominate) |
| [5. Troubleshooting](#5-troubleshooting) | | |

## 1. Fork and clone

| Repo | Fork it? | Why |
|---|---|---|
| [koorikla/platform](https://github.com/koorikla/platform) | **yes** | bootstrap, charts, addons, installations: the GitOps root |
| [koorikla/hello-world](https://github.com/koorikla/hello-world) | optional | example tenant app (`installations/local/tenants/demo.yaml`). Fork it to see your own CI build, push and roll out an image; skip it to deploy the upstream image as-is |
| [`ci/`](https://github.com/koorikla/platform/tree/main/ci) | optional | reusable workflows hello-world calls (`uses: koorikla/platform/.github/workflows/app-go.yaml@<sha> # ci-v1`). Fork it only if you want to own the build logic; otherwise pin the upstream tag or, better, a commit SHA |

```bash
gh repo fork koorikla/platform --clone && cd platform     # or fork in the UI and git clone
gh repo fork koorikla/hello-world                         # optional
mise trust && mise install                                # pinned toolchain (docs/dev-environment.md)
task doctor                                               # every tool at the version in mise.toml
```

Forks of public repos are public. A public fork needs **no repo credentials at all**. For a private copy, create an
empty private repo and mirror into it instead of forking:

```bash
git clone --bare https://github.com/koorikla/platform.git && cd platform.git
git push --mirror https://github.com/<you>/platform.git && cd .. && rm -rf platform.git
git clone https://github.com/<you>/platform.git
```

In the fork's **Actions** tab, enable workflows (GitHub disables them on forks). `ci.yaml` and `portability.yaml`
only need `contents: read` and store nothing. For dependency updates, install the
[Renovate GitHub App](https://github.com/apps/renovate) on the fork; `renovate.json` has nothing org-specific in it.

## 2. Point the fork at itself

```bash
task set-repo REPO=https://github.com/<you>/platform.git
git commit -am "chore: point GitOps at my fork" && git push
```

`hack/set-repo.sh` is idempotent (a second run reports `Nothing to change`) and prints every file it changed. It
rewrites:

| What | Files | Key |
|---|---|---|
| GitOps repo | `bootstrap/root-app.yaml`, `charts/platform/values.yaml`, `installations/*/installation.yaml`, the fallback in `bootstrap/bootstrap.sh` | `repoURL` |
| repo-creds prefix (one Argo CD credential for every repo under it) | `charts/platform/values.yaml`, `installations/*/installation.yaml` | `installation.githubOrg` |
| Tenant app repos owned by `koorikla` (or your previous org) | `installations/*/tenants/*.yaml` | `apps[].repoURL` |

| Variable | Default | Use |
|---|---|---|
| `REPO` | required | `https://<host>/<owner>/<name>.git` (ssh URLs are rejected: Argo CD credentials here are HTTPS) |
| `ORG` | `REPO` minus `/<name>.git` | repo-creds prefix, if your app repos live in another org than the platform repo |
| `APPS_ORG` | `ORG` | org of the tenant app repos. `APPS_ORG=https://github.com/koorikla` keeps the upstream hello-world when you did not fork it |
| `DOCS=1` | off | also rewrite links in `README.md`, `docs/*.md` (except this page: its fork and mirror steps must keep naming upstream) and `docs/diagrams/src/build.py` (then run `python3 docs/diagrams/src/build.py`): `koorikla/platform` URLs and `[koorikla/platform]` link texts become `REPO` (a renamed fork gets its own name), `koorikla/hello-world` and `ghcr.io/koorikla/` follow `APPS_ORG` |

`make set-repo REPO=... ORG=... APPS_ORG=... DOCS=1` works too.

What it deliberately leaves alone, and what you edit by hand if it applies:

| Still says koorikla | Action |
|---|---|
| Label and annotation keys `platform.koorikla.io/*`, `addons.platform.koorikla.io/*` | **keep**: they are an API contract between the CAPI clusters, Argo CD cluster secrets and ApplicationSets (docs/conventions.md), not an org name. Renaming them means renaming every selector at once |
| Chart defaults in `addons/*/values.yaml` (e.g. `addons/secret-stores` `installation.githubOrg`) | keep: only used when a chart renders standalone; every generated Application gets `installation.yaml`, which `set-repo` rewrote. The unit tests assert the defaults |
| Links in prose and diagrams | `DOCS=1`, or leave them: they describe upstream. Plain-text mentions (`gh repo fork koorikla/platform`, diagram box titles) stay either way |
| Your hello-world fork: `deploy/openchoreo/workload.yaml` `image: ghcr.io/koorikla/hello-world:<sha>` | nothing: the first CI run on your fork's `main` builds `ghcr.io/<you>/hello-world` and commits the new tag. Until then the upstream (public) image runs |
| Your hello-world fork: `uses: koorikla/platform/.github/workflows/app-go.yaml@<sha> # ci-v1` | keep (public, but pin a SHA), or point it at your platform fork and change the `uses:` owner |
| `.devcontainer/devcontainer.json` name, `mise.toml` comment, schema cache dir `koorikla-platform` | cosmetic |

## 3. Credentials

Principles (AGENTS.md "Current practice only"): a **GitHub App** with short-lived installation tokens is the primary
GitHub credential; a **fine-grained PAT**, scoped to the selected repos with an expiry, only as fallback; **no classic
PATs**; cloud access through **workload identity / OIDC**, not static keys; image signing **keyless**. Every secret
reaches the clusters through External Secrets Operator from one ClusterSecretStore, `platform`, which only the mgmt
namespaces that consume it may read (docs/architecture.md "Secrets"):

| `secrets.backend` | Where the keys below live | How you put them there |
|---|---|---|
| `kubernetes` (local) | namespace `platform-secrets` on mgmt | `task secrets` (part of `task up`) from the env vars below |
| `aws` | AWS Secrets Manager, secret name `<secrets.aws.prefix><key>`, JSON object of properties | `aws secretsmanager create-secret --name platform-github --secret-string file://platform-github.json` (create the file with `umask 077` and delete it afterwards, see below) |
| `vault` | Vault / OpenBao KV v2 at `<secrets.vault.path>/<key>` | `vault kv put platform/platform-github githubAppID=... githubAppInstallationID=... githubAppPrivateKey=@app.pem` |

### What needs which credential

| Need | Key (properties) | Least privilege | Seeded locally from |
|---|---|---|---|
| **(a)** Argo CD reads the fork (+ app repos) when private | `platform-github` (`githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`) or fallback (`username`, `token`) | GitHub App, *Repository permissions*: **Contents: Read**, Metadata: Read; installed on *only select repositories*. Fallback: fine-grained PAT, same repos, Contents: Read-only, ≤ 90 days. Deploy keys are per repo and do not fit the org-wide repo-creds template | `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, `GITHUB_APP_PRIVATE_KEY_FILE`, or `PLATFORM_GITHUB_TOKEN` [+ `PLATFORM_GITHUB_USER`] |
| **(b)** k3s nodes pull private images from GHCR | `platform-ghcr` (`username`, `token`) | Prefer **no credential**: make the packages public and set `secrets.nodeRegistryAuth.enabled: false` (`installations/local` already does: the koorikla images are public). GHCR does not accept GitHub App tokens or fine-grained PATs outside Actions: ["GitHub Packages only supports authentication using a personal access token (classic)"](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry) (check before relying on it; GitHub may close the gap). A classic PAT goes against this repo's rules, so it needs an explicit security sign-off: dedicated machine user, `read:packages` only (UI trap: ticking `write:packages` also selects the whole `repo` scope), short expiry. With Harbor (`registry.type: harbor`) nodes pull through its proxy cache with robot `nodes`, and a GHCR credential is needed only in Harbor (`secrets.ghcrKey`, docs/build-plane.md) | `GHCR_TOKEN` + `GHCR_USER` |
| **(c)** The platform pushes to git with a GitHub App: Backstage scaffolder (golden-path templates, opt-in: [project-templates.md](project-templates.md#repository-creation)) | `platform-github-app` (`githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`) | a **second** GitHub App: Contents: Read and write, Pull requests: Read and write, Metadata: Read; Workflows: Read and write only if it commits `.github/workflows/*` (scaffolder templates); Administration: Read and write only for scaffolder repo creation (org installation). Fallback: fine-grained PAT with the same permissions | `GITHUB_PUSH_APP_ID`, `GITHUB_PUSH_APP_INSTALLATION_ID`, `GITHUB_PUSH_APP_PRIVATE_KEY_FILE` |
| **(c2)** The promotion gate opens promotion PRs and sets the required status `openchoreo/promotion-gate` (ClusterWorkflow `promotion-gate`, docs/promotion.md); in-cluster builds clone app repos and commit the signed image ref (docs/build-plane.md "Git credentials") | `promotion-gate-github` (`githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`) | a **dedicated** GitHub App, so branch protection can pin the required status to it and nothing else holds this right: Contents: Read and write, Pull requests: Read and write, Commit statuses: Read and write, Metadata: Read; installed on *only select repositories* = the app repos (not the platform repo). Per run the gate mints an installation token restricted to the component's own repository and revokes it at the end; no PAT fallback; every build gets its own token for its one repository (Contents: write only, ESO generator, expires after 1 h) | `GITHUB_GATE_APP_ID`, `GITHUB_GATE_APP_INSTALLATION_ID`, `GITHUB_GATE_APP_PRIVATE_KEY_FILE` |
| **(d)** GitHub Actions in your forks (build, push to GHCR, sign, bump the Workload) | nothing to store | `GITHUB_TOKEN` with `packages: write`, `contents: write` for the bump commit, `id-token: write` for keyless cosign (Fulcio/Rekor); hello-world's `ci.yaml` already declares them | n/a |
| **(e)** Cloud and extras | `capi-aws`, `capi-hetzner`; external-dns `external-dns-*`; OpenChoreo AI agents' LLM keys | see docs/providers.md (CAPA should use IRSA / Pod Identity instead of `AWS_B64ENCODED_CREDENTIALS` where possible; CAPH needs an hcloud token) and the addon's doc | your secret manager |

One read App and one read-write App: keep them separate so the Argo CD credential (which every sync uses) cannot
write. Both can be installed on the same repos. The promotion gate has its own third App (c2): it is the only identity
allowed to set the required promotion status.

### Creating the GitHub App (read, for Argo CD)

1. *Settings → Developer settings → GitHub Apps → New GitHub App* (under your org for org repos). Name e.g.
   `<you>-platform-argocd`, any homepage URL, **untick Webhook → Active**.
2. *Repository permissions*: Contents **Read-only** (Metadata Read-only is added automatically). Nothing else.
3. *Where can this GitHub App be installed?* Only on this account. Create.
4. Note the **App ID** on the app's page. *Generate a private key* (downloads a `.pem`; store it in your password
   manager, `chmod 600` it while it is on disk (`task secrets` warns otherwise), delete the download after seeding).
5. *Install App* → *Only select repositories* → your platform fork (+ app repos). The **installation ID** is the last
   number of the URL you land on (`.../settings/installations/<id>`).
6. Tell the secret-stores addon to template Argo CD's GitHub App fields instead of username/password: create
   `installations/<inst>/addons/secret-stores/values.yaml`:

   ```yaml
   repoCreds:
     auth: githubApp     # properties githubAppID, githubAppInstallationID, githubAppPrivateKey of key platform-github
   ```

Argo CD then mints and refreshes the installation tokens (1 h lifetime) itself; nothing long-lived beyond the App key
is stored.

### Seeding locally (`task secrets`)

`task secrets` (run by `task up`, safe to re-run) writes the keys into namespace `platform-secrets` on the k3d mgmt.
It picks GitHub read credentials in this order and tells you which it used. Keep tokens out of your shell history:
read them without echo, or from your password manager:

```bash
# Preferred: GitHub App (read-only). IDs are not secret; the key stays in its file.
export GITHUB_APP_ID=123456 GITHUB_APP_INSTALLATION_ID=7890123 GITHUB_APP_PRIVATE_KEY_FILE=~/keys/platform-argocd.pem
# Fallback: fine-grained PAT (github_pat_...), Contents: Read-only on the selected repos
read -rs PLATFORM_GITHUB_TOKEN && export PLATFORM_GITHUB_TOKEN PLATFORM_GITHUB_USER=<you>
#   or: export PLATFORM_GITHUB_TOKEN="$(op read op://Private/platform-argocd/token)"   # 1Password; `pass show ...` etc.
# Optional: private GHCR images (see (b) above)
read -rs GHCR_TOKEN && export GHCR_TOKEN GHCR_USER=<machine-user>
# Optional: push App (see (c) above)
export GITHUB_PUSH_APP_ID=... GITHUB_PUSH_APP_INSTALLATION_ID=... GITHUB_PUSH_APP_PRIVATE_KEY_FILE=~/keys/platform-bot.pem
# Optional: promotion gate App (see (c2) above); without it the gate runs every check but fails at the PR step
export GITHUB_GATE_APP_ID=... GITHUB_GATE_APP_INSTALLATION_ID=... GITHUB_GATE_APP_PRIVATE_KEY_FILE=~/keys/promotion-gate.pem
task secrets
unset PLATFORM_GITHUB_TOKEN GHCR_TOKEN
```

**Without the (c2) App the stack still converges Healthy.** The features that cannot work without it are not
rendered: auto-build (addon openchoreo-platform, and argo-events' webhook) and PR previews (the preview token in
secret-stores, every tenant's preview ApplicationSet). Their ESO `GithubAccessToken` generators would otherwise fail
and leave those apps Degraded (#192). The promotion gate stays (it fails closed at the PR step) and builds fail at
checkout. The switch is the installation value `secrets.githubGateApp.enabled` (default `false`, charts/platform):
- backend `kubernetes`: `task up` / `task secrets` set it on the root app from whether `promotion-gate-github` is
  seeded (seed it later and re-run `task secrets`: the features appear); `false` in installation.yaml keeps them off;
- other backends: set `true` in installation.yaml once the key is in your store.

`PLATFORM_GITHUB_TOKEN` is deliberately not `GITHUB_TOKEN`: dev shells, devcontainers and Codespaces often export a
broad token under that name. `GITHUB_TOKEN` [+ `GITHUB_USER`] is still read, with a warning; classic (`ghp_`) and
OAuth (`gho_`) tokens warn too.

With none of these set it falls back to your `gh auth login` token (local convenience only: that OAuth token carries
broad scopes; `NO_GH=1` disables the fallback) and, if there is no `gh` login either, skips `platform-github`, which
is fine for a public fork (the `platform-repo-creds` ExternalSecret then reports a missing key; harmless). The gh token
goes into `platform-ghcr` (and so onto every node) only when `nodeRegistryAuth` is on and the token has
`read:packages`. A gh copy an earlier run left there is deleted once `nodeRegistryAuth` is off (while it is on, new
nodes need it: it is kept and reported until you replace it with `GHCR_USER`/`GHCR_TOKEN`).

The same sources feed the bootstrap Argo CD secret `platform-repo-bootstrap` that lets Argo CD read a private fork
before ESO runs. Once ESO's `platform-repo-creds` is Ready for `installation.githubOrg`, the bootstrap secret is
deleted: `task up` waits up to `REPO_CREDS_WAIT` seconds (default 600, `0` skips) for that, and any later
`task argocd` finishes the job. Generated platform secrets (`openchoreo`, `openchoreo-observability`: Thunder,
Backstage, OpenSearch) are created once and kept on re-runs.

Every secret is built by `yq` from environment variables / files and applied with `kubectl apply --server-side`
(field manager `platform-bootstrap`): no token appears in a process list, and no `last-applied-configuration` copy is
stored.

**Public images, no GHCR token** (the `installations/local` default): new cluster nodes wait for `platform-ghcr` while
`secrets.nodeRegistryAuth` is on (the chart default), so turn it off in `installations/<inst>/installation.yaml`:

```yaml
secrets:
  backend: kubernetes
  kubernetes:
    namespace: platform-secrets
  nodeRegistryAuth:
    enabled: false        # all images public: no k3s registries.yaml, no platform-ghcr
```

`task secrets` warns when it is on and no GHCR credential was given. For the AWS backend, build the JSON without
leaving a readable file behind:

```bash
( umask 077 && read -rs TOKEN                       # subshell: your shell keeps its umask, TOKEN dies with it
  printf '{"username":"git","token":"%s"}' "$TOKEN" > platform-github.json
  aws secretsmanager create-secret --name platform-github --secret-string file://platform-github.json
  rm -f platform-github.json )
```

### Cloud installations

`task up INST=<inst>` targets the management cluster of your current kubeconfig context. With `secrets.backend: aws`
or `vault` it creates no k3d cluster and seeds nothing into the cluster: it installs Argo CD with the GitOps values
and applies the root Application for `installations/<inst>/installation.yaml`. Create the keys in the backend first
(table above), with the same property names. Argo CD's bootstrap secret still comes from
`GITHUB_APP_*` / `PLATFORM_GITHUB_TOKEN` if you export them (no `gh` fallback outside the local backend). ESO authenticates to
AWS with IRSA / EKS Pod Identity (`secrets.aws.role`), to Vault with its Kubernetes auth role: no static keys.

## 4. Boot

```bash
task up         # k3d mgmt, secrets, Argo CD, root app; then everything else is Argo CD
task status     # CAPI clusters, Argo CD apps, ClusterDataPlanes, how to read the Argo CD admin password
```

What happens, roughly (8-CPU / 16 GB Linux host; a warm image cache is faster; other hosts:
[#60](https://github.com/koorikla/platform/issues/60)):

| Minute | What |
|---|---|
| 0-2 | k3d cluster `platform-mgmt` (docker network `kind`, ports `127.0.0.1:8080/8443/9443/11080/11085/8200`), `platform-secrets` seeded, Argo CD installed, root Application applied |
| 2-10 | Argo CD syncs the catalog onto mgmt: cert-manager, ESO + stores, CAPI operator + providers, Gateway API, kgateway, Thunder, OpenChoreo control plane, observability plane |
| 5-20 | CAPD creates `dev1` (kindest/node containers; `prod1` too in the multicluster profile), its kubeconfig becomes an Argo CD cluster secret, addons land on it, the OpenChoreo data plane connects |
| 15-30 | tenant `demo`: hello-world released to `development` |

Watch it with `task ui` (Argo CD on http://localhost:8081, user `admin`; it prints the command that reads the password,
never the password) or
`kubectl --context k3d-platform-mgmt get applications -n argocd -w`. A few Applications show `Unknown`/`OutOfSync`
and retry until the CRDs they need exist: expected (docs/openchoreo.md "Ordering").

| URL | What | Login |
|---|---|---|
| http://localhost:8081 (`task ui`) | Argo CD | `admin` / the command `task status` prints (secret `argocd-initial-admin-secret`) |
| http://openchoreo.localhost:8080 | OpenChoreo console (Backstage) | `admin@openchoreo.dev` / property `admin-user-password` (or `developer@openchoreo.dev` / `developer-user-password`) |
| http://api.openchoreo.localhost:8080 | OpenChoreo API (+ `/mcp`) | same users (OIDC via Thunder) |
| http://thunder.openchoreo.localhost:8080/console | ThunderID admin console | `admin` / property `thunder-admin-password` |
| https://harbor.openchoreo.localhost:9443 | Harbor registry (trust its CA: docs/build-plane.md "Ports and DNS") | `admin` / key `harbor` property `admin-password` |
| http://observer.openchoreo.localhost:11080 | observability (logs, metrics, traces) API; browse it through the console | via the console |
| `development-default.dev1.apps.localhost:19080/hello-world-http/` | hello-world on `dev1` (container IP, not published; docs/openchoreo.md "App traffic") | none |

Read a seeded password:

```bash
kubectl --context k3d-platform-mgmt -n platform-secrets get secret openchoreo \
  -o jsonpath='{.data.admin-user-password}' | base64 --decode; echo
```

Tear down: `task down`. It freezes Argo CD first (application and applicationset controllers to 0 replicas: with
selfHeal on, a running controller re-creates every deleted Cluster), deletes the CAPD clusters (`DOWN_TIMEOUT`, default
5m), removes CAPD node containers of the installation's clusters that are still left, then deletes the k3d mgmt. To
delete only the CAPD clusters, freeze the same way first (`task up`/`task argocd` restores the replicas). Cloud
installations have no `down`: delete cluster files from git and let CAPI clean up.

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pods `Pending`/`OOMKilled`, CAPD nodes never `Ready`, Docker Desktop becomes unresponsive | not enough resources for k3d + the CAPD cluster(s) | give the Docker VM ≥ 8 CPUs / 16 GB (Docker Desktop *Settings → Resources*; Colima `colima start --cpu 8 --memory 16`); `bootstrap.sh` also wants ≥ 15 GB free disk. The default profile runs one CAPD cluster; the multicluster profile (`prod1.yaml`) needs ~3.5 GB more (docs/dev-environment.md "Local profiles") |
| `k3d cluster create` fails with `port is already allocated` / `address already in use` | something else holds `127.0.0.1:8080`, `8443`, `9443`, `11080`, `11085` or `8200` (or `8081` for `task ui`) | `lsof -nP -iTCP:8080 -sTCP:LISTEN` (Windows: `netstat -ano \| findstr :8080`) and stop it. Remapping is not a quick fix: the same port numbers are baked into the OIDC issuer and gateway URLs that pods and browsers share (docs/openchoreo.md "Local networking"). `task ui` alone: `kubectl -n argocd port-forward svc/argocd-server 18081:80` |
| `too many open files`, kubelet / k3s crash-loops, `failed to create fsnotify watcher` | inotify limits, multiplied by many k3s nodes on one kernel | Linux: `sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512` (persist in `/etc/sysctl.d/`); Docker Desktop / Colima: raise them inside the VM (docs/dev-environment.md "Host differences") |
| `ImagePullBackOff` / `401 Unauthorized` from `ghcr.io`, or new CAPD nodes stuck before `Ready` | private image without `platform-ghcr`, a token without `read:packages`, or `nodeRegistryAuth` on with no `platform-ghcr` at all | make the package public (*Package settings → Change visibility*; new GHCR packages start private) and set `secrets.nodeRegistryAuth.enabled: false`, or export `GHCR_USER`/`GHCR_TOKEN` and `task secrets` (existing nodes keep their `registries.yaml`: recreate the cluster) |
| Argo CD keeps deploying an old commit, or `ComparisonError: repository not found` after `set-repo` | repo-server cache, or the root app still points at the old URL | `kubectl --context k3d-platform-mgmt -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite` (same for any app; or *Refresh → Hard refresh* in the UI). Old URL: you pushed the `set-repo` commit? then `task argocd` re-applies the root app. Private fork: check `platform-repo-bootstrap` / `platform-repo-creds` in ns `argocd` and that the App is installed on the repo |

More: docs/dev-environment.md (Docker Desktop, WSL2, Windows), docs/openchoreo.md "Known issue: re-created data plane
clusters", docs/networking.md.
