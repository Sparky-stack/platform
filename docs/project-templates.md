# Golden-path project templates

Tenants create new services from Backstage (OpenChoreo console, *Create*): one Backstage scaffolder `Template` per
framework, kept in this repo under [`templates/`](../templates/catalog-info.yaml). The scaffolder only does **day 0**:
it creates the repository with its content and opens a pull request in the platform repo. Everything after that is
declarative: repository settings and rulesets come from a governance record that Crossplane reconciles
([#100](https://github.com/koorikla/platform/issues/100)); the app is wired into its tenant by the merged PR and
deployed by Argo CD + OpenChoreo ([openchoreo.md](openchoreo.md#tenants)).

## Templates

| Template | Stack | CI (koorikla/ci, pinned by SHA `# v1`) | Runtime image |
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
(Elixir, Next.js, Ruby, Spring Boot, NestJS, Crossplane configuration, Helm chart, GraphQL):
[#59](https://github.com/koorikla/platform/issues/59).

Every generated repository contains:

- the app with unit tests, `GET /healthz` and `GET /version`, listening on `PORT` (8080);
- a multi-arch `Dockerfile`: bases pinned by index digest, non-root runtime on distroless, tests in the build stage;
- `.github/workflows/ci.yaml`: manifest validation, the koorikla/ci build (PRs build + scan; `main` pushes, signs and
  attests), then `bump` pins `<image>:<sha>@sha256:<digest>` in the Workload, which OpenChoreo deploys to
  `development`;
- `deploy/openchoreo/`: `Component` (autoDeploy), `Workload`, `release-bindings/{development,staging,production}.yaml`
  ([openchoreo.md](openchoreo.md#app-repo-contract)); staging and production move by PR ([promotion.md](promotion.md));
- `catalog-info.yaml`, `.github/CODEOWNERS`, `renovate.json` (bases, actions and the koorikla/ci SHA), `SECURITY.md`,
  a README with the golden-path workflow.

`catalog-info.yaml` declares a `Resource` (type `repository`, `dependencyOf` the component), not a `Component`:
OpenChoreo's catalog provider already publishes `component:default/<name>` from the OpenChoreo Component, and a second
entity with the same ref would conflict.

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
koorikla/ci workflow for listed repositories: before the first production promotion the new repo goes into addon
kyverno-policies `imageVerification.github.repositories` (installation overlay; the PR description says so,
[#108](https://github.com/koorikla/platform/issues/108)). The skeletons pin koorikla/ci at the same commit Kyverno
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

### Repository creation

The publish steps need the platform write GitHub App ([forking.md](forking.md#what-needs-which-credential) (c):
Contents, Pull requests and Workflows read/write, Administration write for repository creation; installed on the
owner of the new repos and on the platform repo). Seed it with `GITHUB_PUSH_APP_*` (`task secrets`), then switch it on
in the installation's `installations/<inst>/addons/openchoreo-control-plane/values.yaml`:

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
                allowedInstallationOwners: [koorikla]
```

`templates/validate.yaml` of the addon fails the render when only one side is set. GitHub lets an App installation
create repositories only in an organisation; on a personal account the publish step fails
([#109](https://github.com/koorikla/platform/issues/109)).

## Adding a template

1. `templates/<name>/template.yaml`: copy an existing one; only `metadata`, the `fetch-stack` step title and the
   `stack` values may differ (the test compares parameters and steps).
2. `templates/<name>/skeleton/`: app + tests, `Dockerfile` (digest-pinned bases, non-root distroless/Chainguard
   runtime, tests in the build stage, `GET /healthz` on 8080), `.github/workflows/ci.yaml`, README. Skeletons may use
   only `${{ values.<key> }}` (optionally `| dump` or `| lower`); `{%` and `{#` are refused because nunjucks would
   parse them in code.
3. Add it to `templates/catalog-info.yaml`.
4. `bash hack/tests/test_project_templates.sh` (part of `task test`); `TEMPLATES_BUILD=1` also builds and smoke-tests
   the images (needs Docker; CI workflow `templates.yaml` runs it on amd64 and arm64).

Forks: change `github.com?owner=koorikla&repo=platform`, the `repoOwner` enum in every template and the catalog url
location in the addon values to your own repo and owner.
