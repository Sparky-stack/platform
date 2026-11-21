# Security policy

Report a vulnerability privately through GitHub: *Security → Report a vulnerability* on this repository (private
vulnerability reporting). Do not open a public issue.

What the golden path already does for every change (`.github/workflows/ci.yaml` → koorikla/platform app-* workflows):

- dependency and image scanning (Trivy) on every pull request;
- on `main`: multi-arch image with an SPDX SBOM, SLSA provenance and SBOM attestations, a keyless cosign signature;
- production on koorikla/platform admits only digest-pinned images signed by the koorikla/platform app-container.yaml workflow.

Dependency updates come from Renovate (`renovate.json`).
