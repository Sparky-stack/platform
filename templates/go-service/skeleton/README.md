# ${{ values.name }}

${{ values.description }}

Go service created from the koorikla/platform golden path (`templates/go-service`). Owner: `${{ values.owner }}`,
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

`.github/workflows/ci.yaml` calls the reusable workflow `app-go.yaml` (koorikla/platform), pinned by commit SHA (`# ci-v1`,
Renovate keeps it current):

1. `validate-manifests`: `deploy/openchoreo/` against the OpenChoreo CRD schemas (`hack/validate-manifests.py`).
2. `build`: `go vet`, golangci-lint, `go test -race`, govulncheck, CodeQL, multi-arch distroless image. Pull requests
   build and scan only; `main` pushes `ghcr.io/<owner>/${{ values.name }}`, attaches an SBOM and SLSA provenance and
   signs it keylessly.
3. `bump` (push to `main`): pins `<image>:<sha>@sha256:<digest>` in `deploy/openchoreo/workload.yaml`; OpenChoreo
   deploys it to `development`.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate).

Repository settings and rulesets are not set here: koorikla/platform declares them (`GitHubRepository`, reconciled by
Crossplane).
