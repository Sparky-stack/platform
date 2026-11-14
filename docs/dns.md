# ExternalDNS (Route53 and Cloudflare)

Opt-in addon (`addons/external-dns`, upstream `kubernetes-sigs/external-dns` chart `1.23.0` / app `v0.23.0`) for managing public/private DNS records from Kubernetes Gateway API routes and Services. Disabled by default (`catalog default: false`) so local k3d/CAPD clusters continue using `coredns-local` without external DNS dependencies.

## What it watches and how it owns records

- **Sources:** `gateway-httproute`, `gateway-tlsroute`, `gateway-grpcroute`, `service` (matching `kgateway` and OpenChoreo's Gateway API routing).
- **Policy:** `upsert-only` by default (creates and updates records, never deletes them). Set `external-dns.policy: sync` in `installations/<inst>/addons/external-dns/values.yaml` only when you want ExternalDNS to delete records on resource removal.
- **Ownership:** `registry: txt` with `txtOwnerId` set to `<cluster.name>` via catalog `clusterNameParameters: [external-dns.txtOwnerId]`, so multiple clusters sharing one DNS zone never overwrite each other's records.
- **Domain scope:** `domainFilters` comes from `installation.yaml` (`dns.domainFilters`) via catalog `installationParameters` and/or `installations/<inst>/addons/external-dns/values.yaml` (checked at render time by `templates/validate.yaml`).

## `installation.yaml` `dns:` schema

```yaml
dns:
  provider: none            # none | route53 | cloudflare
  domainFilters:
    - example.com           # zones ExternalDNS is permitted to touch
  route53:                  # optional provider metadata (when provider: route53)
    zoneType: public        # public | private
  cloudflare:               # optional provider metadata (when provider: cloudflare)
    proxied: false
```

## Catalog entry (`charts/platform/values.yaml`)

```yaml
external-dns: { namespace: external-dns, roles: [mgmt, workload], default: false, clusterNameParameters: [external-dns.txtOwnerId], installationParameters: { external-dns.domainFilters: '{ {{- join "," .Values.dns.domainFilters -}} }' } }
```

Enable per cluster via `mgmt.addons.external-dns: "true"` or `addons.external-dns: "true"` in `installations/<inst>/clusters/<name>.yaml` (which sets label `addons.platform.koorikla.io/external-dns: "true"`).

## DNS-provider selection vs infra-provider overlays

The addon ApplicationSet (`charts/platform/templates/appset-addons.yaml`) loads `values/provider-<infra>.yaml` from `platform.koorikla.io/provider` (`docker | aws | hetzner`), which is the **CAPI infrastructure provider**, not `dns.provider`.

- **AWS infra + Route53 (`aws-example`):** `values/provider-aws.yaml` is loaded automatically and configures Route53 (`provider.name: aws`, `aws-zone-type: public`, IRSA/Pod Identity).
- **Any infra + Cloudflare (`hetzner-example`, or AWS infra using Cloudflare DNS):** `values/provider-cloudflare.yaml` is a reference overlay; set the Cloudflare configuration in `installations/<inst>/addons/external-dns/values.yaml` (which layers *after* `values/provider-<infra>.yaml` in `valueFiles` precedence). If overriding `values/provider-aws.yaml`, include `extraArgs: { aws-zone-type: null }` so Helm drops the AWS-only flag.

## Provider authentication

### AWS Route53
- **Default (IRSA / EKS Pod Identity / node IAM role):** No static AWS keys and no `ExternalSecret`. On EKS with IRSA, set `external-dns.serviceAccount.annotations["eks.amazonaws.com/role-arn"]` in `installations/<inst>/addons/external-dns/values.yaml`. On EKS Pod Identity or EC2 instance profiles, leave `annotations: {}`.
- **Static-credentials alternative (non-EKS without Pod Identity):** Seed key `external-dns-aws` (properties `access-key-id`, `secret-access-key`) in ClusterSecretStore `default` (workload) / `platform` (mgmt), set `secrets.aws.enabled: true`, and wire `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from Secret `external-dns-aws` (commented template in `addons/external-dns/values/provider-aws.yaml`).

### Cloudflare
- Create a scoped Cloudflare API Token (`Zone:Zone:Read`, `Zone:DNS:Edit`).
- Seed key `external-dns-cloudflare` with property `api-token` in ClusterSecretStore `platform` (mgmt) and/or `default` (workload).
- `templates/secrets.yaml` renders `ExternalSecret/external-dns-cloudflare` when `secrets.cloudflare.enabled: true` or `dns.provider: cloudflare`, and `external-dns.env` injects `CF_API_TOKEN`.
- `proxied` defaults to `false`; uncomment `cloudflare-proxied: null` in `extraArgs` to proxy DNS records through Cloudflare.

## Untested / VERIFY
- Live Route53 and Cloudflare reconciliation against real zones and IAM/token credentials.
- `hack/test.sh` `installationParameters` evaluation for list values (`join "," .Values.dns.domainFilters`) once `external-dns` is added to `charts/platform/values.yaml`.
