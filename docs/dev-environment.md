# Developer environment

One toolchain, pinned once, on **macOS, Linux and Windows, amd64 and arm64**: [mise](https://mise.jdx.dev) installs
every CLI at the version in [`mise.toml`](../mise.toml), [Task](https://taskfile.dev) runs every entrypoint from
[`Taskfile.yml`](../Taskfile.yml), and the scripts behind them are portable bash. `make <target>` still works: the
`Makefile` is a one-line-per-target shim for `task <target>`.

| Host | Status | Proof |
|---|---|---|
| Linux amd64 / arm64 | supported | `portability` workflow (`ubuntu-latest`, `ubuntu-24.04-arm`): `mise install`, `task lint test` |
| macOS arm64 (Apple Silicon) / amd64 | supported (offline validation proven; `task up` not yet, [#60](https://github.com/koorikla/platform/issues/60)) | `macos-latest`, scripts forced onto the stock `/bin/bash` 3.2 |
| Windows 11 + WSL2 | **recommended on Windows**: it is Linux | as Linux |
| Windows amd64, Git Bash | `doctor`/`lint`/`test` (incl. schemas) proven; `task up` not yet ([#60](https://github.com/koorikla/platform/issues/60)) | `windows-latest`, `shell: bash` |
| Windows on Arm | as above; helm/yq/argocd ship native arm64, jq/k3d/shellcheck run x64-emulated | lock entries only |
| Dev container / Codespaces | zero-install option, amd64 + arm64 | `devcontainer` job builds it, starts its Docker engine and runs `task doctor lint` on both arches |

## Install (three lines per OS)

**macOS** (Docker Desktop, OrbStack or Colima as the engine)
```bash
brew install mise git && echo 'eval "$(mise activate zsh)"' >> ~/.zshrc && exec zsh
cd platform && mise trust && mise install      # all tools + helm-unittest plugin
task up                                        # or: make up
```

**Linux** (Docker Engine; your user in the `docker` group)
```bash
curl -fsSL https://mise.run | sh && echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc && exec bash
cd platform && mise trust && mise install
task up
```

**Windows, WSL2 (recommended)**: install Docker Desktop with *WSL integration* for your distro (or Docker Engine
inside the distro), clone the repo **inside the WSL filesystem** (`~/src`, not `/mnt/c`: 10x faster, no CRLF or
permission surprises), then follow the Linux lines in the WSL shell.

**Windows, native (Git Bash)**
```bash
winget install jdx.mise Git.Git Docker.DockerDesktop    # PowerShell, once; then open "Git Bash"
cd platform && mise trust && mise install && export PATH="$HOME/AppData/Local/mise/shims:$PATH"
task lint test                                          # for clusters prefer WSL2
```

**Zero install**: open the repo in VS Code *Dev Containers*, GitHub Codespaces or DevPod. `.devcontainer/` brings
Ubuntu 24.04 + its own Docker engine (docker-in-docker feature v4: it picks iptables-nft at start on kernels without
legacy iptables, which GitHub's amd64 runners need) and runs `mise install` on create. Codespaces needs the 8-core /
32 GB machine for the full local platform (estimated from the k3d + two CAPD clusters footprint).

Without mise activated in your shell, prefix commands with `mise exec --` (`mise exec -- task test`) or use
`make test` (the shim falls back to `mise exec -- task` when `task` is not on `PATH`). `task doctor` reports missing
tools and version drift against `mise.toml`.

## Entrypoints

`task --list` is the source of truth. `make <name>` maps to `task <name>` (`make images-audit` -> `task images:audit`).

| Task | What |
|---|---|
| `setup` | `mise install` + helm-unittest plugin + git hooks |
| `doctor` | every tool from `mise.toml` present at the pinned version |
| `up` / `secrets` / `argocd` / `status` / `ui` / `down` | bootstrap stages (`INST=local` default; `task up INST=aws-example`) |
| `kubeconfig CLUSTER=dev1` | host-usable kubeconfig of a CAPD workload cluster (see Docker Desktop below) |
| `set-repo REPO=https://github.com/<you>/platform.git` | point a fork at itself: `repoURL`, `githubOrg`, tenant app repos (`ORG=`, `APPS_ORG=`, `DOCS=1`; docs/forking.md) |
| `hooks:install` / `hooks:run` | install the git hooks / run every hook on every tracked file, as CI does ([Git hooks](#git-hooks)) |
| `lint` / `test` / `schemas` | offline validation (helm lint/template, kubeconform, helm-unittest, contract tests, shellcheck, actionlint) |
| `images:audit` | every image of the installation checked for linux/amd64 + linux/arm64 (`-- --live` adds running pods) |
| `tools:lock` | refresh `mise.lock` for all six platforms after editing `mise.toml` |
| `clean` | drop downloaded chart dependencies |

## Why mise + Task

- **mise** reads one file, installs prebuilt, checksum-verified binaries for each OS/arch, and activates them per
  directory. Every tool uses the **aqua** backend (upstream release assets; the aqua registry entry declares the
  supported platforms) except Python (mise core, python-build-standalone). `mise.lock` pins the exact URL + checksum
  for `linux-{x64,arm64}`, `macos-{x64,arm64}`, `windows-{x64,arm64}`. Renovate bumps `mise.toml` natively.
- **Task** is a single Go binary with its own POSIX shell interpreter, so the Taskfile runs unchanged on Windows,
  where Make is not installed by default. The Makefile maps each target to `task <target>`.
- **Rejected**: Nix / devbox / flox (no native Windows; WSL only), asdf (plugins are shell scripts, no Windows),
  Homebrew bundles (macOS/Linux only), per-tool curl installers in scripts (amd64-Linux-only, no checksums, versions
  duplicated between CI and docs).

| Tool | Version | Backend | Why |
|---|---|---|---|
| kubectl | 1.35.10 | aqua:kubernetes/kubernetes/kubectl | matches k3s v1.35 on mgmt + workload clusters |
| helm | 4.3.2 | aqua:helm/helm | charts, lint, template; plugin `helm-unittest` 1.2.1 (postinstall hook) |
| k3d | 5.8.3 | aqua:k3d-io/k3d | local mgmt cluster (5.9.0 exists; 5.8.3 is the version the live boot proved) |
| clusterctl | 1.13.8 | aqua:kubernetes-sigs/cluster-api | = CAPI core of `addons/capi-providers` |
| argocd | 3.6.1 | aqua:argoproj/argo-cd | = Argo CD server |
| yq / jq | 4.54.3 / 1.8.2 | aqua:mikefarah/yq / aqua:jqlang/jq | YAML/JSON in scripts |
| kubeconform | 0.8.0 | aqua:yannh/kubeconform | schema validation |
| crane | 0.22.1 | aqua:google/go-containerregistry | `images:audit` |
| cosign | 3.1.4 | aqua:sigstore/cosign | `demo:check` verifies the demo image's signature with the pinned identity |
| shellcheck / actionlint | 0.11.0 / 1.7.12 | aqua | `task lint`, git hooks |
| gitleaks | 8.30.1 | aqua:gitleaks/gitleaks | secret scan in the git hooks / CI |
| prek | 0.5.10 | aqua:j178/prek | git hook runner (`prek.toml`) |
| kyverno | 1.20.0 | github:kyverno/kyverno | offline policy tests (`hack/tests/test_kyverno_policies.sh`) |
| python | 3.14.10 | core:python | `hack/crd2schema.py`, test helpers (stdlib only) |
| task | 3.54.0 | aqua:go-task/task | entrypoint |
| gh | 2.104.0 | aqua:cli/cli | `task secrets` falls back to `gh auth token` when no `GITHUB_APP_*` / `PLATFORM_GITHUB_TOKEN` is set |

Docker is the one prerequisite mise does not install (Docker Desktop, OrbStack, Colima, Rancher Desktop or Docker
Engine). Git Bash comes with Git for Windows.

## Git hooks

`task hooks:install` (part of `task setup` and the dev container's post-create; after a plain `mise install` run it
once, `task doctor` warns until you do) installs `pre-commit` and
`commit-msg` shims for this clone and all its worktrees. [prek](https://prek.j178.dev) runs [`prek.toml`](../prek.toml):

| Hook | Files | What |
|---|---|---|
| trailing-whitespace, end-of-file-fixer, mixed-line-ending (`--fix=lf`) | all text | fix in place; re-stage and commit again |
| check-merge-conflict, check-added-large-files (500 KB), check-case-conflict, check-illegal-windows-names | all | stray markers, big blobs, paths macOS/Windows cannot check out |
| check-yaml (`templates/` excluded: Go templates), check-toml, check-json | `*.yaml`, `*.toml`, `*.json` | syntax; check-toml also rejects duplicate keys in `mise.toml` |
| gitleaks | staged files (index content) | secrets; false positives get a `gitleaks:allow` comment on the line, not a broad ignore |
| shellcheck (`-x -P SCRIPTDIR`, as `task lint`), actionlint | `bootstrap/` `hack/` `.devcontainer/` `*.sh`, `.github/workflows/` | |
| py-compile | `*.py` | Python syntax |
| mise-tools-table | `mise.toml` | every `[tools]` entry parses for `task doctor` |
| chart-lock | `Chart.yaml` / `Chart.lock` | lock digest in sync (`hack/lib/chartlock.py`; skipped with a note until it is on `main`) |
| charts | `charts/` `addons/` `installations/` | `CHARTS=<changed charts> hack/test.sh`: helm lint + template per installation/cluster + kubeconform (cached schemas) + helm unittest of the changed charts only; installation/cluster files select `charts/platform` + `charts/cluster`. Everything else is `task test` / CI |
| conventional-commit | commit message | warns, never blocks: squash merges make the PR title the commit on `main` |

Nothing is downloaded at commit time: builtin hooks are compiled into prek, the rest run the `mise.toml` tools and
`hack/hooks.sh`. A typical commit takes about a second; touching an addon adds its renders (~8 s).
`hack/tests/test_hooks_config.sh` fails on a remote hook repo without a full commit SHA, a hook that would build its
own environment, or a tool not pinned in `mise.toml`.

**CI runs the same hooks** on every tracked file (`task hooks:run` in the `ci` and `portability` workflows, all four
OS/arch jobs and the dev container; only `charts` is skipped there because `task test` renders every chart). In an
emergency `git commit --no-verify` skips the hooks locally, and `SKIP=charts,gitleaks git commit` skips single hooks;
CI still fails the PR on any finding.

## Portable bash rules

Scripts stay bash (Task calls them as `bash <script>`), written for **bash 3.2** (macOS default) and both GNU and BSD
userlands; helpers live in [`hack/lib/portable.sh`](../hack/lib/portable.sh).

| Avoid | Use |
|---|---|
| `mapfile` / `readarray`, `declare -A`, `${v,,}`, `&>>` | `while read` loops / `read_lines`, plain arrays, `tr`, `>> f 2>&1` |
| `"${arr[@]}"` on a possibly empty array under `set -u` (bash < 4.4: "unbound variable") | `${arr[@]+"${arr[@]}"}` |
| `sed -i` | `sed_inplace` (temp file; GNU and BSD disagree on `-i`) |
| `base64 -d` | `b64dec` |
| `sha1sum` | `sha1` (shasum on macOS) |
| `df -BG --output`, `readlink -f`, `date -d`, `grep -P`, `xargs -r`, `timeout` | `free_gb` (POSIX `df -Pk`), `cd && pwd`, explicit loops, `curl --connect-timeout` |
| `python3` | `pick_python` / `py` (Windows: `python3` is a Store alias; Python writes CRLF) |
| `/tmp/...` | `mktemp -d` |
| `xdg-open` | `open_url` (`open` / `start` / `wslview` / `xdg-open`) |
| MSYS paths handed to Go/Python binaries | `native_path` (`cygpath -m` on Windows) |

`task lint` runs `bash -n` + shellcheck on every script; the macOS CI job runs the whole suite on `/bin/bash` 3.2.

## Host differences (Docker Desktop and friends)

The local topology (k3d mgmt + CAPD clusters on docker network `kind`) was designed on a Linux host. What changes
elsewhere:

| Topic | Linux host | Docker Desktop (macOS / Windows), OrbStack, Colima, WSL2 + Docker Desktop |
|---|---|---|
| Container IPs on `kind` (CAPD `<name>-kubeconfig`, node IPs) | routable from the host | **not routable** from the host. Inside Docker everything works unchanged (mgmt pods, agents, Argo CD reach the CAPD LB IP) |
| Workload cluster kubeconfig on the host | `task kubeconfig CLUSTER=dev1` keeps the LB IP | `task kubeconfig CLUSTER=dev1` rewrites the server to `127.0.0.1:<port the <name>-lb container publishes>` (a k3s cert SAN; `KUBECONFIG_MODE=published`) |
| App URLs on CAPD nodes (`*.dev1.apps.localhost:19080`, docs/openchoreo.md) | `curl --resolve ...:$NODE_IP` | run the client inside the network: `docker run --rm --network kind curlimages/curl:8.22.0 --resolve development-default.dev1.apps.localhost:19080:$NODE_IP http://development-default.dev1.apps.localhost:19080/hello-world-http/` |
| `127.0.0.1:8080/8443/9443/11080/11085/8200` (k3d LB) | published on loopback | published on the host loopback too (Docker Desktop forwards) |
| `/var/run/docker.sock` mounted into the k3d node (CAPD) | host socket | the VM's socket; Docker Desktop, OrbStack, Colima and Rancher Desktop all provide `/var/run/docker.sock` inside their VM. Native Windows k3d may reject the Unix path (use WSL2) |
| inotify limits (many k3s nodes) | `bootstrap.sh` warns below 524288 watches | limits live in the VM kernel: `docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=8192` (resets when the VM restarts) |
| Resources | host RAM | give the VM >= 8 CPUs / 16 GB (Docker Desktop: Settings -> Resources) |
| `*.localhost` names (`openchoreo.localhost:8080`) | browsers and curl resolve to loopback | same in browsers and curl; other CLIs on macOS/Windows may need `/etc/hosts` / `C:\Windows\System32\drivers\etc\hosts` entries |

Not yet proven with a full `task up` on these hosts: [#60](https://github.com/koorikla/platform/issues/60).

## Local stack load and the mgmt datastore

Measured on the 20-core / 31 GiB reference host with mgmt + dev1 (3 servers) + prod1
([#76](https://github.com/koorikla/platform/issues/76)): the local platform holds ~16 GiB RSS (mgmt ~8.3, each CAPD node
1.6-2.5) plus ~3 GiB swapped. Next to other host workloads that is more than RAM: the host swaps at 100-160 MB/s, I/O
pressure is `full ~30%`, and a load average of 30-40 is mostly tasks waiting on I/O (CPU pressure `some` ~8%, 30% idle),
not CPU. Slow fsyncs then hit both datastores: CAPD k3s (embedded etcd) loses leader election on 5 s lease renewals and
restarts (prod1: 20 restarts in 10 hours), and the k3d mgmt (single k3s server, kine/SQLite) crash-loops.

**Mgmt crash loop (kine/SQLite).** A single-server k3d cluster stores its state in SQLite through kine, and kine compacts
old revisions in batches of 1000 inside a transaction. On this host the first batch's transaction fails and k3s exits
with `level=fatal msg="Transaction commit failed: sql: transaction has already been committed or rolled back"`, about 11
minutes after every start, forever: the compaction never advances (`compactRev=1150478` on every logged attempt while
`currentRev` grew 1227790 -> 1257927), so the database only grows (`state.db` 0.9 GB + `state.db-wal` 0.9 GB). Every
restart also restarts all mgmt pods (containerd runs inside k3s: `SandboxChanged`), reruns every controller's initial
list and the Kyverno background scan, and the I/O burst pushes the CAPD clusters' etcd over their lease deadlines.
Embedded etcd compacts incrementally and never exits on a slow compaction; the conversion copies only the current keys.

**Converting a running mgmt to embedded etcd** (data-preserving; needs a maintenance window of ~15 min; Linux paths,
on Git Bash prefix `MSYS_NO_PATHCONV=1`). k3s converts a single SQLite server to etcd when it starts once with
`cluster-init` ([k3s docs](https://docs.k3s.io/datastore/ha-embedded#existing-single-node-clusters)); afterwards the etcd
files on disk select etcd by themselves. The same container is stopped and started, never recreated: its
`/var/lib/rancher/k3s` is an anonymous volume that a recreated node would not get back.

```sh
C=k3d-platform-mgmt-server-0
IMG=$(yq -r .image bootstrap/k3d-mgmt.yaml)                         # same k3s image: has tar and sh
VOL=$(docker inspect "$C" -f '{{range .Mounts}}{{if eq .Destination "/var/lib/rancher/k3s"}}{{.Name}}{{end}}{{end}}')
BK="$HOME/platform-mgmt-backup-$(date +%Y%m%d-%H%M)"; mkdir -p "$BK"  # needs ~2x (server/ + storage/) free, ~12 GB
# 1. stop cleanly (k3s checkpoints the SQLite WAL); CAPD clusters keep running, Argo CD pauses with mgmt
docker stop -t 120 "$C"
# 2. back up the datastore, server identity (token, TLS, credentials) and the local-path PV data; agent/ (images) is
#    re-pullable and not needed
docker run --rm -v "$VOL":/k3s:ro -v "$BK":/backup --entrypoint tar "$IMG" -C /k3s -cf /backup/k3s.tar server storage
tar -tf "$BK/k3s.tar" server/db/state.db server/db/state.db-wal server/token >/dev/null && echo backup-ok
# 3. one start with cluster-init (k3s config file in the container layer; survives stop/start)
printf 'cluster-init: true\n' > "$BK/config.yaml"
docker cp "$BK/config.yaml" "$C":/etc/rancher/k3s/config.yaml
docker start "$C"
docker logs -f --since 2m "$C" 2>&1 | grep -iE 'migrat|sqlite|etcd.*(ready|started)|fatal'   # Ctrl-C once ready
# 4. verify: etcd/ exists and state.db was renamed state.db.migrated (k3s renames it only after a complete copy)
docker exec "$C" ls /var/lib/rancher/k3s/server/db
kubectl --context k3d-platform-mgmt get nodes                       # ROLES control-plane,etcd
kubectl --context k3d-platform-mgmt get applications -n argocd      # Synced/Healthy again within minutes
kubectl --context k3d-platform-mgmt get pvc -A; kubectl --context k3d-platform-mgmt get clusters -n fleet
docker exec "$C" k3s etcd-snapshot save --name post-migration       # first snapshot (default: every 12 h, keep 5)
```

If step 4 shows no `state.db.migrated`, or anything is missing, roll back: k3s would otherwise keep using a partial etcd.
Writes made after the conversion are lost on rollback (Git re-applies them; PV data is not in the datastore).

```sh
docker stop -t 120 "$C"
docker run --rm -v "$VOL":/k3s -v "$BK":/backup --entrypoint sh "$IMG" -c \
  'rm -rf /k3s/server/db && tar -C /k3s -xf /backup/k3s.tar server/db'
printf '{}\n' > "$BK/empty.yaml"; docker cp "$BK/empty.yaml" "$C":/etc/rancher/k3s/config.yaml
docker start "$C"
```

New mgmt clusters run embedded etcd from the start: `bootstrap/k3d-mgmt.yaml` passes `--cluster-init` to server:0
([#76](https://github.com/koorikla/platform/issues/76)). The conversion above is only for a mgmt created before that.

**Leader election on slow disks.** etcd alone does not stop the restarts: k3s runs kube-controller-manager, scheduler and
cloud-controller-manager in-process and exits when one misses its lease renewal (`"leaderelection lost"`). The clean
bootstrap's I/O burst stalled etcd `fdatasync` for 5-8 s and restarted the mgmt k3s 5 times in its first 15 minutes.
Both the k3d mgmt (`bootstrap/k3d-mgmt.yaml`) and the CAPD control planes (ClusterClass `k3s-docker`,
`k3s.dockerLeaderElectionArgs`) run 60 s leases with a 40 s renew deadline instead of upstream 15 s / 10 s
([#82](https://github.com/koorikla/platform/issues/82)). k3d sets server args at create time only: an older mgmt keeps
the short leases until it is re-created; a CAPD cluster gets them through a control-plane rollout.
Check: `docker logs k3d-platform-mgmt-server-0 2>&1 | grep -c 'leaderelection lost'` and
`docker inspect k3d-platform-mgmt-server-0 --format '{{.RestartCount}}'` stay 0.

## Windows notes

- **Line endings**: `.gitattributes` forces LF for scripts, YAML, JSON, TOML and Markdown, so `core.autocrlf=true`
  (the Git for Windows default) cannot break bash or helm values. Re-normalize an old clone with
  `git add --renormalize . && git checkout -- .`.
- **Which bash**: Task resolves `bash` from `PATH`. From PowerShell/cmd that can be `C:\Windows\System32\bash.exe` (the
  WSL launcher). Run tasks from Git Bash, or set `BASH="C:\Program Files\Git\bin\bash.exe"`.
- **Python**: `python3` on a fresh Windows is a Microsoft Store alias that fails; scripts probe and use mise's
  `python`. Turn the alias off in *Settings -> Apps -> Advanced app settings -> App execution aliases* if it bothers you.
- **Paths**: Git Bash rewrites `/c/...` arguments for native programs; scripts pass `cygpath -m` paths
  (`native_path`). If you call tools by hand with Unix-looking arguments that are not paths (e.g. `kubectl exec -- /bin/sh`),
  prefix `MSYS_NO_PATHCONV=1`.
- **Symlinks**: `CLAUDE.md` and `GEMINI.md` are symlinks to `AGENTS.md`; without Developer Mode +
  `git config core.symlinks true` they check out as one-line text files (harmless).
- **Docker socket**: Docker Desktop's engine runs in WSL2 either way; the native path uses the `npipe` socket for the CLI
  and `/var/run/docker.sock` inside the engine VM for containers.

## CPU architecture: image audit

`task images:audit` renders every addon exactly as the ApplicationSets layer it for the installation (mgmt + every
cluster file), adds the k3d node/helper images, the CAPD node and load-balancer images, the CAPI provider controllers
(release components) and the k3s system images (`k3s-images.txt`), and asks the registry (crane) whether each image
publishes `linux/amd64` and `linux/arm64`.

Every image must publish both. The only accepted exceptions are listed, each with an expiry, in
`hack/image-audit.sh` `ARCH_EXCEPTIONS` (today: Harbor 2.15, [build-plane.md](build-plane.md#images-and-architectures));
the audit reports them as `EXCEPTION`. Images that are tag-only or not fully qualified:
[#45](https://github.com/koorikla/platform/issues/45).

Apps built by koorikla/ci must publish multi-arch images too, or arm64 hosts will fail to run them on CAPD clusters.

## Updating a tool

1. Edit the version in `mise.toml` (or merge the Renovate PR).
2. `task tools:lock` (writes the six platform URLs + checksums into `mise.lock`), `mise install`, `task test`.
3. The `portability` workflow re-runs on any change to `mise.toml`, `mise.lock`, `Taskfile.yml`, `hack/**`,
   `bootstrap/**` or `.devcontainer/**`, and weekly.
