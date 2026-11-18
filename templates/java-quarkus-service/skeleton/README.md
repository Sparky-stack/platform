# ${{ values.name }}

${{ values.description }}

Java service created from the koorikla/platform golden path (`templates/java-quarkus-service`), the recommended Java
path: Quarkus REST with health (`/q/health`) and Prometheus metrics (`/q/metrics`), JVM mode on distroless Java 25.
Owner: `${{ values.owner }}`, OpenChoreo project `${{ values.project }}`.

## Endpoints

- `GET /` → `{"message", "hostname", "version"}`
- `GET /healthz` → `{"status": "ok"}`
- `GET /version` → `{"version": "<git sha>"}`
- `GET /q/health/live`, `GET /q/health/ready`, `GET /q/metrics`

Configuration (`src/main/resources/application.properties`): `PORT` (default `8080`), `GREETING` (default `hello`),
`APP_VERSION` (set from the image build).

## Develop

```sh
mise install                 # Temurin 25 + Maven from mise.toml
mvn quarkus:dev              # live reload, Dev UI at http://localhost:8080/q/dev-ui, Dev Services
mvn verify                   # @QuarkusTest suite
docker build -t ${{ values.name }}:dev .   # mvn verify runs in the build stage
```

A native image (Mandrel: faster start, less memory, slower build) is opt-in:
`mvn package -Dquarkus.native.enabled=true -Dquarkus.native.container-build=true`, shipped on
`gcr.io/distroless/cc-debian13` instead of the Java runtime image.

## CI and delivery

`.github/workflows/ci.yaml` calls the reusable `app-*` workflows (koorikla/platform), pinned by commit SHA (`# ci-v1.0.0`, Renovate keeps
them current): manifest validation, multi-arch image build + scan (pull requests) or build, push, SBOM, provenance and
keyless signature (`main`), then the `bump` job pins the new image digest in `deploy/openchoreo/workload.yaml` and
OpenChoreo deploys it to `development`. Until koorikla/platform ships its Java workflow the image build is the test gate.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate). Repository settings and rulesets are declared in koorikla/platform (`GitHubRepository`, reconciled by Crossplane).
