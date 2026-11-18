# ${{ values.name }}

${{ values.description }}

Node.js API created from the koorikla/platform golden path (`templates/node-fastify-service`): Fastify on Node.js 26,
pnpm with a frozen lockfile, eslint + vitest, distroless Node.js image. Owner: `${{ values.owner }}`, OpenChoreo
project `${{ values.project }}`.

## Endpoints

- `GET /` → `{"message", "hostname", "version"}`
- `GET /healthz` → `{"status": "ok"}`
- `GET /version` → `{"version": "<git sha>"}`

Configuration: `PORT` (default `8080`), `GREETING` (default `hello`), `APP_VERSION` (set from the image build).

## Develop

```sh
mise install                 # Node.js + pnpm from mise.toml
pnpm install
pnpm lint && pnpm test
pnpm dev                     # http://localhost:8080, restarts on change
docker build -t ${{ values.name }}:dev .   # eslint + vitest run in the build stage
```

## CI and delivery

`.github/workflows/ci.yaml` calls the reusable `app-*` workflows (koorikla/platform), pinned by commit SHA (`# ci-v1.0.0`, Renovate keeps
them current): manifest validation, multi-arch image build + scan (pull requests) or build, push, SBOM, provenance and
keyless signature (`main`), then the `bump` job pins the new image digest in `deploy/openchoreo/workload.yaml` and
OpenChoreo deploys it to `development`. Until koorikla/platform ships its Node.js workflow the image build is the test gate.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate). Repository settings and rulesets are declared in koorikla/platform (`GitHubRepository`, reconciled by Crossplane).
