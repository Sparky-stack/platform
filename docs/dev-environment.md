# Developer environment

One toolchain, pinned once, on **macOS, Linux and Windows, amd64 and arm64**: [mise](https://mise.jdx.dev) installs
every CLI at the version in [`mise.toml`](../mise.toml), [Task](https://taskfile.dev) runs every entrypoint from
[`Taskfile.yml`](../Taskfile.yml), and the scripts behind them are portable bash. `make <target>` still works: the
`Makefile` is a one-line-per-target shim for `task <target>`.

| Host | Status | Proof |
|---|---|---|
| Linux amd64 / arm64 | supported | `portability` workflow (`ubuntu-latest`, `ubuntu-24.04-arm`): `mise install`, `task lint test` |
| macOS arm64 (Apple Silicon) / amd64 | supported (offline validation proven; `task up` **VERIFY**) | `macos-latest`, scripts forced onto the stock `/bin/bash` 3.2 |
| Windows 11 + WSL2 | **recommended on Windows**: it is Linux | as Linux |
| Windows amd64, Git Bash | `doctor`/`lint`/`test` (incl. schemas) proven; `task up` **VERIFY** | `windows-latest`, `shell: bash` |
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
task lint test                                          # `task up` here is VERIFY, prefer WSL2 for clusters
```

**Zero install**: open the repo in VS Code *Dev Containers*, GitHub Codespaces or DevPod. `.devcontainer/` brings
Ubuntu 24.04 + its own Docker engine (docker-in-docker feature v4: it picks iptables-nft at start on kernels without
legacy iptables, which GitHub's amd64 runners need) and runs `mise install` on create. Codespaces needs the 8-core /
32 GB machine for the full local platform (**VERIFY**: sized from the k3d + two CAPD clusters footprint).

Without mise activated in your shell, prefix commands with `mise exec --` (`mise exec -- task test`) or use
`make test` (the shim falls back to `mise exec -- task` when `task` is not on `PATH`). `task doctor` reports missing
tools and version drift against `mise.toml`.

## Entrypoints

`task --list` is the source of truth. `make <name>` maps to `task <name>` (`make images-audit` -> `task images:audit`).

| Task | What |
|---|---|
| `setup` | `mise install` + helm-unittest plugin |
| `doctor` | every tool from `mise.toml` present at the pinned version |
| `up` / `secrets` / `argocd` / `status` / `ui` / `down` | bootstrap stages (`INST=local` default; `task up INST=aws-example`) |
| `kubeconfig CLUSTER=dev1` | host-usable kubeconfig of a CAPD workload cluster (see Docker Desktop below) |
| `set-repo REPO=https://github.com/<you>/platform.git` | point a fork at itself: `repoURL`, `githubOrg`, tenant app repos (`ORG=`, `APPS_ORG=`, `DOCS=1`; docs/forking.md) |
| `lint` / `test` / `schemas` | offline validation (helm lint/template, kubeconform, helm-unittest, contract tests, shellcheck, actionlint) |
| `images:audit` | every image of the installation checked for linux/amd64 + linux/arm64 (`-- --live` adds running pods) |
| `tools:lock` | refresh `mise.lock` for all six platforms after editing `mise.toml` |
| `clean` | drop downloaded chart dependencies |

## Why mise + Task

- **mise** reads one file, installs prebuilt, checksum-verified binaries for each OS/arch, and activates them per
  directory. Every tool uses the **aqua** backend (upstream release assets; the aqua registry entry declares the
  supported platforms) except Python (mise core, python-build-standalone). `mise.lock` pins the exact URL + checksum
  for `linux-{x64,arm64}`, `macos-{x64,arm64}`, `windows-{x64,arm64}`; all 84 assets were checked to exist. Renovate
  bumps `mise.toml` natively.
- **Task** is a single Go binary with its own POSIX shell interpreter, so the Taskfile runs unchanged on Windows,
  where Make is not installed by default. Targets and variables mirror the old Makefile.
- **Rejected**: Nix / devbox / flox (no native Windows; WSL only), asdf (plugins are shell scripts, no Windows),
  Homebrew bundles (macOS/Linux only), per-tool curl installers in scripts (what CI did before: amd64-Linux-only, no
  checksums, versions duplicated between CI and docs).

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
| shellcheck / actionlint | 0.11.0 / 1.7.12 | aqua | `task lint` |
| python | 3.14.10 | core:python | `hack/crd2schema.py`, test helpers (stdlib only) |
| task | 3.54.0 | aqua:go-task/task | entrypoint |
| gh | 2.104.0 | aqua:cli/cli | `task secrets` falls back to `gh auth token` when no `GITHUB_APP_*` / `GITHUB_TOKEN` is set |

Docker is the one prerequisite mise does not install (Docker Desktop, OrbStack, Colima, Rancher Desktop or Docker
Engine). Git Bash comes with Git for Windows.

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
| Workload cluster kubeconfig on the host | `task kubeconfig CLUSTER=dev1` keeps the LB IP | `task kubeconfig CLUSTER=dev1` rewrites the server to `127.0.0.1:<port the <name>-lb container publishes>` (a k3s cert SAN; verified with `KUBECONFIG_MODE=published`) |
| App URLs on CAPD nodes (`*.dev1.apps.localhost:19080`, docs/openchoreo.md) | `curl --resolve ...:$NODE_IP` | run the client inside the network: `docker run --rm --network kind curlimages/curl:8.22.0 --resolve development-default.dev1.apps.localhost:19080:$NODE_IP http://development-default.dev1.apps.localhost:19080/hello-world-http/` |
| `127.0.0.1:8080/8443/11080/11085` (k3d LB) | published on loopback | published on the host loopback too (Docker Desktop forwards) |
| `/var/run/docker.sock` mounted into the k3d node (CAPD) | host socket | the VM's socket; Docker Desktop, OrbStack, Colima and Rancher Desktop all provide `/var/run/docker.sock` inside their VM. Native Windows k3d may reject the Unix path (**VERIFY**; use WSL2) |
| inotify limits (many k3s nodes) | `bootstrap.sh` warns below 524288 watches | limits live in the VM kernel: `docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=8192` (resets when the VM restarts) **VERIFY** |
| Resources | host RAM | give the VM >= 8 CPUs / 16 GB (Docker Desktop: Settings -> Resources) **VERIFY** |
| `*.localhost` names (`openchoreo.localhost:8080`) | browsers and curl resolve to loopback | same in browsers and curl; other CLIs on macOS/Windows may need `/etc/hosts` / `C:\Windows\System32\drivers\etc\hosts` entries |

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

Result for `installations/local` (with `--live` against the running k3d mgmt; includes Cilium, Istio ambient,
Kyverno): **76 images, all multi-arch (linux/amd64 + linux/arm64), none single-arch**. Hygiene findings from the same inventory (for the addon owners, not arch problems):

| Image | Note |
|---|---|
| `curlimages/curl` (falco chart) | no tag: pin it (`curlimages/curl:8.22.0` is already used by telemetry) |
| `busybox:latest` (openchoreo-observability-plane) | `latest` tag, not fully qualified |
| `curlimages/curl:8.22.0` (telemetry), `opensearchproject/opensearch:3.3.0` (observability plane), `kindest/node:v1.35.8` (clusterclasses), `rancher/k3s:v1.35.10-k3s1` (bootstrap/k3d-mgmt.yaml) | not fully qualified (`docker.io/...`), invariant 9 |
| `kindest/haproxy:...`, `rancher/*` k3s system images | set by CAPD / k3s upstream, not by this repo |
| `gcr.io/k8s-staging-cluster-api/capd-manager:v1.13.8` | CAPD is only published to the staging registry (dev/test provider), expected |

Apps built by koorikla/ci must publish multi-arch images too, or arm64 hosts will fail to run them on CAPD clusters.

## Updating a tool

1. Edit the version in `mise.toml` (or merge the Renovate PR).
2. `task tools:lock` (writes the six platform URLs + checksums into `mise.lock`), `mise install`, `task test`.
3. The `portability` workflow re-runs on any change to `mise.toml`, `mise.lock`, `Taskfile.yml`, `hack/**`,
   `bootstrap/**` or `.devcontainer/**`, and weekly.
