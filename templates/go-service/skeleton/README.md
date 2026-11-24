# ${{ values.name }}

${{ values.description }}

Go service created from the Sparky-stack/platform golden path (`templates/go-service`). Owner: `${{ values.owner }}`,
OpenChoreo project `${{ values.project }}`.

## Endpoints

- `GET /` → `{"message", "hostname", "version"}`
- `GET /healthz` → `{"status": "ok"}`
- `GET /version` → `{"version": "<git sha>"}`

Configuration: `PORT` (default `8080`), `GREETING` (default `hello`).

## Develop

```sh
mise install                 # Go from mise.toml
go test -race ./...
go run .
docker build -t ${{ values.name }}:dev .   # runs the unit tests in the build stage
```

## CI and delivery

`.github/workflows/ci.yaml` is two calls to Sparky-stack/platform reusable workflows, pinned by commit SHA (Renovate keeps
them current); there is no CI code in this repository:

1. `build` (`app-go.yaml`): `go vet`, golangci-lint, `go test -race`, govulncheck, CodeQL, multi-arch distroless image.
   Pull requests build and scan only; `main` pushes `ghcr.io/<owner>/${{ values.name }}`, attaches an SBOM and SLSA
   provenance and signs it keylessly. From the platform's next ci release on it also validates `deploy/openchoreo/`
   against the OpenChoreo schemas the platform runs.
2. `bump` (`app-workload-bump.yaml`, push to `main`): pins `<image>:<sha>@sha256:<digest>` and the commit in
   `deploy/openchoreo/workload.yaml`; OpenChoreo deploys it to `development`.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate).

Repository settings and rulesets are not set here: Sparky-stack/platform declares them (`GitHubRepository`, reconciled by
Crossplane).
