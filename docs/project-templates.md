# Golden-path project templates

Tenants create new services from Backstage (OpenChoreo console, *Create*): one Backstage scaffolder `Template` per
framework, kept in this repo under [`templates/`](../templates/catalog-info.yaml). The scaffolder only does **day 0**:
it creates the repository with its content and opens a pull request in the platform repo. Everything after that is
declarative: repository settings and rulesets come from a governance record that Crossplane reconciles
([#100](https://github.com/koorikla/platform/issues/100)); the app is wired into its tenant by the merged PR and
deployed by Argo CD + OpenChoreo ([openchoreo.md](openchoreo.md#tenants)).

## Templates

| Template | Stack | CI (koorikla/platform app-*, pinned by SHA `# ci-v1.0.0`) | Runtime image |
|---|---|---|---|
| `go-service` | Go, stdlib `net/http` | `go.yaml` | distroless static |
| `python-service` | Python 3.13, FastAPI, uv, ruff, pytest | `python.yaml` | distroless python3 |
| `node-fastify-service` | Node.js 26, Fastify, pnpm, eslint, vitest | `node.yaml` | distroless nodejs26 |
| `rust-service` | Rust, axum, tokio (static musl binary) | `rust.yaml` | distroless static |
| `java-quarkus-service` | Java 25, Quarkus (REST, health, metrics); the recommended Java path | `java.yaml` | distroless java25 |
| `docker-service` | any language, bring your own `Dockerfile` | `container.yaml` | distroless static (placeholder) |

Each stack workflow runs the stack's linters, tests, dependency audit and CodeQL, then calls `container.yaml`, which
builds, scans, signs and attests the multi-arch image; the Dockerfile's build stage runs the tests again, so
`docker build` alone also fails on a broken test. More frameworks
(Elixir, Next.js, Ruby, Spring Boot, NestJS, Helm chart, GraphQL):
[#59](https://github.com/koorikla/platform/issues/59).

Every generated service repository contains:

- the app with unit tests, `GET /healthz` and `GET /version`, listening on `PORT` (8080);
- a multi-arch `Dockerfile`: bases pinned by index digest, non-root runtime on distroless, tests in the build stage;
- `.github/workflows/ci.yaml`: two reusable-workflow calls and no code: the app-* build (PRs build + scan; `main`
  pushes, signs and attests; from the next ci release it also validates `deploy/openchoreo/` via
  `app-openchoreo-manifests.yaml`), then `app-workload-bump.yaml` pins `<image>:<sha>@sha256:<digest>` in the
  Workload, which OpenChoreo deploys to `development`. Generated repos carry no `hack/` scripts;
- `deploy/openchoreo/`: `Component` (autoDeploy), `Workload`, `release-bindings/{development,staging,production}.yaml`
  ([openchoreo.md](openchoreo.md#app-repo-contract)); staging and production move by PR ([promotion.md](promotion.md));
- `catalog-info.yaml`, `.github/CODEOWNERS`, `renovate.json` (bases, actions and the app-* workflow SHA), `SECURITY.md`,
  a README with the golden-path workflow.

`catalog-info.yaml` declares a `Resource` (type `repository`, `dependencyOf` the component), not a `Component`:
OpenChoreo's catalog provider already publishes `component:default/<name>` from the OpenChoreo Component, and a second
entity with the same ref would conflict.

### Platform API: `crossplane-api`

Not a service (`spec.type: platform-api`): a repository for a new platform API as a Crossplane Configuration package,
laid out by `crossplane project init` - `crossplane-project.yaml`, `apis/api/{definition,composition}.yaml` (an XRD
for the chosen kind / plural / group and its Composition), `functions/compose/` (embedded function-go-templating
function, one file per composed resource; copied without templating), `examples/example.yaml`, `tests/`,
`operations/`, `mise.toml` (the platform's Crossplane CLI) and the same `catalog-info.yaml` (type
`crossplane-configuration`), CODEOWNERS, renovate.json and SECURITY.md. `.github/workflows/ci.yaml` calls
`app-crossplane-configuration.yaml` pinned at `# ci-v1.1.1` (Crossplane Project builds need ci-v1.1.0 or later; not
the `ci-v1.0.0` commit Kyverno trusts for app images: Crossplane packages are not admitted by Kyverno). The platform PR
carries only the governance record (no tenant file, no OpenChoreo `deploy/`); installing the API is a later
`addons/crossplane` change ([crossplane.md](crossplane.md#adding-a-new-api)). The developer loop is
[crossplane.md "Inner loop"](crossplane.md#inner-loop-crossplane-cli-24-project-tooling-beta). Contract:
`hack/tests/test_crossplane_api_template.sh` (`TEMPLATES_BUILD=1` also renders the example and runs `crossplane
project build` on the generated repository).

## Scaffolder flow

1. **Parameters**: name (repository = Component = image), description, owner group, tenant (OpenChoreo project), *new
   tenant* yes/no, installation, GitHub owner, visibility, code owners.
2. `fetch:template` the shared skeleton (`templates/_shared/skeleton`) and the stack skeleton; workflow files are
   copied without templating (GitHub expressions are not template placeholders).
3. `publish:github`: creates the repository and pushes `main`. No `token` input: the GitHub integration authenticates
   as the platform write GitHub App. `protectDefaultBranch: false` and nothing else: branch protection, rulesets,
   merge settings, permissions and App installations are repo governance (#100), never set here.
4. `publish:github:pull-request` to the platform repo with
   - `installations/<inst>/repos/<name>.yaml`: the `GitHubRepository` governance record (shape from #100);
   - for a new tenant, `installations/<inst>/tenants/<project>.yaml` with the app. For an existing tenant the PR
     description carries the `apps` entry to add before merging (fetch:template cannot merge into an existing file;
     [#108](https://github.com/koorikla/platform/issues/108)).
5. `catalog:register` of the new repo's `catalog-info.yaml`.

Merging the PR lets Argo CD sync the tenant: the app's Application syncs `deploy/openchoreo/`, and the first CI run on
`main` bumps the Workload, so the service serves in `development`. Production admits only images signed by the
app-container.yaml workflow for listed repositories: before the first production promotion the new repo goes into addon
kyverno-policies `imageVerification.github.repositories` (installation overlay; the PR description says so,
[#108](https://github.com/koorikla/platform/issues/108)). The skeletons pin the app-* workflows at the same commit Kyverno
trusts (`imageVerification.github.workflowRef`; the test fails when they drift).

## Backstage wiring

OpenChoreo's Backstage (addon openchoreo-control-plane) reads extra config from
`openchoreo-control-plane.backstage.appConfig` (ConfigMap `backstage-extra-config`, loaded last):

- `catalog.locations` adds the url location `https://github.com/koorikla/platform/blob/main/templates/catalog-info.yaml`
  (a `Location` listing every `template.yaml`). Backstage replaces arrays across config files, so the list repeats the
  image's own locations (org groups and the 14 OpenChoreo wizards of openchoreo-ui v1.3.3); re-check it on a chart bump.
- `catalog.rules` allows `Template` only from this repo's `templates/catalog-info.yaml`, and `Resource` (the generated
  repos' `catalog-info.yaml`). Backstage checks the entities a `Location` emits against that Location's origin (the
  configured url), so the rule matches `catalog-info.yaml` exactly; a pattern on `*/template.yaml` never matches.

Templates are read from `main` of the public repo; Backstage reads it anonymously until the GitHub App below is set
(GitHub's unauthenticated rate limit applies).

Backstage reads its config files only at start, and the upstream Deployment has no checksum annotation for its
ConfigMaps. Addon `reloader` on mgmt (`addons/reloader/values/role-mgmt.yaml`) watches the ConfigMaps labelled
`app.kubernetes.io/component=backstage` in `openchoreo-control-plane` and rolls Backstage when one changes, so a
merged `appConfig` change is live after Argo CD's sync plus a Backstage restart (~1-2 min), with no manual step.

### Repository creation

The publish steps need the platform write GitHub App ([forking.md](forking.md#what-needs-which-credential) (c)).
GitHub lets an App installation create repositories only in an **organisation**, not on a personal account
([#109](https://github.com/koorikla/platform/issues/109)), so the scaffolder needs an org for the new app repos. The
App is owned by that org and installed twice: on the org (create repos) and on the platform repo (open the platform
PR). Example below: org `Sparky-stack`, platform repo `koorikla/platform`.

1. **Create the org** (web UI only, github.com has no API for it): *github.com/account/organizations/new?plan=free*,
   owned by your personal account.
2. **Create the App from a manifest**, so the permissions are exactly (c) and the private key goes straight to a file:

   ```bash
   python3 hack/github-app.py manifest --org Sparky-stack      # review the permissions first (no network)
   python3 hack/github-app.py create --org Sparky-stack        # open http://127.0.0.1:8765/ and click Create
   ```

   The browser must be logged in as an owner of the org. The script writes `~/keys/<slug>.pem` (mode 0600) and
   `~/keys/<slug>.json` (App ID, slug: not secret) and never prints the key. To finish on a phone, expose the port
   through an HTTPS tunnel you control and pass its URL, e.g.
   `tailscale serve --bg --https=8443 --set-path /ghapp http://127.0.0.1:8765/ghapp` and
   `--public-url https://<host>.ts.net:8443/ghapp` (plain http is refused off loopback; remove the path afterwards
   with `tailscale serve --https=8443 --set-path /ghapp off`).
3. **Install the App twice** from *github.com/apps/&lt;slug&gt;/installations/new*: on the org with
   *All repositories* (repos the scaffolder creates are covered at once), and on the platform repo's owner with
   *Only select repositories* = the platform repo. Check both with the App's own credentials:

   ```bash
   python3 hack/github-app.py installs --slug sparky-stack-scaffolder   # installation IDs, selection, permissions
   ```

4. **Seed it** (`task secrets`, [forking.md](forking.md#seeding-locally-task-secrets)):
   `GITHUB_PUSH_APP_ID=<App ID> GITHUB_PUSH_APP_INSTALLATION_ID=<org installation ID>
   GITHUB_PUSH_APP_PRIVATE_KEY_FILE=~/keys/<slug>.pem`. Backstage reads only the App ID and key and looks up the
   installation per repository owner itself; `task secrets` requires the installation ID for the store key.
5. **Switch it on** in the installation's `installations/<inst>/addons/openchoreo-control-plane/values.yaml`, with both
   owners in `allowedInstallationOwners`:

```yaml
scaffolder:
  githubApp:
    enabled: true            # ExternalSecret backstage-github-app <- platform store key platform-github-app
openchoreo-control-plane:
  backstage:
    extraEnv:
      - name: GITHUB_APP_ID
        valueFrom: { secretKeyRef: { name: backstage-github-app, key: app-id } }
      - name: GITHUB_APP_PRIVATE_KEY
        valueFrom: { secretKeyRef: { name: backstage-github-app, key: private-key } }
    appConfig:
      integrations:
        github:
          - host: github.com
            apps:
              - appId: ${GITHUB_APP_ID}
                privateKey: ${GITHUB_APP_PRIVATE_KEY}
                clientId: not-used          # required by Backstage's schema; only user OAuth would use them
                clientSecret: not-used
                allowedInstallationOwners: [Sparky-stack, koorikla]   # org of the new repos + platform repo owner
```

`templates/validate.yaml` of the addon fails the render when only one side is set. Argo CD read access to the new
repos (public repos need none; private ones need the read App (a) installed on the org), production admission
(Kyverno `imageVerification.github.repositories`) and the promotion gate App (c2) on each new repo are separate steps;
the end-to-end run is tracked in [#109](https://github.com/koorikla/platform/issues/109).

## Adding a template

1. `templates/<name>/template.yaml`: copy an existing one; only `metadata`, the `fetch-stack` step title and the
   `stack` values may differ (the test compares parameters and steps).
2. `templates/<name>/skeleton/`: app + tests, `Dockerfile` (digest-pinned bases, non-root distroless/Chainguard
   runtime, tests in the build stage, `GET /healthz` on 8080), `.github/workflows/ci.yaml`, README. Skeletons may use
   only `${{ values.<key> }}` (optionally `| dump` or `| lower`); `{%` and `{#` are refused because nunjucks would
   parse them in code.
3. Add it to `templates/catalog-info.yaml`.
4. `bash hack/tests/test_project_templates.sh` (part of `task test`; a non-service template gets its own test, like
   `test_crossplane_api_template.sh`); `TEMPLATES_BUILD=1` also builds and smoke-tests
   the images (needs Docker; CI workflow `templates.yaml` runs it on amd64 and arm64).

Forks: change `github.com?owner=koorikla&repo=platform`, the `repoOwner` enum in every template and the catalog url
location in the addon values to your own repo and owner.
