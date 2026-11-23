# Runbook: Harbor configuration (projects, proxy caches, robots)

## When to use

Use it to add or remove a proxy cache, a project or a robot account, to change a robot's permissions, to rotate a robot
or GHCR secret, or when a Harbor object does not converge. Harbor's configuration is a set of Crossplane managed
resources in ns `harbor` (provider `provider-upjet-harbor`, installed on mgmt by addon crossplane); background:
[build-plane.md](../build-plane.md#declarative-configuration).

## Symptoms

- `kubectl --context k3d-platform-mgmt -n harbor get managed` shows `SYNCED=False` or `READY=False` for an object.
- Node or build pulls through a proxy cache fail (`<host>/<project>/<repo>` 404 or 401 at Harbor) while upstream works.
- An in-cluster build fails to push to `apps` with `unauthorized` for `robot$builder`.
- Argo CD app `harbor-mgmt` is `OutOfSync` or its sync retries with `the server could not find the requested resource`
  (the provider CRDs are not there yet: check addon crossplane on mgmt).

## Steps

### 1. Read the state of every Harbor object

```bash
kubectl --context k3d-platform-mgmt -n harbor get managed
kubectl --context k3d-platform-mgmt -n harbor describe project.harbor.m.crossplane.io dockerhub   # conditions + events
kubectl --context k3d-platform-mgmt get providers.pkg.crossplane.io provider-upjet-harbor         # INSTALLED / HEALTHY
kubectl --context k3d-platform-mgmt -n crossplane-system logs -l pkg.crossplane.io/provider=provider-upjet-harbor --tail=50
```

### 2. Add a proxy cache

One entry in each of two places, in a PR:

1. `installations/<inst>/installation.yaml` `registry.proxyCache`: `{ upstream: <registry>, project: <harbor project> }`
   (nodes get the k3s mirror and rewrite from it, [build-plane.md](../build-plane.md#node-pulls-mirrors-with-fallback)).
2. `addons/harbor/values.yaml` `config.endpoints.<registry>`: `{ type: docker-registry, url: "https://<registry>" }`
   (`type` is the Harbor adapter, e.g. `docker-hub`, `github-ghcr`; the render fails without the endpoint).

After the merge the addon renders a `Registry` and a `Project` with `registryIdRef`; `robot$builder` and `robot$nodes`
get pull access to every proxy cache automatically (`pull: [proxyCache]`). Existing workload nodes pick up the new
mirror only when CAPI replaces their `Machine`s.

### 3. Add a robot account or change its permissions

1. Add a property `<name>-secret` (>= 8 characters with upper, lower and digit) to store key `harbor` (locally:
   `task secrets` seeds the known keys; add yours to `bootstrap/bootstrap.sh` too).
2. Add `config.robots[]`: `{ name, secretProperty: <name>-secret, description, push: [...], pull: [...] }` (`push`
   grants pull+push+tag create, `pull` read-only; `proxyCache` expands to every proxy-cache project).
3. Consumers read the secret from the store key `harbor` as user `robot$<name>`.

Removing a robot from `config.robots` deletes it from Harbor.

### 4. Rotate a robot or GHCR secret

Write the new value to the store, then let ESO and the provider pick it up at once:

```bash
kubectl --context k3d-platform-mgmt -n harbor annotate externalsecret harbor-platform force-sync="$(date +%s)" --overwrite
# The provider sets the robot secret from harbor-platform at its next reconcile; any annotation change triggers one now.
kubectl --context k3d-platform-mgmt -n harbor annotate account.robot.harbor.m.crossplane.io nodes rotated="$(date +%s)" --overwrite
kubectl --context k3d-platform-mgmt -n harbor annotate registry.harbor.m.crossplane.io ghcr.io rotated="$(date +%s)" --overwrite
```

Every consumer (node `registries.yaml`, build push secret, auto-build) reads the same store value: see
[certificates-and-secrets.md](certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

### 5. Remove a project or proxy cache

Removing the entry orphans the `Project` and `Registry` objects: they stay in Harbor with their images
(`managementPolicies` without `Delete`). If the data should go, delete the project in the Harbor UI (admin password:
store key `harbor` `admin-password`), then its registry endpoint.

## Verify

```bash
kubectl --context k3d-platform-mgmt -n harbor get managed                                    # all SYNCED=True READY=True
kubectl --context k3d-platform-mgmt -n harbor get project.harbor.m.crossplane.io -o custom-columns=NAME:.metadata.name,ID:.status.atProvider.projectId
```

Pull through the proxy cache from a workload node (`docker exec <dev1 node> crictl pull docker.io/library/busybox:1.37`)
and check the project's repository count in the Harbor UI.

## Rollback

Revert the PR. Projects and registries are never deleted by a revert (no `Delete` policy); robots and replication rules
return to their previous definition at the next sync. If the provider itself is broken, the Harbor objects keep their
last applied state: Harbor keeps serving pulls and pushes, only drift correction stops.

## Related links

- [build-plane.md](../build-plane.md#declarative-configuration): what each object configures
- [crossplane.md](../crossplane.md#crossplane-on-mgmt): Crossplane on mgmt
- [addons/harbor](../../addons/harbor/README.md), [addons/crossplane](../../addons/crossplane/README.md)
