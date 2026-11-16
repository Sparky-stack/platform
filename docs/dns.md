# DNS: external-dns (Route 53, Cloudflare)

Addon `external-dns` (upstream [kubernetes-sigs/external-dns](https://github.com/kubernetes-sigs/external-dns) chart
1.23.0, app v0.23.0) publishes the hostnames of Gateway API routes into a public DNS zone. It is **opt-in per cluster**
(catalog `default: false`) and runs on mgmt and workload clusters. Local installations do not use it: `coredns-local`
resolves `*.openchoreo.localhost` inside the clusters.

## What it does

| Setting | Value | Why |
|---|---|---|
| Sources | `gateway-httproute`, `gateway-grpcroute`, `gateway-tlsroute` | kgateway and OpenChoreo publish through Gateways. No Ingress, no Service source. Gateway API v1.5.1 standard serves all three as `gateway.networking.k8s.io/v1`, the version external-dns v0.23 watches. |
| Policy | `upsert-only` | Creates and updates records, never deletes. `sync` (also deletes records of removed routes) only per installation, on a zone dedicated to the platform. `create-only` is rejected. |
| Gateways | workload: `gateway-default` in `openchoreo-data-plane` only; mgmt: Gateways labelled `platform.koorikla.io/public-dns: "true"` only | `values/role-*.yaml` (`--gateway-name`/`--gateway-namespace`, `--gateway-label-filter`). Without it every route on every Gateway would be published, on mgmt internal hostnames (thunder, observer, rca-agent, api) and private LB IPs included. No mgmt Gateway carries the label today, so mgmt publishes nothing until you mark one public. |
| Registry | TXT, owner = `<installation>-<cluster>` | `txtOwnerId` is the catalog `clusterIdParameters`: unique even when two installations share a zone and both have a `dev1`. A cooperative marker, not a security boundary (see [Ownership](#ownership-and-what-txt-records-do-not-protect)). |
| Zones | `installation.yaml` `dns.domainFilters` | Delivered as a catalog `installationParameters` entry; never empty while running (ExternalDNS would otherwise manage every zone its credentials reach). |
| Image | `registry.k8s.io/external-dns/external-dns:v0.23.0@sha256:…` | Pinned by digest, multi-arch (amd64, arm64, arm). Pod Security restricted (chart defaults), so namespace `external-dns` is **not** in the Kyverno-exempt platform namespaces: admission and policies apply. |

## Ownership and what TXT records do not protect

The TXT registry is a cooperative marker, not a security boundary. It keeps honest controllers apart; it does not stop
a cluster whose credentials can write the zone:

- **First claim wins.** With `upsert-only` and owner checks, the first cluster to publish a hostname owns it; another
  cluster's controller skips it. A dev cluster can therefore squat a name before prod publishes it (a route with a
  prod hostname on a dev Gateway), and prod's controller will leave the dev record in place.
- **Credentials decide, not owners.** Anyone holding the zone credential can rewrite any record, TXT owners included.
  That is why the Cloudflare token never goes through a tenant-readable store (store `dns` on workload clusters) and
  why Route 53 has no static keys.

Recommendations, strongest first:

1. **One zone per environment** (`dev.example.com`, `prod.example.com`, delegated from the apex), each with its own
   credential. `dns.domainFilters` is installation-wide and overlays cannot change it, so this means one installation
   (or at least one credential) per environment's zone. A dev credential then cannot touch prod names at all.
2. **Route 53:** per-cluster roles with the `route53:ChangeResourceRecordSetsNormalizedRecordNames` condition (see
   [Route 53](#route-53-workload-identity)).
3. **Cloudflare:** API tokens scope to zones, not names; only separate zones separate clusters.

## Installation facts: `dns:`

```yaml
# installations/<inst>/installation.yaml
dns:
  provider: cloudflare        # none | route53 | cloudflare
  domainFilters:              # the only zones ExternalDNS may touch
    - example.com
```

`installation.yaml` holds the facts other parts of the platform may need too (which provider, which zones). Provider
tuning (`aws-zone-type`, `cloudflare-proxied`, an IRSA role ARN, `policy: sync`) is ordinary Helm values in
`installations/<inst>/addons/external-dns/values.yaml`.

## Choosing the DNS provider (independent of the infra provider)

The addon ApplicationSet layers `values/provider-<provider>.yaml` from the cluster label
`platform.koorikla.io/provider`, the **CAPI infrastructure provider** (`docker | aws | hetzner`). Where DNS lives is a
different fact: a Hetzner installation can use Route 53, an AWS one Cloudflare. Keying DNS off the infra provider would
force every such combination into per-installation copies of provider settings.

So the catalog gained a generic field, `installationValueFiles`: value files chosen by a template over installation
values, rendered once per installation by `charts/platform` and layered after the role/provider/cni overlays, before the
installation overlays. external-dns uses it to pick its DNS provider file:

```yaml
# charts/platform/values.yaml
external-dns: { namespace: external-dns, roles: [mgmt, workload], default: false,
  clusterIdParameters: [external-dns.txtOwnerId],
  installationParameters: { external-dns.domainFilters: '{{ printf "{%s}" (join "," .Values.dns.domainFilters) }}' },
  installationValueFiles: ['values/dns-{{ .Values.dns.provider }}.yaml'] }
```

| File | Layered when | Sets |
|---|---|---|
| `addons/external-dns/values.yaml` | always | sources, policy, registry; `external-dns.enabled: false` (Chart.yaml condition) |
| `values/role-mgmt.yaml` / `role-workload.yaml` | by role | ESO store `platform` / `dns` (never the tenant store `default`) |
| `values/dns-route53.yaml` | `dns.provider: route53` | `enabled: true`, `provider.name: aws`, `aws-zone-type: public` |
| `values/dns-cloudflare.yaml` | `dns.provider: cloudflare` | `enabled: true`, `provider.name: cloudflare`, `CF_API_TOKEN` from the ESO Secret |
| `installations/<inst>/addons/external-dns/values.yaml` | always | tuning only |

`dns.provider: none` layers nothing (missing value files are ignored), so the subchart stays off. Guards in
`templates/validate.yaml` turn every inconsistency into a failed render (the Argo CD Application shows it) instead of a
running controller doing the wrong thing:

- the addon is opted in on a cluster but the installation's `dns.provider` is `none`;
- an overlay switches `provider.name` away from `dns.provider`, or the provider file was not layered;
- `external-dns.domainFilters` differs from `dns.domainFilters`, or the list is empty;
- `txtOwnerId` is not `<installation>-<cluster>`; `policy` is not `upsert-only` or `sync`;
- `extraArgs` sets `domain-filter`, `regex-domain-filter`, `zone-id-filter`, `zone-name-filter`, `aws-zone-tags`,
  `txt-prefix`, `txt-suffix` or `txt-owner-id` (or `txtPrefix`/`txtSuffix` values): an overlay must not widen the zones
  or change ownership; `extraArgs` no longer scopes the Gateways (`gateway-name` or `gateway-label-filter`);
- Cloudflare without `CF_API_TOKEN` from Secret `external-dns-cloudflare`, or on a workload cluster from any store but
  `dns`;
- static AWS keys (`secrets.aws`, `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` env).

Helm parameters beat value files, so an overlay cannot replace the zones either.

## Credentials

### Route 53: workload identity

No static keys and no ExternalSecret: the render fails on `secrets.aws` or AWS key env vars. Two identities only:

- **IRSA**: set `external-dns.serviceAccount.annotations."eks.amazonaws.com/role-arn"` in the installation overlay. On
  CAPA k3s clusters this needs the cluster's service-account issuer registered as an IAM OIDC provider plus the pod
  identity webhook.
- **EKS Pod Identity**: a PodIdentityAssociation for `external-dns/external-dns`; no annotation.

Not the nodes' EC2 instance profile: pods reach IMDS only with metadata hop limit 2, which hands the node role (and
its DNS write access) to every pod on the node.

IAM policy: `route53:ChangeResourceRecordSets` on the hosted zones of `dns.domainFilters` only, plus
`route53:ListHostedZones`, `route53:ListResourceRecordSets`, `route53:ListTagsForResources`. One role per cluster,
with `ChangeResourceRecordSets` conditioned on `route53:ChangeResourceRecordSetsNormalizedRecordNames` (`ForAllValues`,
`StringLike` the cluster's own names, e.g. `*.dev-euc1.aws.example.com`), so a cluster cannot claim another's
hostnames (see [Ownership](#ownership-and-what-txt-records-do-not-protect)).

### Cloudflare: scoped API token from ESO

Create an API token (not the global API key) with `Zone:Zone:Read` and `Zone:DNS:Edit` on the zones of
`dns.domainFilters` only. Store it as key `external-dns-cloudflare`, property `api-token`:

- **mgmt**: store `platform` (namespace `external-dns` is in secret-stores `platformStore.namespaces`).
- **workload clusters**: store `dns`, never `default`. `default` is the ClusterDataPlane `secretStoreRef`, so any
  tenant SecretReference / ExternalSecret could sync a key from it and get `DNS:Edit` on every zone, prod's and mgmt's
  records included. Addon secret-stores renders `ClusterSecretStore/dns` on workload clusters while
  `dns.provider: cloudflare`, with `conditions` admitting namespace `external-dns` only (AGENTS.md invariant 5
  exception, covered by `hack/tests/test_secret_store_scope.sh`), reading from a location `default` cannot:

  | Backend | Store `dns` reads | You provide |
  |---|---|---|
  | `kubernetes` | namespace `external-dns-credentials` (SA `eso-workload-dns`) | the Secret there (`default` reads `openchoreo-secrets`) |
  | `aws` | Secrets Manager via SA `eso-aws-dns`, role `secrets.dnsStore.aws.role` | an IAM role that reads only this key; deny it in the `default` role (`secrets.aws.role`) |
  | `vault` | Vault role `secrets.dnsStore.vault.role` (SA `eso-vault-dns`), path `secrets.dnsStore.vault.path` (default: `secrets.vault.path`) | a policy that reads only this key; deny it in the `default` role's policy |

  The render fails when the dedicated role is missing or equals the tenant store's; addon external-dns fails on a
  workload cluster whose Cloudflare token is not from store `dns`.

`templates/secrets.yaml` syncs it to Secret `external-dns-cloudflare`. Records are DNS-only
(`cloudflare-proxied` off) unless the installation overlay sets `cloudflare-proxied: true`.

## Turning it on

1. `installation.yaml`: `dns.provider` and `dns.domainFilters` (the examples ship `aws.example.com` /
   `hetzner.example.com` placeholders).
2. Credentials as above.
3. Opt in per cluster: `mgmt.addons.external-dns: "true"` in `installation.yaml` for mgmt, `addons: { external-dns: true }`
   in `installations/<inst>/clusters/<name>.yaml` for a workload cluster (label
   `addons.platform.koorikla.io/external-dns: "true"`).

Examples: `installations/aws-example` (Route 53) and `installations/hetzner-example` (Cloudflare) carry `dns:` and an
overlay; no cluster is opted in.

## Tests

- `addons/external-dns/tests/` (helm-unittest): both providers, stores per role, every guard (negative tests).
- `hack/tests/test_external_dns.sh`: renders the addon through the real catalog for every cluster of `aws-example` and
  `hetzner-example` with the toggle forced on, plus the failure cases (no provider, provider switch, zone override).
- `charts/platform/tests/`: `installationValueFiles` order and the path guard.

## Open items
Live Route 53 (IRSA on CAPA k3s) and Cloudflare runs: [#21](https://github.com/koorikla/platform/issues/21).
