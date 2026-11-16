# ${{ values.name }}

${{ values.description }}

Python service created from the koorikla/platform golden path (`templates/python-service`): FastAPI on uvicorn,
dependencies locked with uv, ruff + pytest, distroless Python 3.13 image. Owner: `${{ values.owner }}`, OpenChoreo
project `${{ values.project }}`.

## Endpoints

- `GET /` → `{"message", "hostname", "version"}`
- `GET /healthz` → `{"status": "ok"}`
- `GET /version` → `{"version": "<git sha>"}`

Configuration: `PORT` (default `8080`), `GREETING` (default `hello`), `APP_VERSION` (set from the image build).

## Develop

```sh
mise install                       # Python + uv from mise.toml
uv sync                            # .venv from uv.lock
uv run pytest
uv run ruff check . && uv run ruff format --check .
uv run python -m app               # http://localhost:8080
docker build -t ${{ values.name }}:dev .   # ruff + pytest run in the build stage
```

Add a dependency with `uv add <pkg>` (commit `uv.lock`; the image build uses `--locked`).

## CI and delivery

`.github/workflows/ci.yaml` calls the reusable `koorikla/ci` workflows, pinned by commit SHA (`# v1`, Renovate keeps
them current): manifest validation, multi-arch image build + scan (pull requests) or build, push, SBOM, provenance and
keyless signature (`main`), then the `bump` job pins the new image digest in `deploy/openchoreo/workload.yaml` and
OpenChoreo deploys it to `development`. Until koorikla/ci ships its Python workflow the image build is the test gate.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate). Repository settings and rulesets are declared in koorikla/platform (`GitHubRepository`, reconciled by Crossplane).
