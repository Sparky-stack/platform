# valkey: Crossplane Configuration package

**Status: layout** (#241) - not installed on any cluster, not live-tested. The `valkey-operator` backend renders
offline in CI; the cloud backends are skeletons that render but were never applied. Enable + live proof: follow-up issue.

The platform's Valkey API (`platform.koorikla.io/v1alpha1 Valkey`, namespaced XR): a Redis-protocol cache / key-value
store. Valkey is the Linux Foundation fork of Redis (BSD-3), current practice over Redis. Same layout as
[`packages/postgresql`](../postgresql/README.md) and [docs/crossplane.md](../../docs/crossplane.md): XRD + one
Composition `valkey` dispatching on `$facts.backend` from the EnvironmentConfig `platform-valkey`.

## Developer contract

| Field | Default | Meaning |
|---|---|---|
| `size` | `S` | memory per node, about 512Mi / 2Gi / 8Gi (cloud: nearest tier) |
| `highAvailability` | `false` | a replica in another zone with automatic failover |
| `maxmemoryPolicy` | `noeviction` | `allkeys-lru` / `allkeys-lfu` for caches |
| `deletionPolicy` | `Retain` | cloud: keep the cache when the XR goes |

Plain values in the XR status: `endpoint`, `port`, `tls` (true = `rediss://`). Credentials Secret `<name>-valkey`
(`status.secretName`), same keys on every backend: `username`, `password`. The host is not in the Secret because in
cloud the password must exist before the endpoint is known; OpenChoreo binds both. On `gcp-memorystore` and
`azure-cache` the password is empty: clients authenticate with their workload identity (IAM / Entra ID) - VERIFY.

## Backends

| `backend` | Composes | Facts |
|---|---|---|
| `valkey-operator` | `valkey.io/v1alpha1 ValkeyCluster` (1 shard, +1 replica for HA, ACL user `app`), ESO `Password` + `ExternalSecret` | - |
| `aws-elasticache` | `elasticache.aws.m.upbound.io ReplicationGroup` (engine valkey, TLS, AUTH token from the Secret) | `region`, `subnetGroupName`, `securityGroupIds` |
| `gcp-memorystore` | `memorystore.gcp.m.upbound.io Instance` (VALKEY_8_0, PSC, IAM_AUTH) | `project`, `region`, `network` |
| `azure-cache` | `cache.azure.m.upbound.io RedisCache` (no managed Valkey on Azure; Entra auth, private) | `resourceGroupName`, `location` |

## Local operator choice: valkey-io/valkey-operator

- No CNCF Valkey/Redis operator exists. The Valkey project's own operator
  ([valkey-io/valkey-operator](https://github.com/valkey-io/valkey-operator), Apache-2.0, Linux Foundation) is chosen:
  declarative ACL users from Secrets, live config, status conditions. It is v1alpha1 and documented as not
  production-ready yet, cluster mode only (clients must be cluster-aware), no backup/restore - acceptable for local
  data planes; production clusters use the cloud backends.
- Considered: OT-Container-Kit redis-operator and SAP valkey-operator (both maintained, not the upstream project),
  Bitnami charts (no operator, image licensing changes). Revisit when valkey-operator reaches v1beta1.

## VERIFY (before enabling)

- valkey-operator: `shards: 1` accepted, field names `acl.users[].password.secret` / `permissions` / `state`,
  `resources`, client Service name `<name>`, Ready condition for auto-ready, image digest pins + signatures, PSS
  `restricted`, NetworkPolicy (6379 / cluster bus 16379), aggregated RBAC for `ValkeyCluster`.
- Cloud skeletons: field names against the provider CRDs, Memorystore endpoint path in status, ElastiCache IAM auth
  instead of the token, Entra access-policy assignment on Azure.
- OpenChoreo: `openchoreo/cluster-resource-type.yaml` is not deployed (see its header).
- Kyverno only-through-XR (deny raw `ValkeyCluster` to tenants) and production HA rule: with the enable issue.

## Release and developer loop

As [`packages/postgresql`](../postgresql/README.md#release): `.github/workflows/package-valkey.yaml`, release-please
component `valkey`, image `ghcr.io/koorikla/platform/valkey`.

```bash
PACKAGE_ROOT=packages/valkey bash ci/scripts/crossplane/validate-render.sh   # UPDATE_EXPECTED=true to accept
```
