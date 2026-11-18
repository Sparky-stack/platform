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
    until each allowed repository's production image is rebuilt at the new one. Kyverno 1.20 verifies one identity
    per attestor ("multiple identities are not supported"), so each trusted commit renders its own attestors (suffix
    `-<sha7>` for the transition commit) and the validations accept any of them, current-pin attestors first: images
    already rebuilt cost nothing extra, images still at the old commit pay one failed verification per check on every
    admission (failures are not cached, see "Admission latency"). Keep the window short.
    Steps: (1) move `workflowRef`, put the old SHA into `transitionWorkflowRefs`; (2) bump the app repos and promote
    their rebuilt images; (3) empty `transitionWorkflowRefs`, which denies images signed at the old commit. Rendering and
    `hack/tests/test_kyverno_policies.sh` allow 40-hex SHAs only, no repeats, at most two commits in total
    ([#128](https://github.com/koorikla/platform/issues/128));
  - **plus** the certificate extensions `githubWorkflowRepository` (from `github.repositories`),
    `githubWorkflowRef` (from `github.refs`) and `githubWorkflowTrigger` (from `github.triggers`, default `push`).
    The subject alone would accept any repository on GitHub calling the public reusable workflow; the trigger pin
    keeps out `pull_request_target` / `workflow_run` runs, which carry the main ref but may build untrusted PR code.
    Kyverno matches extensions exactly, so every allowed (repository, ref, trigger) renders its own attestor, and the
    validation accepts any of them (tried in order, so an image of the n-th repository pays n-1 failed verifications
    per check and admission: keep the list short).
  - Required signed attestations from the same identity: `https://spdx.dev/Document/v2.3` (SBOM),
    `https://slsa.dev/provenance/v1` (provenance), `https://cosign.sigstore.dev/attestation/vuln/v1` (scan).
  - Transparency log: Rekor (`github.rekorURL`).
- **Workflow-plane images**: prefix `<registry.host>/<registry.appsProject>/` from installation.yaml (locally
  `harbor.openchoreo.localhost:9443/apps/`; host, port and project pinned), cosign public key
  (`platformKey.publicKey`, not a secret), no tlog by default. Keyless would need an OIDC issuer that Fulcio trusts
  ([#37](https://github.com/koorikla/platform/issues/37)). The key is inline (`platformKey.publicKey`) or, with
  `registry.type: harbor`, delivered from mgmt to each workload cluster and read at admission; required signed
  attestations: SBOM (`https://spdx.dev/Document/v2.3`) and vuln. **Without a key source the registry is not a trusted
  source at all**: its images fail `openchoreo-trusted-registries-*` (denied in production, reported elsewhere) instead
  of skipping signature verification. A key without `registry.host` fails rendering. See "Wiring the key" below.
  `registry.type: external` installations push builds to `registry.external.repository`: trust it through
  `extraTrustedPrefixes` only together with a matching signature source.
- **Digest pinning**: `requireDigest.Deny: true`. Production rejects tag-only references, development and staging only
  report them. `mutateDigest` is off on purpose: OpenChoreo's agent re-applies the rendered Deployment, and a mutated
  digest would flap. See "Digest references" below for what app repos must do.
- **Trusted sources**: `openchoreo-trusted-registries-*` requires every container, init and ephemeral image to match a
  trusted prefix (the sources' prefixes plus `extraTrustedPrefixes`).
- **One policy per check**: `openchoreo-verify-images-<audit|enforce>` verifies the signature and
  `openchoreo-attest-<sbom|provenance|vuln>-<audit|enforce>` one required attestation each, so the checks run in
  parallel ("Admission latency" below). An image is admitted only if every one of them passes.
- **Failure policy**: production `Fail` (a Kyverno outage pauses production rollouts, never platform namespaces).
  Audit `Ignore`. Webhook timeout 30 s, the maximum (a cold check takes ~5-10 s, below).

Evidence (Kyverno CLI v1.20.0 against the real image
`ghcr.io/koorikla/hello-world:d04ca59@sha256:068979444334cb0dc031d9a286dcd7daed372572a5354135d19e8a471fcb2ec1`):
- `hack/tests/test_kyverno_policies.sh` with `KYVERNO_ONLINE=1`:
  - that image was built through `koorikla/ci@v1`, before the commit pin: it now fails in production ("expected SAN
    value …container.yaml@<sha>, got …container.yaml@refs/tags/v1") and is reported in staging. With the subject at
    `refs/tags/v1` its signature + SBOM + provenance + vuln attestations passed in production;
  - the tag-only reference fails in production.
  - `ghcr.io/koorikla/hello-world:5129f77@sha256:79cf2ede…`, built through `go.yaml@a31c234` (= `workflowRef`), passes
    in production; `df72ab8@sha256:889643d3…`, built through `go.yaml@de39b1d` (the previous pin), fails since
    `transitionWorkflowRefs` is empty again.
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

### Admission latency

Production admission must finish within the webhook timeout (30 s max, `failurePolicy: Fail`), for every rollout
([#136](https://github.com/koorikla/platform/issues/136)). Where the time goes, per keyless verification on Kyverno 1.20
(measured from the local host against the real image; the admission controller logs show the same ~5-6 s per call):

- **Sigstore TUF, ~1-1.5 s**: Kyverno refreshes the TUF metadata on every call, twice (sigstore `tuf.Initialize` with a
  forced update, then a fresh sigstore-go client without cache validity): `<n+1>.root.json` (404), `timestamp.json`,
  roots and snapshot, ~150-500 ms per request to `tuf-repo-cdn.sigstore.dev`, under a process-wide lock. No flag turns
  it off: the attestor's `tuf` field only changes mirror and root, and the trusted root (`trustedRoot`) does not skip
  the refresh for keyless attestors.
- **Registry, ~3-4 s**: ghcr.io has no OCI referrers API (404), so cosign reads the `sha256-<digest>` referrers index
  and fetches every bundle in it (signature + 3 attestations: manifest, 307 redirect, blob each), for every check.
- No Rekor request in the trace: the cosign v3 bundle carries the inclusion proof.

What the platform does about it:

- **Verification cache** (`addons/kyverno` values, `imageVerifyCache*` flags of the admission controller): a
  successful verification is cached per image reference **with digest** (`repo:tag@sha256:…`), attestor definition
  and attestation type, so the next admission of the same reference (the Deployment's ReplicaSet pods, a scale-up, a
  restart, the same image in production after staging - same attestors, same entries) skips it. Not weakened by the
  cache: tag-only references are never cached
  (production requires digests anyway), failed verifications are never cached (a denied image is verified again every
  time), any change of the policy identity, extensions or Rekor URL changes the key. TTL 24 h bounds how long a
  Sigstore trust-root change takes to reach digests verified before it; deleting the admission controller pod flushes
  the cache (in-memory, per replica). 32 MiB per replica, ~1 MiB per image (the SPDX SBOM payload).
- **One policy per check**: one `ImageValidatingPolicy` evaluates its validations one after the other; signature + 3
  attestations in one policy took ~20 s cold. Each policy gets its own (fine-grained) webhook, the API server calls
  them in parallel and Kyverno evaluates them concurrently; only the TUF refreshes stay serialized.
- **One attestor per call**: `verifyImageSignatures(image, [a]) > 0 || verifyImageSignatures(image, [b]) > 0`, not
  `verifyImageSignatures(image, [a, b]) > 0`. Kyverno caches a call only when every attestor in it verified and runs
  every attestor of a list, so a list (pin move, several repositories) was never cached and cost n verifications per
  check on every admission.

Measured on dev1 with a server dry-run in production (`kubectl -n <production cell namespace> run probe
--image=<ref> --dry-run=server`, timed; `<ref>` = `ghcr.io/koorikla/hello-world:5129f77@sha256:79cf2ede…`). "New
digest" uses a reference Kyverno has not seen yet (same digest, another tag: the cache key is the full reference):

| | before (#135: one policy, 4 checks) | after (#142) |
|---|---|---|
| signed image, new digest | ~20 s | 8.3-8.5 s |
| signed image, first admission after an admission controller restart | 20.6 s | 12.1-15.9 s (*) |
| signed image, cached | 0.07 s | 0.06-0.08 s |
| production after the same reference was admitted in staging | cold unless within 60 min | 0.08 s |
| image signed at the previous pin (denied, never cached) | 5.7-7.0 s | 8.3 s |
| unsigned digest (denied) | | 6.0 s |
| tag-only reference (denied) | 0.06 s | 0.09 s |
| unsigned docker.io image (denied, trusted registries) | 0.09 s | 0.06 s |

(*) includes the first TUF initialization of the new pod, and another admission of the same image (OpenChoreo
re-applying the production Deployment) arrived within 2 s: Kyverno does not coalesce identical in-flight
verifications, so both ran their 4 checks and the 8 TUF refreshes queued on the lock.

Further cut, not done: an in-cluster caching TUF mirror (attestor `tuf.mirror`; TUF metadata is signed, so a mirror
needs no trust) would remove most of the per-call TUF time.

### Wiring the key

Two key sources for the workflow-plane prefix (addon kyverno-policies `imageVerification.platformKey`):

- **Inline** (`publicKey`): `cosign.pub` of store key `cosign-platform` in
  `installations/<inst>/addons/kyverno-policies/values.yaml` (print it with
  `kubectl -n platform-secrets get secret cosign-platform -o jsonpath='{.data.cosign\.pub}' | base64 -d`). For
  long-lived installations with a stable key (or, better, a KMS key, [#37](https://github.com/koorikla/platform/issues/37)).
- **From mgmt, per workload cluster** (default with `registry.type: harbor` and no `publicKey`; `installations/local`):
  `task secrets` generates a fresh pair per mgmt cluster, so no committed key could match. `charts/cluster`
  (`templates/image-verification-crs.yaml`) builds an ESO-templated ClusterResourceSet payload on mgmt and CAPI applies
  it to exactly that cluster (strategy Reconcile), into Kyverno's namespace:

  | Object | Content | Source on mgmt | Used by |
  |---|---|---|---|
  | ConfigMap `platform-image-verification` | `cosign.pub`, `ca.crt` (both public) | store `platform` key `cosign-platform` property `cosign.pub` only; store `mgmt-harbor` `harbor-ca-bundle` | the policies: attestor key `expression` from `resource.Get(...)`, read per admission; addon kyverno `values/role-workload.yaml`: `ca.crt` under `SSL_CERT_DIR` of the admission and reports controllers |
  | Secret `platform-registry` (`kubernetes.io/dockerconfigjson`) | Harbor robot `robot$nodes` (pull only, the nodes' robot) | store `platform` key `harbor` property `nodes-secret` | the policies: `credentials.secrets` |

  The ExternalSecret selects single properties, so the encrypted private key and its password are never read on the
  way (the local seed path `secrets.workloadSeed` copies whole keys, which is why it is not used). Kyverno 1.20 takes a
  key inline, from KMS or from a CEL expression, not from a Secret reference. The registry name resolves through
  coredns-local's generic rule (k3d load balancer, port 9443). `SSL_CERT_DIR` adds the Harbor CA to Go's system bundle
  instead of replacing it (the chart's `caCertificates` would), so public registries and Sigstore keep working. A
  missing ConfigMap fails the policy's checks (denied in production), it never skips them. A re-bootstrapped mgmt key
  is picked up without a policy change (verified results stay cached up to 24 h, addon kyverno); a re-issued Harbor CA
  needs a Kyverno controller restart (Go reads the roots once; the CA lives 10 years).

Required platform-key attestations (`platformKey.attestations`): `sbom` and `vuln`. The workflow plane attests its SBOM
with predicate `https://spdx.dev/Document/v2.3`, the type koorikla/ci's GitHub path emits (`attestationTypes.sbom`), and
the Trivy scan as `https://cosign.sigstore.dev/attestation/vuln/v1`. Provenance is BuildKit's unsigned SLSA attestation
manifest, so it is not required for this source.

### Digest references (live impact of `requireDigest`)

Production admits only `image@sha256:…` references. Every ComponentRelease carries the Workload's image as it was
when the release was cut, so a tag-only Workload makes the first production promotion fail at admission (the
RenderedRelease shows the Kyverno denial; nothing already running is touched). App repos must bump the Workload with
the digest reference:

- koorikla/ci already outputs it: `go.yaml` / `container.yaml` / `elixir.yaml` output `image_digest_ref`
  (`<image>:<tag>@sha256:<digest>`).
- hello-world's `bump` job still writes the tag-only `needs.go.outputs.image`; switching it to `image_digest_ref` is
  [#16](https://github.com/koorikla/platform/issues/16). Development and staging keep working meanwhile (Audit).

Builds themselves follow the same rule on mgmt: pods in the workflow run namespaces `workflows-*` admit only digest
references (Kyverno `platform-workflow-image-digests`, Deny; [build plane](build-plane.md#security-posture-of-build-pods)).

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
  - Istio's charts (`addons/istio-ambient`) are also pinned by tarball sha256 (`Chart.yaml` annotation
    `platform.koorikla.io/dependency-digests`, checked by `hack/deps.sh` locally and in CI, not by the Argo CD repo
    server).
  - Images, whatever chart deploys them into cell namespaces, are verified at admission.
  - When upstreams sign their charts: verify them in the Renovate PR workflow and mirror them into an internal OCI
    registry ([#43](https://github.com/koorikla/platform/issues/43)).
- Not covered: tampering between `helm dependency build` and render on the Argo CD repo server (it pulls chart
  tarballs over TLS but does not check signatures), and platform images in excluded namespaces. Those come from
  upstream charts and are pinned by digest (`hack/tests/test_image_pins.sh`), not verified at admission.

Open checks: web-flow key ID ([#42](https://github.com/koorikla/platform/issues/42)), Kyverno egress and registry
credentials on data planes ([#44](https://github.com/koorikla/platform/issues/44)).
