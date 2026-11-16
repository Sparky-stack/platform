# Runbook: Break-glass

## When to use

Use this runbook **only** when normal GitOps delivery or an automated gate is deadlocked during an active incident or recovery procedure and no declarative fix can land in time. Every break-glass action leaves an explicit audit record and must be reconciled back to `main` before closing the incident.

## Symptoms

- Argo CD `selfHeal` reverts recovery edits while repairing PVCs or stateful pods (`thunder`, `openbao`).
- An urgent production rollback or hotfix is blocked by `promotion.freezeWindows` or an outage of `promotion-gate` / GitHub Actions.
- `Application/cluster-<name>` is stuck indefinitely in `OperationState: Running` (`retry.limit: -1`) because `ExternalSecret/<name>-registries` is `Ready=False` in sync wave `-1`.
- `ValidatingAdmissionPolicy/thunder-pvc-delete-protection` blocks intentional deletion of a protected PVC.
- A single-server `dev`/local k3s control plane (`controlPlane.replicas: 1`) lost `etcd` quorum during a `2 -> 1` rollout.
- Local `openbao-0` cannot unseal `data-openbao-0` because its static unseal key was lost or regenerated.

## Steps

### Who and what (authorization boundaries)

| Boundary | Default enforcement | Break-glass mechanism | Allowed scope |
|---|---|---|---|
| Management GitOps (`argocd`) | `automated.selfHeal: true` on `ApplicationSet`s | Scale both Argo CD controllers to `0` | Platform maintainers with `k3d-platform-mgmt` admin access |
| Production bindings (`ReleaseBinding`) | OpenChoreo ABAC + `ValidatingAdmissionPolicy/openchoreo-gated-bindings-from-git` + GitHub ruleset + `promotion.freezeWindows` | Emergency PR using GitHub ruleset bypass role + temporary `freezeWindows` edit in Git (`promotion.gitOnly.breakGlassGroups` stays `[]` by default) | Release managers / platform maintainers |
| Hook PVCs (`thunder`) | `ValidatingAdmissionPolicy/thunder-pvc-delete-protection` | Freeze Argo CD, back up PVs, drop annotation `platform.koorikla.io/delete-protection` | Platform maintainers |
| Cluster sync wave `-1` (`fleet`) | `ExternalSecret/<name>-registries` health check + `retry.limit: -1` | Fix secret + `force-sync`, terminate active op, or set `secrets.nodeRegistryAuth.enabled: false` in Git | Platform maintainers |
| Single-server k3s `etcd` | Embedded `etcd` quorum | `k3s server --cluster-reset` on the newest server | Local / non-HA `dev` clusters only (`production` cloud uses `>= 3` servers) |
| Production image admission (`kyverno`) | `openchoreo-verify-images-enforce` + `openchoreo-trusted-registries-enforce` (`failurePolicy: Fail`) | **None** (never weaken `production` to `Audit`; fix signing/allowlist or revert to the previous signed digest) | N/A |

### Freezing Argo CD self-heal

Pause **both** controllers on `k3d-platform-mgmt` whenever a recovery procedure mutates Argo-managed resources (`ApplicationSet` controller otherwise restores `Application` specs while `application-controller` reconciles workloads):

```bash
K="kubectl --context k3d-platform-mgmt"
$K -n argocd scale statefulset/argocd-application-controller --replicas=0
$K -n argocd scale deploy/argocd-applicationset-controller --replicas=0
$K -n argocd wait --for=delete pod \
  -l 'app.kubernetes.io/name in (argocd-application-controller,argocd-applicationset-controller)' --timeout=120s
```

Unfreeze as soon as the state matches Git:

```bash
$K -n argocd scale statefulset/argocd-application-controller deploy/argocd-applicationset-controller --replicas=1
```

### Emergency production promotion or freeze-window override

`ValidatingAdmissionPolicy/openchoreo-gated-bindings-from-git` rejects imperative `kubectl` and UI/API edits to `production` `ReleaseBinding`s unless they come from `system:serviceaccount:argocd:argocd-application-controller` tracking `<project>-<component>-production` ([promotion.md](../promotion.md#2-git-is-the-only-path-to-gated-bindings-native)). Keep Git in the loop even during emergencies `(not yet verified live)`:

1. **Active freeze window**: open and merge an emergency PR adjusting `promotion.freezeWindows` in `installations/<inst>/installation.yaml` ([promotion.md](../promotion.md#5-freeze-window-optional)). Argo CD updates the `AppProject` sync window and syncs the waiting `<project>-<component>-production` `Application`.
2. **`promotion-gate` or GitHub App outage**: merge a PR updating `deploy/openchoreo/release-bindings/production.yaml` to a signed `@sha256:...` `ComponentRelease` using the documented GitHub branch-ruleset break-glass role ([promotion.md](../promotion.md#1-manual-approval-pattern)). Because Argo CD applies the merged file through `<project>-<component>-production`, admission succeeds without opening `promotion.gitOnly.breakGlassGroups`.
3. **Control-plane API emergency (`breakGlassGroups`)**: only if Argo CD itself cannot reconcile and a `ReleaseBinding` must be edited directly, set `promotion.gitOnly.breakGlassGroups: ["<admin-group>"]` in `installations/<inst>/addons/openchoreo-platform/values.yaml` via PR, apply the fix, and revert `breakGlassGroups` to `[]` immediately.

### Blocked cluster sync on node registry secret

`ExternalSecret/<name>-registries` refreshes hourly in sync wave `-1`. When `Ready=False` (store outage, missing `platform-ghcr` or `harbor` key, or unissued `harbor-ca-bundle`), Argo CD blocks wave `0` (`Cluster/<name>`) and `fleet`'s `retry.limit: -1` keeps `OperationState: Running` active indefinitely ([providers.md](../providers.md#node-registry-config)):

```bash
K="kubectl --context k3d-platform-mgmt"
# 1. Diagnose which ClusterSecretStore (platform or mgmt-harbor) or key failed
$K -n fleet get externalsecret dev1-registries
$K -n fleet describe externalsecret dev1-registries

# 2. Preferred: restore the backing key (`task secrets` locally) and force ESO refresh; retry loop advances within 5m
$K -n fleet annotate externalsecret dev1-registries force-sync="$(date +%s)" --overwrite
```

- **Manual syncs while `retry.limit: -1` is active**: terminate the running retry operation first in the Argo CD UI (**Terminate** -> **Sync**) or via CLI (`argocd app terminate-op cluster-dev1`), and only sync `Cluster/dev1` selectively (`argocd app sync cluster-dev1 --resource cluster.x-k8s.io:Cluster:dev1`) if the existing `Secret/dev1-registries` is still valid `(not yet verified live)`.
- **Extended store outage bypass**: set `secrets.nodeRegistryAuth.enabled: false` (plus `registry.type: external` if Harbor's secret/CA is down) in `installations/<inst>/clusters/<name>.yaml` and merge. **Caveat:** changing `registryAuth` / `registryCA` updates `ClusterClass` variables and rolls every node in `<name>` without private registry auth or Harbor mirrors; use only when public pulls suffice.

### Intentional deletion of a delete-protected PVC

Hook PVCs (`thunder-database-pvc`, `thunder-certs-pvc`, `thunder-secrets-pvc`) carry `platform.koorikla.io/delete-protection: enabled`, enforced by `ValidatingAdmissionPolicy/thunder-pvc-delete-protection` for every identity including `cluster-admin` (`addons/thunder/templates/pvc-delete-protection.yaml`). To delete one intentionally:

```bash
K="kubectl --context k3d-platform-mgmt"
# 1. Freeze Argo CD (above) and back up the bound PV directory first (backup-restore.md)
# 2. Remove the delete-protection annotation, then delete the PVC
$K -n thunder annotate pvc thunder-database-pvc platform.koorikla.io/delete-protection-
$K -n thunder delete pvc thunder-database-pvc
```

### Single-server etcd quorum loss

For local or `dev` clusters with `controlPlane.replicas: 1` where the `2 -> 1` `etcd` member removal lost quorum ([#56](https://github.com/koorikla/platform/issues/56), `(not yet verified live)`; the new server already holds promoted voter data):

```bash
# 1. Identify the newest control-plane Machine (on CAPD, container name == Machine name) and save logs first
kubectl --context k3d-platform-mgmt -n fleet get machines \
  -l cluster.x-k8s.io/cluster-name=dev1,cluster.x-k8s.io/control-plane --sort-by=.metadata.creationTimestamp
SURVIVOR=<newest-machine-name>
docker exec "$SURVIVOR" journalctl -u k3s --no-pager > "${SURVIVOR}-k3s.log"

# 2. Reset etcd membership to the surviving node
docker exec "$SURVIVOR" sh -c 'systemctl stop k3s; k3s server --cluster-reset; systemctl start k3s'
```

### OpenBao local re-initialization

On a local installation (`seal "static"`), if `openbao-unseal` was lost and `data-openbao-0` can no longer be decrypted, re-initialize OpenBao from scratch (`(not yet verified live)`; invalidates the previous mesh root CA so workload pods roll onto the new root):

```bash
K="kubectl --context k3d-platform-mgmt"
# 1. Ensure a valid static unseal key exists in platform-secrets and syncs to openbao
task secrets
$K -n openbao annotate externalsecret openbao-unseal force-sync="$(date +%s)" --overwrite

# 2. Stop openbao-0, wipe its PVC so self-initialization runs again, and start openbao-0
$K -n openbao scale statefulset/openbao --replicas=0
$K -n openbao wait --for=delete pod/openbao-0 --timeout=120s
$K -n openbao delete pvc data-openbao-0
$K -n openbao scale statefulset/openbao --replicas=1
$K -n openbao rollout status statefulset/openbao --timeout=180s

# 3. Re-run mesh-reconcile, refresh mesh CA bundles, and roll istiod + ztunnel on each mesh member
$K -n openbao create job --from=cronjob/mesh-reconcile mesh-reconcile-reset
$K -n openbao wait --for=condition=complete job/mesh-reconcile-reset --timeout=120s
$K -n openbao annotate externalsecret openbao-ca-bundle force-sync="$(date +%s)" --overwrite
for c in dev1 prod1; do
  $K -n fleet annotate externalsecret "${c}-mesh-ca" force-sync="$(date +%s)" --overwrite
  task kubeconfig CLUSTER="$c"
  kubectl --kubeconfig "${c}.kubeconfig" -n istio-system delete secret istiod-tls --ignore-not-found
  kubectl --kubeconfig "${c}.kubeconfig" -n istio-system rollout restart deploy/istiod ds/ztunnel
done
```

### Audit trail and post-incident reconciliation

Every break-glass action is recorded across four durable trails:

1. **Git history and PR reviews**: emergency `freezeWindows`, `nodeRegistryAuth`, `breakGlassGroups`, and `production.yaml` PRs record author, reviewer, timestamp, and reason on `main`.
2. **Kubernetes Events (`OpenSearch` `k8s-events-*`)**: admission denials, `scale` changes, `Job` creations, and `FalcoCritical` escalations are shipped by `events-collector` and retained in OpenSearch (`7d` locally).
3. **Argo CD operation history**: `Application.status.history` and `argocd-server` / `argocd-application-controller` logs (`container-logs-*`) capture manual syncs and terminated operations.
4. **Host / node evidence**: capture container or systemd logs (`journalctl -u k3s`, PV backups) before destructive resets, and attach the command transcript (without secret values) to the incident issue or post-mortem PR.

Before closing a break-glass session:

- Revert any temporary Git overrides (`freezeWindows`, `secrets.nodeRegistryAuth.enabled: false`, `promotion.gitOnly.breakGlassGroups`).
- Re-add `platform.koorikla.io/delete-protection: enabled` on recreated hook PVCs.
- Unfreeze both Argo CD controllers and delete local PV backup directories once healthy.

## Verify

```bash
K="kubectl --context k3d-platform-mgmt"

# 1. Both Argo CD controllers are running at 1/1 Ready
$K -n argocd get statefulset/argocd-application-controller deploy/argocd-applicationset-controller

# 2. All Applications are Synced and Healthy (zero drift from main)
$K -n argocd get applications | grep -v 'Synced.*Healthy' || true

# 3. Admission guardrails remain active
$K get validatingadmissionpolicy
```

## Rollback

- **Unfreeze Argo CD and reconcile to `main`**: scale `argocd-application-controller` and `argocd-applicationset-controller` back to `1` (or run `task argocd` if `argocd` itself was broken) and let `selfHeal` restore Git state.
- **Revert temporary Git bypasses**: `git revert <break-glass-commit>` in a PR to `main` so `freezeWindows`, `nodeRegistryAuth`, and `breakGlassGroups` return to normal enforcement.

## Related links

- [Operations handbook](../operations.md)
- [Promotion gates and admission policy](../promotion.md#2-git-is-the-only-path-to-gated-bindings-native)
- [Control-plane rollouts and node registry config](../providers.md#control-plane-size-and-rollouts)
- [Thunder PVC hook protection](../openchoreo.md#argo-cd-requirements)
- [OpenBao mesh CA](../multicluster.md#mesh-ca-openbao)
- [Backup and restore](backup-restore.md)
- [Incidents](incidents.md)
