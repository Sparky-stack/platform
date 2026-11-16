# Promotion gates: development → staging → production

How a release moves through the OpenChoreo `DeploymentPipeline default` (development → staging → production) and
which gates stop it. Everything on the path to production is declarative: a pull request into the app repo, synced by
Argo CD. Nothing runs `kubectl` against a cluster. App repo layout and the basic GitOps flow:
[openchoreo.md](openchoreo.md#app-repo-contract).

| Gate | Where | Native in OpenChoreo 1.3.3? | Implemented by |
|---|---|---|---|
| Promotion order | `DeploymentPipeline.spec.promotionPaths` | yes, but only `occ component deploy --to` and the console follow it ([#4884](https://github.com/openchoreo/openchoreo/issues/4884)) | the gate workflow checks the path |
| Manual approval | app repo PR (CODEOWNERS + branch protection) | no (`requiresApproval` was removed in 1.0) | pattern: GitHub review |
| Who may promote via console / API / MCP | OpenChoreo ABAC on `resource.environment` | yes (authz conditions) | `addons/openchoreo-platform/templates/promotion-authz.yaml` |
| Only git writes production bindings | Kubernetes admission | no | native `ValidatingAdmissionPolicy` (`promotion-git-only.yaml`) |
| Automated smoke + observability | ClusterWorkflow `promotion-gate` | generic Workflows + WorkflowRun are native. No hook on binding events | gate workflow + Argo Events trigger |
| Supply chain per environment | Kyverno on data planes | no | `addons/kyverno-policies/templates/image-verification.yaml` |
| Freeze window | Argo CD sync window + gate check | no | `charts/tenant` (AppProject `syncWindows`) + gate workflow |

## What OpenChoreo 1.3.3 offers

- **DeploymentPipeline** has only `promotionPaths[].sourceEnvironmentRef` / `targetEnvironmentRefs[]`. The approval
  fields (`requiresApproval`, `isManualApprovalRequired`) were removed in v1.0 (CHANGELOG). The ReleaseBinding webhook
  and controller never read the pipeline, so a direct write can skip an environment (upstream issue #4884).
- **ReleaseBinding** has `spec.releaseName`, `spec.state` (`Active` | `Undeploy`), per-environment overrides, and
  `status.delivery` (`rolloutId`, `startedAt`, `succeededAt`, `failedAt`). The delivery lifecycle Kubernetes Events
  (`DeploymentStarted/Succeeded/Failed/Recovered`) are written on the **data plane**, not on mgmt. So the trigger here
  watches the binding's `status.delivery` on mgmt.
- **Promotion UIs**: console "Promote" button, `occ component deploy <c> --to <env>`, openchoreo-api `PUT
  /api/v1/namespaces/{ns}/releasebindings/{name}`, MCP tools `create_release_binding` / `update_release_binding`.
  For a git-owned binding all of them are either denied (below) or reverted by Argo CD's self-heal.
- **Authorization conditions** (CEL over `resource.environment`, etc.) on `releasebinding:create|update|delete`,
  `projectreleasebinding:create|update|delete` and `resourcereleasebinding:create|update|delete`.
  An explicit `deny` binding wins over an `allow` for the same entitlement value.
- **Generic Workflows**: `ClusterWorkflow` + `WorkflowRun`, not tied to a component. They render into the workflow
  plane as Argo Workflows and appear in the console, `occ` and MCP like build runs.
- There are no gate or check hooks on bindings and no event-driven workflow triggers. The event-forwarder only sends
  change notifications to Backstage.

## The gates

### 1. Manual approval (pattern)

The app repo owns `deploy/openchoreo/release-bindings/<env>.yaml`. Promotion to production means a pull request that
sets `spec.releaseName` in `release-bindings/production.yaml`. The PR can be opened by the gate workflow or by a person.
In the app repo, configure:

- `CODEOWNERS`: `/deploy/openchoreo/release-bindings/production.yaml @koorikla/release-managers`
- Branch protection / ruleset on `main`:
  - require a PR, one approval from code owners, dismiss stale approvals;
  - required status check `openchoreo/promotion-gate`. Pin it to the gate's GitHub App (store key
    `promotion-gate-github`, [forking.md](forking.md#3-credentials) (c2); setup:
    [#10](https://github.com/koorikla/platform/issues/10)), so nobody else can set the status;
  - no bypass for admins, except a documented break-glass role.

Argo CD then syncs the merged binding: `charts/tenant` gives every gated environment its own Application
`<project>-<app>-production`. That Application includes only `release-bindings/production.yaml`, and the app's main
Application excludes that file.

### 2. Git is the only path to gated bindings (native)

- **OpenChoreo ABAC** (`promotion.restrictedGroups`, default `developers`): a `deny` ClusterAuthzRoleBinding with the
  condition `resource.environment in ["default/production"]` for `releasebinding:create|update|delete`,
  `projectreleasebinding:create|update|delete` and `resourcereleasebinding:create|update|delete` (deleting or editing
  the project's production `ProjectReleaseBinding` would deprovision or re-bind the project namespace on the production
  data plane).
  - Developers keep full control of development and staging through the console, `occ` and MCP.
  - Production is rejected with a clear authz error, also for AI agents using MCP.
  - `component:delete` is denied too, for every gated app's Component: `charts/tenant` renders an `AuthzRoleBinding`
    `<project>-promotion-deny-component-delete-<group>` (effect `deny`, scope project + component) on the
    `ClusterAuthzRole promotion-component-deleter` of addon openchoreo-platform. Apps with `promotionGates: false`
    keep it.
- **ValidatingAdmissionPolicy** `openchoreo-gated-bindings-from-git` (Kubernetes GA, no Kyverno needed on mgmt):
  - Only `system:serviceaccount:argocd:argocd-application-controller` may create, update or delete a production
    ReleaseBinding, **and only for the gated Application**: Argo CD writes for every Application with that one
    identity, so the binding's `argocd.argoproj.io/tracking-id` annotation (set by the controller on every apply,
    `<application>:<group>/<kind>:<namespace>/<name>`; a manifest cannot override it) must be exactly
    `<spec.owner.projectName>-<spec.owner.componentName>-<spec.environment>` (`oldObject` on DELETE): the gated
    Application of the app whose tenant-file name is the component (app name == Component name,
    [openchoreo.md](openchoreo.md#app-repo-contract)).
    - A production binding smuggled into any other file of the app repo (say `deploy/openchoreo/hotfix.yaml`) syncs
      through the main Application `<project>-<app>` and is denied, so the freeze window and the CODEOWNERS rule on
      `production.yaml` cannot be skipped.
    - Another app's gated Application cannot write this component's binding either. Developers control their
      Workload's `spec.source.repository`, so a gate run could open its PR in another repo, but merging there promotes
      nothing: only the repo the tenant file names for the app feeds `<project>-<component>-production`.
    - `charts/tenant` rejects app names that end in `-<gated environment>`, and a contract test rejects tenant
      projects named `<other project>-…` (their gated Applications would look like the other project's).
  - The OpenChoreo controller may change metadata only (`object.spec == oldObject.spec`, for finalizers).
  - The garbage collector may delete: deleting the Component cascades to its production binding. So the restricted
    groups may not delete gated Components either (next bullet); offboarding is removing the app from the tenant file
    (reviewed), and Argo CD deletes its objects.
  - Everyone else is denied: openchoreo-api acting for any user, kubectl, scripts.
  - Break glass: `promotion.gitOnly.breakGlassGroups` (empty by default).

### 3. Automated gate: ClusterWorkflow `promotion-gate`

`addons/openchoreo-platform/templates/promotion-gate.yaml` runs `files/promotion-gate/gate.py` (stdlib Python, image
pinned by digest, read-only root, non-root). It runs in the workflow plane, namespace `workflows-default`, as
ServiceAccount `workflow-sa`, on `ClusterWorkflowPlane default` (`promotionGate.workflowPlane`). Parameters
(`project`, `component`, environments, `release`) are DNS-1123 constrained; there is no repository parameter.

**Same run conventions as the builds** ([build-plane.md](build-plane.md#security-posture-of-build-pods)): the gate step gets no ServiceAccount token
(`automountServiceAccountToken: false`, only Argo's executor uses `workflow-sa`; the gate talks to the OpenChoreo API
with its Thunder token, never to the Kubernetes API). The run namespace is default-deny (NetworkPolicy
`build-runs-default-deny` of addon openchoreo-workflow-plane: DNS, API server for the executor, public 80/443, which
covers `api.github.com`). The gate pod carries `promotionGate.podLabels` (`platform.koorikla.io/egress: openchoreo`),
which opts it into NetworkPolicy `platform-workflows-openchoreo`: egress to the control-plane Gateway pods (port 8080:
`api.<host>`, `thunder.<host>`, rewritten there by coredns-local) and the observability Gateway pods
(`openchoreo.observability.httpPort`: `observer.<host>`). Build ClusterWorkflows never set the label and their
parameters cannot (`hack/tests/test_gitops_contracts.sh` check 10 keeps both addons' labels equal).

**Credentials.** A per-run ExternalSecret against `${workflowplane.secretStore}` (`ClusterSecretStore/workflows`,
scoped by `namespaceRegexes` to `workflows-*` and by `resourceNames` to `workflowStore.keys`; never the full
`platform` store) fetches, once (`refreshInterval: "0"`):
the Thunder client secret (`promotion-gate`) and the gate's own GitHub App (`promotion-gate-github`, never Argo CD's
read-only `platform-github`). The Secret is mounted read-only as files into the single gate pod (no env vars), the
pod is deleted when the step completes (`podGC: OnPodCompletion`), and the Secret goes with the WorkflowRun after
`promotionGate.ttlAfterCompletion` (1h; `deletionPolicy: Delete`). GitHub access per run:

- the repository is the component's Workload `spec.source.repository`, and its owner must be the installation's
  `installation.githubOrg`; anything else fails the gate;
- the gate signs an App JWT and mints an installation token restricted to exactly that repository and
  `contents`, `pull_requests`, `statuses` write (GitHub caps it at 1h), and revokes it when the PR step ends.

Residual: `workflows-*` can only sync `workflowStore.keys` from the secret backend (never `platform-github`,
`openchoreo`, `openbao-unseal` or cloud provider keys), but the workflow namespace is shared with tenant build runs
(OpenChoreo renders every run into `workflows-<org namespace>`), so for the run's lifetime the App key sits in a
Secret there; build run containers carry no ServiceAccount token, so tenant code would need a credential with Secret
read RBAC in that namespace to see it. The App's blast radius is the app repos it is installed on.
For one component and one edge (default staging → next environment) the gate checks, in order:

1. **pipeline**: the edge exists in the project's DeploymentPipeline (closes #4884 for the automated path).
2. **readiness**: the source binding runs the release being promoted and its **current spec** is rolled out: `Ready`
   for the generation the controller observed, and `Ready` turned true at or after `status.lastSpecUpdateTime` (a stale
   `Ready` of the previous release fails). openchoreo-api 1.3.3 does not return `status.delivery`; when the object has
   it, its rollout must have started after the last spec change and succeeded.
3. **smoke**: `GET` on every external endpoint of the source binding (`status.endpoints[].externalURLs`) answers
   2xx/3xx (5 tries with backoff).
4. **observability** (observer API, Thunder client credentials):
   - `POST /api/v1alpha1/alerts/query`: no alert fired for the component in the source environment during the last
     `observe.windowMinutes` (15).
   - `POST /api/v1/metrics/query` (`metric: http`): unsuccessful/total requests ≤ `observe.maxErrorRate` (5%).
     No traffic is reported, not failed.
5. **freeze**: no `promotion.freezeWindows` entry is active for the target environment (IANA time zones, DST-aware).
6. **promote**:
   - opens or updates the PR `promote(<component>): <release> to <env>` (branch `promote/<component>-<env>`) through
     the GitHub REST API, so GitHub signs the commit;
   - the PR body lists the evidence;
   - sets the commit status `openchoreo/promotion-gate` = success.

If any step fails, the WorkflowRun fails and no PR is opened. Its logs are in the console (Workflows), in `occ`, and
in the observer (`workflow` log scope).

**Triggers.**
- Automatic: addon `argo-events` watches ReleaseBindings in the org namespace. When `status.delivery.succeededAt` is
  set for a binding in `promotionGate.sourceEnvironments` (default `staging`) and that rollout started at or after the
  binding's `status.lastSpecUpdateTime` (right after a `releaseName` edit the binding still shows the previous
  release's finished rollout), Sensor `promotion-gate` creates `WorkflowRun gate-<component>-<sha256(rolloutId)[:10]>`. The name is deterministic, so one rollout gives exactly one
  run, and re-delivered events fail with AlreadyExists.
- Manual: create a WorkflowRun (below).

**Why a PR and not a direct binding update.** The gate only proves that the release is healthy. The approval stays
with people and git stays the record. Rollback is reverting the PR.

### 4. Policy gate per environment (Kyverno)

On every data plane `addons/kyverno-policies` renders, per action, an `ImageValidatingPolicy`
`openchoreo-verify-images-<audit|enforce>` (Sigstore signature + SBOM, SLSA provenance and vulnerability attestations;
digest required in production) and a `ValidatingPolicy` `openchoreo-trusted-registries-<audit|enforce>` (every image
from a trusted prefix). `Audit` applies to development and staging cell namespaces, `Deny` with `failurePolicy: Fail`
to production (namespace label `openchoreo.dev/environment`). A denied apply shows on the RenderedRelease. Identities,
scope and test evidence: [supply-chain.md](supply-chain.md#image-signatures-and-attestations-at-admission).

### 5. Freeze window (optional)

`promotion.freezeWindows` in `installation.yaml` (local: weekend, Fri 16:00 – Mon 08:00 Europe/Tallinn, production):

- `charts/tenant` turns each window into an Argo CD **deny sync window** on the gated Applications only
  (`schedule: "0 16 * * 5"`, `duration: 64h`, `timeZone`, `manualSync: false`). Development and staging keep syncing.
- The gate workflow refuses to open promotion PRs while a window is active.
- A PR merged during a freeze syncs when the window ends. Revert it if that is not wanted. Break glass: change the
  window in git.

## hello-world (tenant `demo`) walkthrough

The tenant file needs nothing extra. Gates are on by default (`promotionGates: false` per app opts out). What the
platform renders for it:
- Applications `demo-hello-world` (everything except `release-bindings/production.yaml`) and
  `demo-hello-world-production`;
- the AppProject `tenant-demo` sync window;
- the authz denies (production bindings, deleting `hello-world`) and the VAP.

App repo changes (koorikla/hello-world, outside this repo):

- `CODEOWNERS` + branch ruleset as in gate 1.
- CI: write the image **by digest** into `workload.yaml`. koorikla/ci outputs `image_digest_ref`; production denies
  tag-only references ([#16](https://github.com/koorikla/platform/issues/16)). Commit through the GitHub API (signed) rather than `git push` if `sourceIntegrity` is enabled
  ([supply-chain.md](supply-chain.md#git-commit-signatures)).
- Optional `/` health endpoint for the smoke test (`promotionGate.smoke.path`).

Flow:

```text
push main ─► CI (koorikla/ci: build, sign, SBOM, SLSA, vuln) ─► bump workload.yaml (digest)
  └► Argo CD syncs Workload ─► OpenChoreo cuts ComponentRelease hello-world-<hash> ─► binds development (autoDeploy)
developer: PR "staging: releaseName hello-world-<hash>" (review by the team) ─► merge ─► staging rollout
  └► rollout succeeded ─► Argo Events ─► WorkflowRun gate-hello-world-<id> (promotion-gate)
       pipeline ✓ readiness ✓ smoke ✓ observer ✓ freeze ✓ ─► PR "promote(hello-world): hello-world-<hash> to production"
                                                             + status openchoreo/promotion-gate=success
release manager (CODEOWNERS) approves ─► merge ─► Argo CD syncs demo-hello-world-production (not in a freeze)
  └► VAP: argocd-application-controller for Application demo-hello-world-production ✓ ─► OpenChoreo renders for production's cluster
       └► Kyverno there (dev1 locally, prod1 in the multicluster profile): signature + SBOM + SLSA + vuln + digest ✓ ─► pods run
```

### Driving it

| Action | CLI (`occ`) | API / MCP | Console (Backstage) |
|---|---|---|---|
| See what runs where | `occ releasebinding list --namespace default --project demo --component hello-world` | `GET /api/v1/namespaces/default/releasebindings?component=hello-world`, MCP `list_release_bindings` | Component → Deploy tab |
| Promote dev → staging | PR in the app repo (or `occ component deploy hello-world --to staging` for a non-gated, non-git environment) | MCP `update_release_binding` (staging only) | Promote button (staging only) |
| Run the gate by hand | `kubectl create -f` the manifest below (or the `occ` equivalent, [#54](https://github.com/koorikla/platform/issues/54)) | `POST /api/v1/namespaces/default/workflowruns`, MCP workflow tools | Workflows → promotion-gate → Run |
| Production | merge the gate's PR | denied (ABAC + VAP) | denied |
| Roll back production | revert the PR | – | – |

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: WorkflowRun
metadata:
  name: gate-hello-world-manual-1
  namespace: default
spec:
  workflow:
    kind: ClusterWorkflow
    name: promotion-gate
    parameters:
      project: demo
      component: hello-world
      sourceEnvironment: staging
      dryRun: true            # run every check, open no PR
```

## Configuration reference

| Key | Where | Default |
|---|---|---|
| `promotion.gatedEnvironments` | installation.yaml (charts/tenant, openchoreo-platform) | `[production]` |
| `promotion.restrictedGroups` | installation.yaml | `[developers]` |
| `promotion.freezeWindows` | installation.yaml | weekend, production |
| `promotion.bindingFile` | installation.yaml | `release-bindings/{environment}.yaml` |
| `promotion.gitOnly.*` | addon openchoreo-platform | Argo CD writes, controller metadata, no break glass |
| `promotionGate.*` (endpoints, smoke, observe, client, GitHub, status context) | addon openchoreo-platform | see values.yaml |
| `promotionGate.sourceEnvironments` | addon argo-events | `[staging]` |
| `imageVerification.*` | addon kyverno-policies | Audit dev/staging, Deny production |

Secrets (store `workflows` for the gate run, `platform` for addon thunder; seeded locally by `make secrets`):

| Key | Properties | Used by |
|---|---|---|
| `promotion-gate` | `client-secret` | gate workflow → Thunder client `openchoreo-promotion-gate` (client_credentials, created by addon thunder bootstrap script `70-openchoreo-promotion-gate-app.yaml`; also read by addon thunder) |
| `promotion-gate-github` | `githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey` | gate workflow: its own GitHub App; per-run token for the component's repo only (branch, PR, commit status). Seeded from `GITHUB_GATE_APP_*` (docs/forking.md) |

## Limits

- The gate fails closed until its GitHub App is seeded ([#10](https://github.com/koorikla/platform/issues/10)).
- Locally the workflow plane on mgmt cannot resolve `<env>-default.<cluster>.apps.localhost`, so the smoke probe is
  off in `installations/local/addons/openchoreo-platform/values.yaml`; other installations keep it on.
- Argo Events allows one source type per EventSource: the Falco webhook is EventSource `platform`, the
  ReleaseBinding watch is EventSource `releasebindings`.
- After a WorkflowRun's TTL (1 hour) any status update of an old staging rollout re-runs the gate. It is idempotent: a
  no-op when production already runs the release, otherwise it updates the same PR.
- Endpoints outside local: the gate posts the Thunder client secret to `TOKEN_URL` and calls `API_URL` / the observer
  over the control-plane Gateway; locally these are plain HTTP on the docker network. Every other installation must
  set `promotionGate.tokenURL` / `apiURL` / `observerURL` to `https://` endpoints (HTTPS listener on the Gateway).
- argo-events renders the promotion-gate Sensor only once the Argo Workflows CRDs exist (`workflowPlane: auto`,
  addon openchoreo-workflow-plane). The Argo Workflows controller watches all namespaces (`workflowNamespaces: []`);
  falco-response runs in `argo-events` with its own ServiceAccount, outside the build NetworkPolicy.
- Values not yet confirmed live (ABAC deny semantics, observer environment scope, Argo Events event shapes, first gate
  run): [#54](https://github.com/koorikla/platform/issues/54).
