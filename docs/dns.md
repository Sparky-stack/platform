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
| Registry | TXT, owner = cluster name | `txtOwnerId` is the catalog `clusterNameParameters`, so clusters sharing a zone never touch each other's records. |
| Zones | `installation.yaml` `dns.domainFilters` | Delivered as a catalog `installationParameters` entry; never empty while running (ExternalDNS would otherwise manage every zone its credentials reach). |
| Image | `registry.k8s.io/external-dns/external-dns:v0.23.0@sha256:…` | Pinned by digest, multi-arch (amd64, arm64, arm). Pod Security restricted (chart defaults). |

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
  clusterNameParameters: [external-dns.txtOwnerId],
  installationParameters: { external-dns.domainFilters: '{{ printf "{%s}" (join "," .Values.dns.domainFilters) }}' },
  installationValueFiles: ['values/dns-{{ .Values.dns.provider }}.yaml'] }
```

| File | Layered when | Sets |
|---|---|---|
| `addons/external-dns/values.yaml` | always | sources, policy, registry; `external-dns.enabled: false` (Chart.yaml condition) |
| `values/role-mgmt.yaml` / `role-workload.yaml` | by role | ESO store `platform` / `default` |
| `values/dns-route53.yaml` | `dns.provider: route53` | `enabled: true`, `provider.name: aws`, `aws-zone-type: public` |
| `values/dns-cloudflare.yaml` | `dns.provider: cloudflare` | `enabled: true`, `provider.name: cloudflare`, `CF_API_TOKEN` from the ESO Secret |
| `installations/<inst>/addons/external-dns/values.yaml` | always | tuning only |

`dns.provider: none` layers nothing (missing value files are ignored), so the subchart stays off. Guards in
`templates/validate.yaml` turn every inconsistency into a failed render (the Argo CD Application shows it) instead of a
running controller doing the wrong thing:

- the addon is opted in on a cluster but the installation's `dns.provider` is `none`;
- an overlay switches `provider.name` away from `dns.provider`, or the provider file was not layered;
- `external-dns.domainFilters` differs from `dns.domainFilters`, or the list is empty;
- `txtOwnerId` is not the cluster name; `policy` is not `upsert-only` or `sync`;
- Cloudflare without `CF_API_TOKEN` from Secret `external-dns-cloudflare`.

Helm parameters beat value files, so an overlay cannot widen the zones either.

## Credentials

### Route 53: workload identity

No static keys and no ExternalSecret by default. The AWS SDK default chain picks up whichever identity is present:

- **IRSA**: set `external-dns.serviceAccount.annotations."eks.amazonaws.com/role-arn"` in the installation overlay. On
  CAPA k3s clusters this needs the cluster's service-account issuer registered as an IAM OIDC provider plus the pod
  identity webhook.
- **EKS Pod Identity**: a PodIdentityAssociation for `external-dns/external-dns`; no annotation.
- **EC2 instance profile** of the nodes (CAPA `iamInstanceProfile`): no annotation; IMDSv2 hop limit >= 2 for pods. Every
  pod on the node gets the role, so prefer the two above.

IAM policy: `route53:ChangeResourceRecordSets` on the hosted zones of `dns.domainFilters` only, plus
`route53:ListHostedZones`, `route53:ListResourceRecordSets`, `route53:ListTagsForResources`.

Last resort for clusters with none of these (commented in `values/dns-route53.yaml`): key `external-dns-aws`
(`access-key-id`, `secret-access-key`), `secrets.aws.enabled: true`, and the two `env` entries.

### Cloudflare: scoped API token from ESO

Create an API token (not the global API key) with `Zone:Zone:Read` and `Zone:DNS:Edit` on the zones of
`dns.domainFilters` only. Store it as key `external-dns-cloudflare`, property `api-token`, in the store of every
opted-in cluster: `platform` on mgmt (namespace `external-dns` is in secret-stores `platformStore.namespaces`), `default`
on workload clusters. `templates/secrets.yaml` syncs it to Secret `external-dns-cloudflare`. Records are DNS-only
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

## VERIFY

- Live reconciliation against real Route 53 / Cloudflare zones (no installation has run it yet).
- IRSA on CAPA k3s (self-hosted issuer + pod identity webhook) is not wired by this repo yet.
