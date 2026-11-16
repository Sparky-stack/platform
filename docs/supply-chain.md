# Supply chain

What is verified between a commit and a running pod, and what is not (yet). Promotion gates that use these checks:
[promotion.md](promotion.md).

| Stage | Control | State |
|---|---|---|
| Image build (GitHub) | koorikla/ci reusable workflow `container.yaml`: multi-arch build, Trivy scan, Sigstore keyless signature, SPDX SBOM, SLSA provenance, vuln attestation (cosign v3 bundles) | on (app repos) |
| Image build (in-cluster) | OpenChoreo workflow plane: cosign with the platform key (`cosign-platform`), Trivy vuln + SPDX SBOM attestations, no public tlog (docs/build-plane.md) | on (mgmt); admission trust per installation (below) |
| Admission, data planes | Kyverno `ImageValidatingPolicy` + `ValidatingPolicy` per environment | on: Audit dev/staging, Deny production |
| Git sources (Argo CD) | AppProject `sourceIntegrity` GnuPG policy | example, off (`sourceIntegrity.enabled`) |
| Helm / OCI charts (Argo CD) | not supported by Argo CD 3.6 | gap, see below |
| Promotion | reviewed PR + gate workflow + VAP (git-only writes) | on |

## Image signatures and attestations at admission

`addons/kyverno-policies/templates/image-verification.yaml` (Kyverno 1.20 CEL policy types only, no ClusterPolicy):

- **Scope**: pods (all container kinds; `pods/ephemeralcontainers`, so `kubectl debug` is checked too) and through
  Kyverno autogen their controllers, in OpenChoreo cell namespaces chosen by the label `openchoreo.dev/environment`.
  `imageVerification.environments` maps environment → `Audit` | `Deny`; `defaultAction` (default `Audit`) covers the
  cell namespaces of every environment not listed, so a new environment is reported, not unchecked. Platform
  namespaces are excluded twice: Kyverno's webhook namespaceSelector and `matchConditions` (`request.namespace`).
- **GitHub-built images** (`github.prefixes`, default `ghcr.io/koorikla/`):
  - issuer `https://token.actions.githubusercontent.com`;
  - subject = the reusable workflow at one commit: `github.workflow` + `@` + `github.workflowRef`
    (`https://github.com/koorikla/ci/.github/workflows/container.yaml@<40-hex SHA>`). Rendering fails for anything but
    a full commit SHA: a tag such as `v1` is mutable, so whoever can move it would decide what is trusted. App repos
    call koorikla/ci by the same SHA (`uses: koorikla/ci/.github/workflows/go.yaml@<sha> # v1`); the nested
    `container.yaml` call inherits that ref, so it is what the Fulcio certificate names. Renovate bumps
    `workflowRef` (custom manager in `renovate.json`, tag `v1` of koorikla/ci) and the app repos' `uses:` pins
    (github-actions digest pinning) to the same commit;
  - **moving the pin**: running production images were signed at the previous commit, so a bare bump of
    `workflowRef` would deny their next rollout. `github.transitionWorkflowRefs` keeps the previous commit trusted
    (every attestor lists one identity per commit) until each allowed repository's production image is rebuilt at the
    new one: (1) move `workflowRef`, put the old SHA into `transitionWorkflowRefs`; (2) bump the app repos and promote
    their rebuilt images; (3) empty `transitionWorkflowRefs`, which denies images signed at the old commit. Rendering
    and `hack/tests/test_kyverno_policies.sh` allow 40-hex SHAs only, no repeats, at most two commits in total
    ([#128](https://github.com/koorikla/platform/issues/128));
  - **plus** the certificate extensions `githubWorkflowRepository` (from `github.repositories`),
    `githubWorkflowRef` (from `github.refs`) and `githubWorkflowTrigger` (from `github.triggers`, default `push`).
    The subject alone would accept any repository on GitHub calling the public reusable workflow; the trigger pin
    keeps out `pull_request_target` / `workflow_run` runs, which carry the main ref but may build untrusted PR code.
    Kyverno matches extensions exactly, so every allowed (repository, ref, trigger) renders its own attestor, and the
    validation accepts any of them.
  - Required signed attestations from the same identity: `https://spdx.dev/Document/v2.3` (SBOM),
    `https://slsa.dev/provenance/v1` (provenance), `https://cosign.sigstore.dev/attestation/vuln/v1` (scan).
  - Transparency log: Rekor (`github.rekorURL`).
- **Workflow-plane images**: prefix `<registry.host>/<registry.appsProject>/` from installation.yaml (locally
  `harbor.openchoreo.localhost:9443/apps/`; host, port and project pinned), cosign public key
  (`platformKey.publicKey`, not a secret), no tlog by default. Keyless would need an OIDC issuer that Fulcio trusts
  ([#37](https://github.com/koorikla/platform/issues/37)). **Without a public key the registry is not a trusted source
  at all**: its images fail `openchoreo-trusted-registries-*` (denied in production, reported elsewhere) instead of
  skipping signature verification. A key without `registry.host` fails rendering. See "Wiring the key" below.
  `registry.type: external` installations push builds to `registry.external.repository`: trust it through
  `extraTrustedPrefixes` only together with a matching signature source.
- **Digest pinning**: `requireDigest.Deny: true`. Production rejects tag-only references, development and staging only
  report them. `mutateDigest` is off on purpose: OpenChoreo's agent re-applies the rendered Deployment, and a mutated
  digest would flap. See "Digest references" below for what app repos must do.
- **Trusted sources**: `openchoreo-trusted-registries-*` requires every container, init and ephemeral image to match a
  trusted prefix (the sources' prefixes plus `extraTrustedPrefixes`).
- **Failure policy**: production `Fail` (a Kyverno outage pauses production rollouts, never platform namespaces).
  Audit `Ignore`. Webhook timeout 20 s (registry + Rekor/TUF lookups).

Evidence (Kyverno CLI v1.20.0 against the real image
`ghcr.io/koorikla/hello-world:d04ca59@sha256:068979444334cb0dc031d9a286dcd7daed372572a5354135d19e8a471fcb2ec1`):
- `hack/tests/test_kyverno_policies.sh` with `KYVERNO_ONLINE=1`:
  - that image was built through `koorikla/ci@v1`, before the commit pin: it now fails in production ("expected SAN
    value …container.yaml@<sha>, got …container.yaml@refs/tags/v1") and is reported in staging. With the subject at
    `refs/tags/v1` its signature + SBOM + provenance + vuln attestations passed in production;
  - the tag-only reference fails in production.
  - an initContainer signed by a repository that is not allowed (`ghcr.io/koorikla/ci-toolbox`, signed by
    koorikla/ci's own pipeline) fails in production.
- Offline (every `task test`, kyverno CLI from `mise.toml`): unsigned / untrusted images in containers, initContainers
  and ephemeral containers are denied in production; the in-cluster registry without a platform key is denied in
  production (`registries` suite, `prod-platform-unsigned`); with a key only `<host>:<port>/<appsProject>/` is trusted
  (`platform-key` suite); an unlisted environment is audited (`defaultAction`).
- Negative checks during development:
  - a wrong `githubWorkflowRepository` or `githubWorkflowRef` is rejected ("expected GithubWorkflowRepository to be
    …");
  - an unknown predicate type is rejected and the error lists the types found.
- Kyverno 1.20 verifies the cosign v3 Sigstore bundle format.

Add an app repo: append its `owner/repo` to `imageVerification.github.repositories` in
`installations/<inst>/addons/kyverno-policies/values.yaml` (a tenant file alone does not trust its images).

### Wiring the key

The platform key is an installation value, not an ESO secret: `cosign.pub` of store key `cosign-platform` goes into
`installations/<inst>/addons/kyverno-policies/values.yaml` as `imageVerification.platformKey.publicKey` (print it with
`kubectl -n platform-secrets get secret cosign-platform -o jsonpath='{.data.cosign\.pub}' | base64 -d`). That suits
long-lived installations with a stable key (or, better, a KMS key). `installations/local` leaves it empty on purpose:
`task secrets` generates a fresh pair per mgmt cluster, so no committed key can match, and Harbor `apps/` images stay
untrusted on local workload clusters (Audit reports them, production denies them).

Why not ESO: the local seed path (`secrets.workloadSeed`) copies whole keys, so it would ship the encrypted private key
and its password to every workload cluster, and Kyverno 1.20 `ImageValidatingPolicy` takes a key inline (`data`), from
KMS or from a CEL `expression`, not from a Secret reference. Verification from a workload cluster also needs what
Kyverno does not have there yet: the registry host (coredns-local rewrites it on mgmt only), the mgmt-only Harbor CA,
and pull credentials for the private `apps` project. All of it: [#15](https://github.com/koorikla/platform/issues/15).

`platformKey.attestations` stays `[]`: the workflow plane's SBOM attestation is `cosign attest --type spdxjson`
(predicate `https://spdx.dev/Document`), not the `https://spdx.dev/Document/v2.3` that koorikla/ci's GitHub path emits.

### Digest references (live impact of `requireDigest`)

Production admits only `image@sha256:…` references. Every ComponentRelease carries the Workload's image as it was
when the release was cut, so a tag-only Workload makes the first production promotion fail at admission (the
RenderedRelease shows the Kyverno denial; nothing already running is touched). App repos must bump the Workload with
the digest reference:

- koorikla/ci already outputs it: `go.yaml` / `container.yaml` / `elixir.yaml` output `image_digest_ref`
  (`<image>:<tag>@sha256:<digest>`).
- hello-world's `bump` job still writes the tag-only `needs.go.outputs.image`; switching it to `image_digest_ref` is
  [#16](https://github.com/koorikla/platform/issues/16). Development and staging keep working meanwhile (Audit).

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
  ([#42](https://github.com/koorikla/platform/issues/42)).
- GnuPG verification covers Git sources only. Argo CD documents that Helm and OCI sources cannot be verified this way.

## Helm and OCI charts: not covered

- Argo CD 3.6 has no signature verification for Helm repositories or OCI artifacts (upstream issue
  [argoproj/argo-cd#22609](https://github.com/argoproj/argo-cd/issues/22609), open). Addons are wrapper charts:
  Argo CD renders them from this git repo, and their dependencies come from `helm dependency build` against the
  pinned versions in `Chart.yaml` and the committed `Chart.lock`.
- Upstream signing status of the charts used here (`cosign verify`):
  - OpenChoreo (`cr.openchoreo.dev`, `ghcr.io/openchoreo`), Kyverno (`ghcr.io/kyverno/charts`): no signatures
    published;
  - cert-manager's OCI chart (`quay.io/jetstack/charts`): a key-based signature (cert-manager KMS key).
  So there is little to verify yet.
- Best available today:
  - Exact chart versions, reviewed through Renovate PRs, signed git commits (above), so Argo CD only renders reviewed
    chart pins.
  - Images, whatever chart deploys them into cell namespaces, are verified at admission.
  - When upstreams sign their charts: verify them in the Renovate PR workflow and mirror them into an internal OCI
    registry ([#43](https://github.com/koorikla/platform/issues/43)).
- Not covered: tampering between `helm dependency build` and render on the Argo CD repo server (it pulls chart
  tarballs over TLS but does not check signatures), and platform images in excluded namespaces. Those come from
  upstream charts and are pinned by digest (`hack/tests/test_image_pins.sh`), not verified at admission.

Open checks: web-flow key ID ([#42](https://github.com/koorikla/platform/issues/42)), Kyverno egress and registry
credentials on data planes ([#44](https://github.com/koorikla/platform/issues/44)), the rendered workflow-plane image
host ([#40](https://github.com/koorikla/platform/issues/40)).
