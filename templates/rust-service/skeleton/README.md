# ${{ values.name }}

${{ values.description }}

Rust service created from the koorikla/platform golden path (`templates/rust-service`): axum on tokio, a static musl
binary on distroless static (about 10 MB). Owner: `${{ values.owner }}`, OpenChoreo project `${{ values.project }}`.

## Endpoints

- `GET /` → `{"message", "hostname", "version"}`
- `GET /healthz` → `{"status": "ok"}`
- `GET /version` → `{"version": "<git sha>"}`

Configuration: `PORT` (default `8080`), `GREETING` (default `hello`), `RUST_LOG` (default `info`); the version is
compiled in from the image build (`APP_VERSION`).

## Develop

```sh
mise install                 # Rust from mise.toml
cargo fmt --check && cargo clippy --all-targets -- -D warnings
cargo test
cargo run                    # http://localhost:8080
docker build -t ${{ values.name }}:dev .   # fmt, clippy and tests run in the build stage
```

## CI and delivery

`.github/workflows/ci.yaml` calls the reusable `koorikla/ci` workflows, pinned by commit SHA (`# v1`, Renovate keeps
them current): manifest validation, multi-arch image build + scan (pull requests) or build, push, SBOM, provenance and
keyless signature (`main`), then the `bump` job pins the new image digest in `deploy/openchoreo/workload.yaml` and
OpenChoreo deploys it to `development`. Until koorikla/ci ships its Rust workflow the image build is the test gate.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate). Repository settings and rulesets are declared in koorikla/platform (`GitHubRepository`, reconciled by Crossplane).
