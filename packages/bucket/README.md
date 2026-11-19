# bucket: Crossplane Configuration package

**Status: layout** (#241) - not installed on any cluster, not live-tested. The `rustfs` backend renders offline in CI;
the cloud backends are skeletons that render but were never applied. Enable + live proof: follow-up issue.

The platform's object storage API (`platform.koorikla.io/v1alpha1 Bucket`, namespaced XR): one S3-compatible bucket.
Same layout as [`packages/postgresql`](../postgresql/README.md) and [docs/crossplane.md](../../docs/crossplane.md):
XRD + one Composition `bucket` (environment-configs -> embedded function `compose-bucket` -> auto-ready) reading
`$facts.backend` from the EnvironmentConfig `platform-bucket`. `functions/compose-bucket/` is Helm-style, one
template per composed object: `00-prelude.yaml.gotmpl` (facts, backend check, derived values), shared objects
`1x-*`, per-backend objects `<backend>-<object>.yaml.gotmpl` (render only on that backend), `90-xr-status`.
Render tests pin the upstream Functions like the addon (`tests/render/functions.yaml`); `validate-render.sh`
builds the project and adds the embedded function (package-derived name) for the render.

## Developer contract

| Field | Default | Meaning |
|---|---|---|
| `versioning` | `false` | keep every object version |
| `storageGiB` | `10` | `rustfs` only: volume of the local RustFS tenant |
| `deletionPolicy` | `Retain` | cloud: keep bucket and objects when the XR goes |

Connection Secret `<name>-bucket` (`status.secretName`), same keys on every backend: `endpoint`, `bucket`, `region`,
`accessKeyId`, `secretAccessKey`. Only `rustfs` fills the two credential keys (a per-bucket user with a policy scoped
to the bucket); cloud backends leave them empty and the app authenticates with workload identity (EKS Pod Identity /
GKE Workload Identity Federation / Azure Workload Identity) - no static cloud keys. The bucket name is derived from
cluster/namespace/name (globally unique in cloud), reported in `status.bucket`.

## Backends

| `backend` | Composes | Facts |
|---|---|---|
| `rustfs` | RustFS `Tenant` (1 server; bucket, policy, user), ESO `Password`s + `ExternalSecret`s, policy `ConfigMap` | `rustfsImage` |
| `aws-s3` | `s3.aws.m.upbound.io Bucket` + `BucketPublicAccessBlock` + `BucketVersioning` | `region` |
| `gcp-storage` | `storage.gcp.m.upbound.io Bucket` (uniform access, public access prevention) | `project`, `region` |
| `azure-blob` | `storage.azure.m.upbound.io Account` (shared keys off) + `Container` | `resourceGroupName`, `location` |

## Local backend choice: RustFS operator

- Owner choice (#241): [RustFS](https://github.com/rustfs/rustfs) (Apache-2.0, S3-compatible, Rust). Its operator
  ([rustfs/operator](https://github.com/rustfs/operator), `rustfs.com/v1alpha1 Tenant`) declares buckets, canned
  policies and users in the Tenant spec, so the Composition needs no Job or provider. It is pre-release (v0.x):
  VERIFY before relying on it; fallback is the official RustFS chart plus a provisioning Job.
- One Tenant per Bucket XR: a namespaced XR can only compose into its own namespace, and per-namespace tenants keep
  credentials on the data plane next to the app. Cost: one RustFS pod per bucket.
- Later: the operator's STS (`PolicyBinding`, ServiceAccount token -> temporary credentials) is the local analogue of
  workload identity and can replace the static per-bucket user.
- No CNCF S3 server exists; MinIO (AGPL, community edition stripped of the console and moved to source-only) is not
  used. Kubernetes COSI (SIG Storage, alpha) is the future standard for bucket claims: see docs/crossplane.md.

## VERIFY (before enabling)

- RustFS Tenant fields: `credsSecret` keys (`accesskey` / `secretkey`), `users[].secret` key mapping, `pools[].persistence`,
  S3 Service name `<name>-io`, Ready condition, image tag + digest, PSS `restricted`, NetworkPolicy (9000).
- Cloud skeletons: field names against the provider CRDs; workload identity binding per app (Pod Identity association,
  GCS IAM member, Azure role assignment) is not composed yet; GCS via S3 SDKs needs the XML API interop.
- OpenChoreo: `openchoreo/cluster-resource-type.yaml` is not deployed (see its header); empty credential keys in cloud.
- Kyverno only-through-XR (deny raw `Tenant` to tenants): with the enable issue.

## Release and developer loop

As [`packages/postgresql`](../postgresql/README.md#release): `.github/workflows/package-bucket.yaml`, release-please
component `bucket`, image `ghcr.io/koorikla/platform/bucket`.

```bash
PACKAGE_ROOT=packages/bucket bash ci/scripts/crossplane/validate-render.sh   # UPDATE_EXPECTED=true to accept
```
