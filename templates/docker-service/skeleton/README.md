# ${{ values.name }}

${{ values.description }}

Container service created from the koorikla/platform golden path (`templates/docker-service`): any language, bring
your own `Dockerfile`. Owner: `${{ values.owner }}`, OpenChoreo project `${{ values.project }}`.

The placeholder `Dockerfile` serves `www/` with busybox httpd on distroless static. Replace it with your build and keep
the contract the platform relies on:

- multi-arch (`linux/amd64`, `linux/arm64`) and base images pinned by digest (Renovate keeps them current);
- a non-root runtime user, ideally a distroless or Chainguard base;
- HTTP on port `8080` with `GET /healthz` (or change `deploy/openchoreo/workload.yaml` accordingly).

## Develop

```sh
docker build -t ${{ values.name }}:dev .
docker run --rm -p 8080:8080 ${{ values.name }}:dev     # http://localhost:8080/healthz
```

## CI and delivery

`.github/workflows/ci.yaml` calls the reusable workflow `app-container.yaml` (koorikla/platform), pinned by commit SHA (`# ci-v1.0.0`,
Renovate keeps it current): multi-arch build and Trivy scan on pull requests; on `main` also push to
`ghcr.io/<owner>/${{ values.name }}`, SPDX SBOM, SLSA provenance and a keyless cosign signature. The `bump` job then
pins the new image digest in `deploy/openchoreo/workload.yaml` and OpenChoreo deploys it to `development`.

Staging and production move by pull request: set `spec.releaseName` in `deploy/openchoreo/release-bindings/<env>.yaml`
to the release running in the previous environment. Production is gated (code-owner review + the platform's promotion
gate). Repository settings and rulesets are declared in koorikla/platform (`GitHubRepository`, reconciled by Crossplane).
