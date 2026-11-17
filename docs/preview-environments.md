# PR preview environments

Every open pull request of an opted-in component gets its own OpenChoreo environment running the in-cluster build of
the PR head. The URL appears on the PR as commit status `openchoreo/preview`. Closing or merging the PR removes the
environment; a TTL (48h locally) removes forgotten ones. Issue: [#168](https://github.com/koorikla/platform/issues/168).

## How it works

```
PR opened/pushed ──> ApplicationSet previews-<project> (Argo CD, mgmt; pull request generator, GitHub App token)
                      └─> Application preview-<component>-pr-<n>  (AppProject previews, charts/preview)
                            ├─ Environment pr-<n>-<component>        on the preview data plane (dev1 locally)
                            ├─ ProjectReleaseBinding <project>-pr-<n>-<component>  -> cell namespace (labelled preview)
                            └─ ReleaseBinding <component>-pr-<n>     -> ComponentRelease <component>-pr-<n>-<sha12>
auto-build pass (every minute locally) ──> WorkflowRun <component>-pr<n>-<sha12>: build + scan + sign the PR head,
                                            push to Harbor, no GitOps commit
                                       ──> ComponentRelease <component>-pr-<n>-<sha12> = the Component's latest release
                                            with the PR image (owned by the Environment)
                                       ──> commit status openchoreo/preview: pending -> success + URL
PR closed/merged ──> Application deleted ──> Environment deleted ──> OpenChoreo finalizers delete bindings + namespace
```

- **Trigger**: the `pullRequest` generator of `charts/tenant/templates/previews.yaml`, one per app repo of the tenant
  file, polled every `previews.requeueAfterSeconds` (no inbound webhook locally; the ApplicationSet webhook for the
  cloud installations is a follow-up of #166). It authenticates with an installation token of the platform GitHub App
  limited to `pull_requests: read`, minted by ESO from store key `promotion-gate-github`
  (`addons/secret-stores/templates/preview-token.yaml`). No PAT.
- **Build**: the auto-build trigger of [build-plane.md](build-plane.md) ("Auto-build") handles PR heads too
  (`addons/openchoreo-platform/files/auto-build/auto_build.py`, class `Previews`): one WorkflowRun per PR head commit
  through the Component's own ClusterWorkflow, so the image is checked, scanned, signed with the platform key and pushed
  to Harbor exactly like a `main` build, but with `gitops.enabled: false` (nothing is committed to the app repo).
  Pull requests from forks are never built.
- **Release**: the pass cuts `ComponentRelease/<component>-pr-<n>-<sha12>` from the Component's latest release
  (`status.latestRelease`: the platform's ComponentType snapshot, traits, parameters) with the PR image and commit. A
  change to `deploy/openchoreo/` in the PR is therefore not part of the preview (only the code is). The pass then
  annotates the ReleaseBinding (`platform.koorikla.io/release`): OpenChoreo 1.3.3 does not requeue a binding whose
  release appears after it.
- **URL**: OpenChoreo's own external route of the environment, `http://pr-<n>-<component>-<org ns>.<gateway host>/<endpoint path>`
  (locally `http://pr-7-hello-world-default.dev1.apps.localhost:19080/hello-world-http`, reachable like the other
  environments, [demo.md](demo.md) "5. Deploy and promote"), read from the ReleaseBinding's `status.endpoints` and
  posted as the commit status target URL.

## Opting in

A component opts in from its own repository: the Component carries the annotation

```yaml
metadata:
  annotations:
    platform.koorikla.io/preview-environments: enabled
```

and its app repo is listed in the tenant file (`installations/<inst>/tenants/<project>.yaml`, as for every app). The
ApplicationSet selects on the annotation of the Component manifest at the top of the app path (git files generator),
and the auto-build pass checks it again before building PR code. Removing the annotation removes all previews of the
component. The installation switch is `installation.yaml` `previews`:

| Key | Local | Meaning |
|---|---|---|
| `enabled` | `true` | renders the ApplicationSets, the token, the Kyverno policies and the preview pass |
| `dataPlane` | `dev1` | ClusterDataPlane of the development tier every preview lands on |
| `ttl` | `48h` | lifetime from the Environment's creation (hours/minutes) |
| `maxPerTenant` | `2` | concurrent previews per tenant (RAM-bound locally) |
| `requeueAfterSeconds` | `120` | pull request poll |
| `expiredLabel` | `preview-expired` | PR label that ends a preview |

## Lifecycle and limits

- **PR closed or merged**: the generator drops the PR, the ApplicationSet deletes the Application, its resources
  finalizer deletes the Environment, and OpenChoreo's environment finalizer deletes the bindings and the cell namespace
  on the data plane (via its cluster agent). The ComponentRelease goes with the Environment (owner reference).
- **New push**: the Application's commit changes, the binding points at the new release, the pass builds the new head.
- **TTL**: Kyverno stamps `platform.koorikla.io/expires-at` (unix seconds, creation + `ttl`) on the Environment at
  creation (MutatingPolicy `platform-preview-expiry`). When it passes, the auto-build pass labels the PR
  `preview-expired`: the Application renders empty and Argo CD prunes the preview (the desired state itself says
  "gone", so neither self-heal nor a platform commit brings it back). Remove the label for a fresh 48h. Backstop:
  DeletingPolicy `platform-preview-ttl` deletes any preview Environment one hour past its stamp (or past creation +
  `ttl` without one), e.g. when GitHub was unreachable or an Application was orphaned.
- **Per-tenant cap**: ValidatingPolicy `platform-preview-cap` denies a tenant's preview Environment beyond
  `maxPerTenant`. The Application retries without a limit (every 5 minutes at most), so the next PR's preview starts
  when a slot frees up; the commit status shows the denial meanwhile.
- **Per-preview quota**: GeneratingPolicy `platform-preview-guardrails` puts a ResourceQuota and a LimitRange
  (`addons/kyverno-policies/values.yaml` `previewGuards`) into every preview cell namespace.

## Isolation and policy tier

- **Network**: the same GeneratingPolicy adds NetworkPolicy `platform-preview-isolation`: egress only inside the
  preview namespace, to platform namespaces (DNS, gateway) and outside the cluster, never to another OpenChoreo cell
  (staging, production, development or other previews). Ingress is OpenChoreo's per-component policy (same namespace
  and system components such as the gateway only), so no other cell reaches a preview either.
- **Admission tier**: preview environment names are not listed in `imageVerification.environments`, so the
  supply-chain gate applies `defaultAction` (Audit, the development tier; contract check 17 keeps them equal). Preview
  images are platform-signed anyway.
- **Never promotable**: preview environments are in no DeploymentPipeline and `isProduction: false`; the promotion gate
  only watches its source environments ([promotion.md](promotion.md)).
- **Who can create them**: only the ApplicationSet. AppProject `previews` admits Environment, ProjectReleaseBinding and
  ReleaseBinding in the org namespace, from the platform repo only; tenants' AppProjects cannot create Environments.

## GitHub App permissions

The platform App (`promotion-gate-github`, the promotion gate's) already has what previews need: Pull requests
read/write (generator, PR lookup, the expiry label) and Commit statuses read/write (the URL). Each consumer gets its own
installation token restricted to its share. GitHub Deployments are not used: they would need the extra permission
Deployments read/write on the App.

## Alignment with upstream OpenChoreo

OpenChoreo 1.3.3 has no ephemeral environments. The upstream proposal
([openchoreo/openchoreo discussion 4994](https://github.com/openchoreo/openchoreo/discussions/4994)) adds a thin root
resource that composes an Environment, a ProjectReleaseBinding and ReleaseBindings with a TTL. `charts/preview` renders
exactly those stock objects, so switching means replacing the chart with one instance of the upstream resource
(`projectRelease`/component selection, `ttl`) per PR; the build, URL, TTL label and Kyverno guardrails stay.

## Troubleshooting

```bash
kubectl --context k3d-platform-mgmt -n argocd get applicationset -l platform.koorikla.io/preview=true
kubectl --context k3d-platform-mgmt -n argocd get applications -l platform.koorikla.io/preview=true
kubectl --context k3d-platform-mgmt -n default get environments,releasebindings -l platform.koorikla.io/preview=true \
  -L platform.koorikla.io/expires-at
kubectl --context k3d-platform-mgmt -n default get workflowruns -l platform.koorikla.io/trigger=preview
kubectl --context k3d-platform-mgmt -n workflows-default get workflows -l workflows.argoproj.io/cron-workflow=auto-build-poll
```

- No Application for an open PR: the ApplicationSet's status (`ParametersGenerated`); is the annotation on the
  Component manifest on the app's revision, directly under the app path?
- Status `Waiting for environment`: the Application's sync message, usually the per-tenant cap.
- Status `Build ... failed`: the WorkflowRun in the console (Workflows), as for `main` builds.
