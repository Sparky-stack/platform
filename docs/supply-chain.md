# Supply chain

What is verified between a commit and a running pod, and what is not (yet). Promotion gates that use these checks:
[promotion.md](promotion.md).

| Stage | Control | State |
|---|---|---|
| Image build (GitHub) | koorikla/ci reusable workflow `container.yaml`: multi-arch build, Trivy scan, Sigstore keyless signature, SPDX SBOM, SLSA provenance, vuln attestation (cosign v3 bundles) | on (app repos) |
| Image build (in-cluster) | OpenChoreo workflow plane: cosign with the platform key | planned (build plane) |
| Admission, data planes | Kyverno `ImageValidatingPolicy` + `ValidatingPolicy` per environment | on: Audit dev/staging, Deny production |
| Git sources (Argo CD) | AppProject `sourceIntegrity` GnuPG policy | example, off (`sourceIntegrity.enabled`) |
| Helm / OCI charts (Argo CD) | not supported by Argo CD 3.6 | gap, see below |
| Promotion | reviewed PR + gate workflow + VAP (git-only writes) | on |

## Image signatures and attestations at admission

`addons/kyverno-policies/templates/image-verification.yaml` (Kyverno 1.20 CEL policy types only, no ClusterPolicy):

- **Scope**: pods (and through Kyverno autogen, their controllers) in OpenChoreo cell namespaces, chosen by the label
  `openchoreo.dev/environment`. `imageVerification.environments` maps environment → `Audit` | `Deny`. Platform
  namespaces are excluded twice: Kyverno's webhook namespaceSelector and `matchConditions`.
- **GitHub-built images** (`github.prefixes`, default `ghcr.io/koorikla/`):
  - issuer `https://token.actions.githubusercontent.com`;
  - subject = the reusable workflow `https://github.com/koorikla/ci/.github/workflows/container.yaml@refs/tags/v1`;
  - **plus** the certificate extensions `githubWorkflowRepository` (from `github.repositories`) and
    `githubWorkflowRef` (from `github.refs`). The subject alone would accept any repository on GitHub calling the
    public reusable workflow. Kyverno matches extensions exactly, so every allowed (repository, ref) pair renders its
    own attestor, and the validation accepts any of them.
  - Required signed attestations from the same identity: `https://spdx.dev/Document/v2.3` (SBOM),
    `https://slsa.dev/provenance/v1` (provenance), `https://cosign.sigstore.dev/attestation/vuln/v1` (scan).
  - Transparency log: Rekor (`github.rekorURL`).
- **Workflow-plane images** (`platformKey.prefixes`, the registry `apps` project): cosign public key
  (`platformKey.publicKey`, not a secret), no tlog by default. Keyless would need an OIDC issuer that Fulcio trusts
  (a public cluster issuer with workload identity); that is the follow-up. Until a key is configured these images
  cannot be verified, which fails closed in production.
- **Digest pinning**: `requireDigest.Deny: true`. Production rejects tag-only references, development and staging only
  report them. `mutateDigest` is off on purpose: OpenChoreo's agent re-applies the rendered Deployment, and a mutated
  digest would flap.
- **Trusted sources**: `openchoreo-trusted-registries-*` requires every container, init and ephemeral image to match a
  trusted prefix (the sources' prefixes plus `extraTrustedPrefixes`).
- **Failure policy**: production `Fail` (a Kyverno outage pauses production rollouts, never platform namespaces).
  Audit `Ignore`. Webhook timeout 20 s (registry + Rekor/TUF lookups).

Evidence (Kyverno CLI v1.20.0 against the real image
`ghcr.io/koorikla/hello-world:d04ca59@sha256:068979444334cb0dc031d9a286dcd7daed372572a5354135d19e8a471fcb2ec1`):
- `hack/tests/test_kyverno_policies.sh` with `KYVERNO_ONLINE=1`:
  - signature + SBOM + provenance + vuln attestations pass in production;
  - the tag-only reference fails in production and passes in staging.
- Negative checks during development:
  - a wrong `githubWorkflowRepository` or `githubWorkflowRef` is rejected ("expected GithubWorkflowRepository to be
    …");
  - an unknown predicate type is rejected and the error lists the types found.
- Kyverno 1.20 verifies the cosign v3 Sigstore bundle format.

Add an app repo: append its `owner/repo` to `imageVerification.github.repositories` in
`installations/<inst>/addons/kyverno-policies/values.yaml` (a tenant file alone does not trust its images).

## Git commit signatures

Argo CD 3.5+ verifies sources through `AppProject.spec.sourceIntegrity`. The old `signatureKeys` is deprecated and
cannot be combined with it. `charts/platform` (projects `platform`, `fleet`) and `charts/tenant` (`tenant-<project>`)
render this policy when `sourceIntegrity.enabled: true`:

```yaml
sourceIntegrity:
  git:
    policies:
      - repos: [{ url: "https://github.com/koorikla/*" }]
        gpg:
          mode: head                 # none | head | strict
          keys: [B5690EEEBB952194]   # GitHub web-flow key: commits GitHub creates (UI merges, REST API commits)
```

- With GitHub's web-flow key in `head` mode, only commits made by GitHub can deploy: squash-merged PRs, and API
  commits such as the promotion gate's and a CI bump done via the contents API. A local `git push` of an unsigned
  commit is refused (`ResourceComparison` error). Add maintainers' keys for signed direct commits.
- Public keys go into the Argo CD keyring. Addon `argo-cd`:
  `argo-cd.configs.gpg.keys: { B5690EEEBB952194: "<armored public key>" }` (`gpg --export --armor`).
- Off by default: the platform repo history and the hello-world CI bump (`git push` by github-actions) are not signed
  yet. Turn it on after switching those to API commits or signed commits.
- GnuPG verification covers Git sources only. Argo CD documents that Helm and OCI sources cannot be verified this way.

## Helm and OCI charts: not covered

- Argo CD 3.6 has no signature verification for Helm repositories or OCI artifacts (upstream issue
  [argoproj/argo-cd#22609](https://github.com/argoproj/argo-cd/issues/22609), open). Addons are wrapper charts:
  Argo CD renders them from this git repo, and their dependencies come from `helm dependency build` against the
  pinned versions in `Chart.yaml` and the committed `Chart.lock`.
- Upstream signing status of the charts used here, checked 2026-11-14 with `cosign verify`:
  - OpenChoreo (`cr.openchoreo.dev`, `ghcr.io/openchoreo`), Kyverno (`ghcr.io/kyverno/charts`): no signatures
    published;
  - cert-manager's OCI chart (`quay.io/jetstack/charts`): a key-based signature (cert-manager KMS key).
  So there is little to verify yet.
- Best available today:
  - Exact chart versions, reviewed through Renovate PRs, signed git commits (above), so Argo CD only renders reviewed
    chart pins.
  - Images, whatever chart deploys them into cell namespaces, are verified at admission.
  - When upstreams sign their charts: verify in CI before merge (`cosign verify oci://…:<version>` with the
    publisher's identity) in the Renovate PR workflow, and mirror verified charts into an internal OCI registry that
    Argo CD reads exclusively.
- Not covered: tampering between `helm dependency build` and render on the Argo CD repo server (it pulls chart
  tarballs over TLS but does not check signatures), and platform images in excluded namespaces. Those come from
  upstream charts and are pinned by version, not verified at admission.

## VERIFY

- GitHub web-flow key ID `B5690EEEBB952194` (rotated January 2024; `4AEE18F83AFDEB23` before).
- The registry host and project for workflow-plane images (`platformKey.prefixes`, build agent).
- Kyverno admission controller egress to `ghcr.io`, `rekor.sigstore.dev`, `tuf-repo-cdn.sigstore.dev` from data
  planes. Registry credentials for private images: `credentials.secrets` (Secrets in the kyverno namespace).
