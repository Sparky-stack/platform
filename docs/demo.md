# Full platform demo

The scripted demo of the whole platform on the local stack (k3d mgmt + CAPD `dev1`, the lean profile of docs/dev-environment.md "Local profiles"): about 30 minutes, for
the team and for management. It follows the storyline of the tracking issue
[#98](https://github.com/koorikla/platform/issues/98). Every step lists what to show, the commands and URLs, the expected
output, talking points, and a fallback. A step whose feature is not on `main` yet is marked **pending #NN**.

## Before the demo

Run `task demo:check` 15 minutes before and again just before you start. It is read-only and prints one row per check:

```bash
task demo:check            # make demo-check; or: bash hack/demo-check.sh
```

```text
STEP CHECK                                          RESULT       DETAIL
---- ---------------------------------------------- ------------ ------
1    Argo CD apps Synced/Healthy                    PASS         51/51 Synced/Healthy
2    CAPI clusters Provisioned                      PASS         dev1 Provisioned/Available
...
5    hello-world 200 in production                  PENDING #54  404 http://production-default.dev1.apps.localhost:19080/hello-world-http/ (node 172.18.0.7)
...
24 PASS, 0 FAIL, 5 PENDING
```

| Result | Meaning | Before the demo |
|---|---|---|
| PASS | the step works on the live stack | show it live |
| FAIL | it should work and does not (exit code 1) | fix it, or use the step's fallback |
| PENDING #NN | the feature is not merged yet (issue NN) | tell the story with the fallback; do not improvise it live |

What it checks, per step: Argo CD apps, CAPI clusters, OpenChoreo data-plane agents, the cluster file rendered for the
other providers (offline `helm template`), the Backstage console, component types, the latest image's signature
(`cosign verify` with the identity pinned in `addons/kyverno-policies/values.yaml`), Kyverno policies Ready, a signed
image admitted and an unsigned one denied in the production cell namespace (`kubectl apply --dry-run=server`, nothing
is stored), in-cluster builds, hello-world HTTP 200 per environment through the CAPD node IP, promotion-gate
WorkflowRuns, metrics per cluster and per app in the observability plane, Falco on every cluster and the escalation
path, OpenBao-issued mesh certificates, ClusterSecretStores, the PostgreSQL claim API.

How it works and what it never does:
- Reads only: `kubectl get`, `kubectl get --raw` (Prometheus through the API server's service proxy), server-side
  dry-runs, curl GETs, `cosign verify`. Workload-cluster kubeconfigs come from `hack/kubeconfig.sh` into a temp dir that
  is removed on exit; no secret value is printed. Context `koorikla` is refused.
- Known-unmerged features: a failing check listed in `pending_issue()` of `hack/demo-check.sh` shows PENDING #NN instead
  of FAIL; delete the line when the issue closes. `DEMO_STRICT=1 task demo:check` shows them as FAIL.
- Variables: `KUBE_CTX`, `DEMO_NAMESPACE` (org namespace, `default`), `DEMO_COMPONENT` (`hello-world`),
  `DEMO_UNSIGNED_IMAGE`, `DEMO_HTTP_MODE=direct|docker` (default `docker` on macOS / Windows / WSL, where container IPs
  are not routable from the host: docs/dev-environment.md "Host differences (Docker Desktop and friends)").
- Tests: `hack/tests/test_demo_check.sh` (stubbed kubectl, curl, cosign, helm; part of `task test`).

Also prepare:
- Browser tabs: Argo CD (`task ui`, http://localhost:8081), the OpenChoreo console http://openchoreo.localhost:8080
  (user `admin@openchoreo.dev`, password: docs/forking.md "4. Boot"), Harbor https://harbor.openchoreo.localhost:9443, the
  promotion pull requests of koorikla/hello-world.
- Terminal with the workload cluster's kubeconfig: `task kubeconfig CLUSTER=dev1` (file `dev1.kubeconfig`, gitignored;
  in the multicluster profile also `CLUSTER=prod1`).
- Font size up, notifications off. Close the terminal that shows `task secrets` output.

## Timeline

| # | Step | Minutes | Status |
|---|---|---|---|
| 1 | Clean bootstrap | 3 | live |
| 2 | Add a cluster by adding a file | 4 | live; other providers render-only (EKS/GKE/AKS/Talos pending #87-#90) |
| 3 | Developer self-service | 3 | console live; scaffolder templates pending #59 |
| 4 | Build and supply chain | 5 | signature + live deny live; in-cluster build pending #17 |
| 5 | Deploy and promote | 5 | development/staging live; production pending #54 |
| 6 | Observe | 3 | logs/metrics/traces live; alert-rule trait pending #48 |
| 7 | Runtime security | 3 | live |
| 8 | Zero trust | 2 | live (OpenBao mesh CA on mgmt, istio-csr on dev1; #19); per-tenant stores pending #96 |
| 9 | App with a database | 2 | pending #91 |

## 1. Clean bootstrap

Show: one command builds the platform from zero; Argo CD converges mgmt and the fleet.

```bash
task up            # recorded beforehand: ~25 min; show the recording or the end of the log
task status        # CAPI clusters, Argo CD apps, ClusterDataPlanes
```

Expected: `task status` lists `dev1` `Provisioned`, every Application `Synced Healthy`, ClusterDataPlane `dev1` (hosting
development, staging and production, one namespace each). Argo CD UI: the `root` app fanning out to mgmt addons, the `fleet`
ApplicationSet and per-cluster addons.

Talking points:
- Push GitOps: Git is the source of truth; nobody runs `kubectl apply` for platform resources (AGENTS.md).
- Same toolchain on Linux, macOS, Windows (mise + Task); a fork runs from its own repo (`task set-repo`).
- Two clean runs from zero, no hand-fixes.

Fallback: do not run `task up` live (too long). Show `task status` and Argo CD on the running stack.

## 2. Add a cluster by adding a file

Show: a cluster is one YAML file. Open `installations/local/clusters/dev1.yaml` next to `prod1.yaml.disabled` (the
multicluster profile: renaming it to `prod1.yaml` and moving `production` to it creates prod1).

```bash
kubectl --context k3d-platform-mgmt get clusters -n fleet
kubectl --context k3d-platform-mgmt get clusterdataplanes
kubectl --context k3d-platform-mgmt get applications -n argocd | grep dev1
helm template cluster-prod-euc1 charts/cluster --namespace fleet \
  --values installations/aws-example/installation.yaml --values installations/aws-example/clusters/prod-euc1.yaml \
  | grep -E '^kind:|classRef' -A1 | head -20
```

Expected: `dev1` `Provisioned`, `AVAILABLE True`; its ClusterDataPlane exists (the check shows `1 agent connected`);
per-cluster addon apps (`cilium-dev1`, `falco-dev1`, ...); the AWS file renders a CAPI `Cluster`
with class `k3s-aws`.

Talking points:
- File -> `fleet` ApplicationSet -> CAPI Cluster -> Argo CD cluster secret -> addons by label -> OpenChoreo data plane
  (docs/providers.md "Adding a cluster").
- CNI is fixed at birth: `dev1` runs Cilium, `prod1` (multicluster profile) flannel; the label picks the addon set
  (docs/networking.md "CNI is fixed when the cluster is created").
- The same contract renders for AWS (CAPA) and Hetzner (CAPH) today; EKS, GKE, AKS and Talos/vSphere ClusterClasses are
  **pending #87, #88, #89, #90**.

Fallback: if a cluster is still provisioning, show the file, `kubectl get clusters -n fleet` and the rendered output.
Never create or delete a cluster live (a new CAPD cluster needs ~10 min and RAM the laptop may not have).

## 3. Developer self-service

Show: a developer creates a component in the console without touching Kubernetes.

- Console: http://openchoreo.localhost:8080 -> project `demo` -> component `hello-world`: Overview, Deploy tab
  (environments development / staging / production), Runtime Logs.
- Create: Create -> pick a component type (`service`, `web-application`, `worker`, `scheduled-task`).

```bash
kubectl --context k3d-platform-mgmt get clustercomponenttypes
kubectl --context k3d-platform-mgmt get components,releasebindings -n default
```

Expected: the four component types; component `hello-world` with release bindings for the three environments.

Talking points:
- Developers get golden paths (component types, traits) and a portal; the platform team owns the templates.
- The app repo contract is small: docs/openchoreo.md "App repo contract".

Fallback / pending: Backstage scaffolder templates that create a repo plus the OpenChoreo Component are **pending #59**.
Until then, show the existing `hello-world` component and its repo (koorikla/hello-world, `deploy/openchoreo/`).

## 4. Build and supply chain

Show: only signed images with SBOM, provenance and a vulnerability scan run in production; an unsigned one is denied
live.

```bash
IMAGE=$(kubectl --context k3d-platform-mgmt get workloads -n default hello-world-workload -o jsonpath='{.spec.container.image}')
cosign verify "$IMAGE" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity https://github.com/koorikla/ci/.github/workflows/container.yaml@<workflowRef> \
  --certificate-github-workflow-repository koorikla/hello-world \
  --certificate-github-workflow-ref refs/heads/main --certificate-github-workflow-trigger push >/dev/null
```

`<workflowRef>` is `imageVerification.github.workflowRef` in `addons/kyverno-policies/values.yaml`. Expected:
`The following checks were performed ...`, `The code-signing certificate was verified ...`.

The live deny, in the production cell namespace on `dev1` (production is where signatures are enforced; development
and staging, on the same cluster, only report: the policies select namespaces by their environment label):

```bash
NS=$(kubectl --kubeconfig dev1.kubeconfig get ns -l openchoreo.dev/environment=production,openchoreo.dev/managed-by=renderedrelease-controller -o name | head -1 | cut -d/ -f2)
kubectl --kubeconfig dev1.kubeconfig get imagevalidatingpolicies,validatingpolicies
kubectl --kubeconfig dev1.kubeconfig -n "$NS" run signed --image="$IMAGE" --dry-run=server
kubectl --kubeconfig dev1.kubeconfig -n "$NS" run unsigned \
  --image=ghcr.io/koorikla/hello-world@sha256:5760e176af0ec30cb8b06c80e99b3ab1746243c6c2d54997847ff850e8e38ad7 --dry-run=server
kubectl --kubeconfig dev1.kubeconfig -n "$NS" run untrusted --image=docker.io/library/busybox:1.37.0 --dry-run=server
```

Expected: policies `READY true`; `pod/signed created (server dry run)`; the unsigned digest is denied by
`openchoreo-verify-images-enforce` (`is not signed by gh-koorikla-hello-world-heads-main ... no signatures found`); the
docker.io image is denied by `openchoreo-trusted-registries-enforce` (`images must come from ghcr.io/koorikla/`).

Talking points:
- Keyless signing in CI (koorikla/ci): the certificate names the exact reusable workflow commit, repository, branch
  and trigger. A fork, a PR build or a manual run does not get in (docs/supply-chain.md).
- Kyverno checks signature + SBOM + SLSA provenance + vuln attestations and a digest reference at admission.
- The unsigned image above is a real digest in the same repository that CI never signed: anything pushed outside the
  pipeline looks like this.

Fallback / pending: the in-cluster build on the OpenChoreo workflow plane (Harbor, platform key) is **pending #17**
(and #15, #40). Show the GitHub Actions run of koorikla/hello-world and the attestations instead
(`cosign tree "$IMAGE"`). If the live deny returns a webhook timeout, Kyverno is still starting: show the `READY`
column and retry after a minute; `task demo:check` row "unsigned image denied" is the proof from the pre-flight.

## 5. Deploy and promote

Show: development -> staging -> production, with gates in front of production.

```bash
NODE_DEV=$(kubectl --context k3d-platform-mgmt get machines -n fleet -l cluster.x-k8s.io/cluster-name=dev1 -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
for env in development staging production; do
  curl -s --resolve "$env-default.dev1.apps.localhost:19080:$NODE_DEV" "http://$env-default.dev1.apps.localhost:19080/hello-world-http/"; echo
done
kubectl --context k3d-platform-mgmt get releasebindings,workflowruns -n default
```

On macOS / Windows run curl inside the CAPD network instead (docs/dev-environment.md "Host differences (Docker Desktop and friends)"). Expected: the
hello-world response from development and staging; WorkflowRuns `gate-hello-world-<id>` of ClusterWorkflow
`promotion-gate`; in Argo CD the AppProject `tenant-demo` sync window and the two apps `demo-hello-world` and
`demo-hello-world-production`.

Talking points:
- Promotion is a pull request; production bindings are reachable only through Git (ABAC + a ValidatingAdmissionPolicy
  deny everything else, docs/promotion.md "The gates").
- The automated gate checks pipeline order, readiness, a smoke test, the observer and the freeze window, then opens
  the production PR with a commit status; a human release manager merges it.

Fallback / pending: production serving hello-world needs a passing gate run that promotes a digest release:
**pending #54** (and the gate's GitHub App, #10). Show the gate WorkflowRun in the console (Workflows ->
promotion-gate), its PR if one exists, and the production ReleaseBinding condition (denied tag-only image) as proof
that production refuses what is not verified.

## 6. Observe

Show: logs, metrics and traces of hello-world in the console, collected from both workload clusters.

- Console -> `hello-world` -> Runtime Logs, Metrics, Traces (environment development).
- Raw proof (the pre-flight queries the same):

```bash
kubectl --context k3d-platform-mgmt get --raw \
  '/api/v1/namespaces/openchoreo-observability-plane/services/prometheus-operated:9090/proxy/api/v1/query?query=count%20by%20(k8s_cluster_name)(%7Bk8s_cluster_name!%3D%22%22%7D)'
```

Expected: series for `dev1` (and `prod1` in the multicluster profile); hello-world pods in the Metrics view.

Talking points:
- One observability plane on mgmt; data planes ship logs (Fluent Bit), metrics (Prometheus agent, remote write) and
  traces (OTel collector) with the cluster name (docs/observability.md "Signals").
- The same views back the RCA agent and MCP clients.

Fallback / pending: an alert rule as an OpenChoreo trait is **pending #48**. If the console views are empty, the
observer may still be indexing after a restart: show the Prometheus query above and the Runtime Logs of the last hour.

## 7. Runtime security

Show: Falco detects a shell in an app container; falcosidekick routes it, Talon labels the pod, Critical events
escalate to the falco-response workflow on mgmt.

```bash
POD=$(kubectl --kubeconfig dev1.kubeconfig get pods -A -l openchoreo.dev/component=hello-world -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}')
kubectl --kubeconfig dev1.kubeconfig exec -n "${POD%/*}" "${POD#*/}" -- sh -c 'id' || true
kubectl --kubeconfig dev1.kubeconfig logs -n falco ds/falco -c falco --since=2m | grep 'Platform shell'
kubectl --kubeconfig dev1.kubeconfig get pod -n "${POD%/*}" "${POD#*/}" --show-labels
kubectl --context k3d-platform-mgmt get sensors,workflows -n argo-events
```

Expected: a `Platform shell in app container` alert naming the pod; a `platform.koorikla.io/falco` label set on the
pod by Talon; Sensor `falco-escalation` deployed on mgmt. If the image has no
shell, the exec fails and Falco still reports the attempt (process spawn).

Talking points:
- Detection on every cluster (eBPF, no kernel module), response on the cluster (Talon), escalation to mgmt where the
  workflow enriches the event with project, component and environment (docs/observability.md "Falco response").
- Responses only ever touch app namespaces (`dp-*`), never platform workloads.

Every event carries `cluster:<name>` (falcosidekick custom field) and each cluster posts to its own escalation
endpoint with its own token, so one cluster cannot raise events in another's name.

Fallback: if no alert shows within a minute, show `task demo:check` rows of step 7 and the falco-response WorkflowTemplate.
Locally all clusters share one kernel (docs/observability.md "Falco"), so expect duplicate detections from other
clusters' Falcos.

## 8. Zero trust

Show: mTLS between workloads with certificates from OpenBao on mgmt (CA keys never leave mgmt), and secrets only
through External Secrets.

```bash
kubectl --kubeconfig dev1.kubeconfig get issuers,certificates -n istio-system
kubectl --kubeconfig dev1.kubeconfig get ns -L istio.io/dataplane-mode | grep dp-
kubectl --context k3d-platform-mgmt get clustersecretstores
kubectl --kubeconfig dev1.kubeconfig get clustersecretstores
```

Expected: Issuer `openbao-mesh` (Vault issuer) `READY True` and Certificate `istiod` `READY True` on each mesh member;
app namespaces in ambient mode; ClusterSecretStores `Ready True` on mgmt (`platform`, `mgmt-*`) and `default` on the
workload clusters.

Talking points:
- Istio ambient: ztunnel gives every app pod mTLS without sidecars; istio-csr on each member asks OpenBao on mgmt to
  sign, scoped to that cluster's PKI role with 10-minute tokens.
- No secret is in Git; ESO pulls from the platform store; per-tenant stores are next (#96).

Fallback: if `task demo:check` does not show "OpenBao-issued mesh certificates" as PASS (e.g. right after a restart
of OpenBao or istiod), show ambient enrollment, the ClusterSecretStores and the design in docs/architecture.md; do not
debug the CA live. Per-tenant SecretStores on OpenBao are **pending #96**.

## 9. App with a database

Show: a developer claims a PostgreSQL database; locally CloudNativePG runs it, on AWS the same claim becomes RDS.

Pending: PostgreSQL as a service (Crossplane v2 claim, CNPG live, RDS render-only) is **pending #91** (with #70 for
OpenChoreo resource types). Fallback: show docs/data-services.md "PostgreSQL (CloudNativePG)" and the opt-in label
in a cluster file; do not enable the addon live.

## Wrap-up (1 minute)

- One repo, one command, a file per cluster; every change through Git and Argo CD.
- Supply chain enforced at admission, promotion through reviewed PRs and automated gates, runtime detection and
  response, workload identity and secrets without long-lived credentials.
- What is next: the PENDING rows of `task demo:check` and the open items of [#98](https://github.com/koorikla/platform/issues/98).
