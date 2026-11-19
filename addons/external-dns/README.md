# external-dns

## Purpose

Wrapper chart for `external-dns` (`1.23.0` / `v0.23.0`). Publishes DNS records for Gateway API `HTTPRoute`, `GRPCRoute`, and `TLSRoute` resources to Route 53 or Cloudflare according to `installation.yaml` `dns.provider`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all infra providers (`namespace: external-dns`; layers `values/dns-<dns.provider>.yaml` and `values/role-<role>.yaml`).
- **Catalog label:** `addons.platform.koorikla.io/external-dns` (`default: false`, opt-in with `"true"` per cluster).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster.name | string | `"sample"` |  |
| cluster.role | string | `"mgmt"` |  |
| dns.domainFilters | list | `[]` |  |
| dns.provider | string | `"none"` | `none`, `route53` (workload identity only), or `cloudflare` (scoped API token), plus allowed `dns.domainFilters` zones. |
| external-dns.domainFilters | list | `[]` |  |
| external-dns.enabled | bool | `false` |  |
| external-dns.image.tag | string | `"v0.23.0@sha256:1854499e2b08cee47c40a08e356bff20dcb192dbcfde8378fc3f900f12cad5a3"` |  |
| external-dns.interval | string | `"1m"` |  |
| external-dns.policy | string | `"upsert-only"` | `upsert-only` with `registry: txt` and `txtOwnerId` set to `<installation>-<cluster>`. |
| external-dns.provider.name | string | `"aws"` |  |
| external-dns.registry | string | `"txt"` |  |
| external-dns.resources.limits.cpu | string | `"100m"` |  |
| external-dns.resources.limits.memory | string | `"128Mi"` |  |
| external-dns.resources.requests.cpu | string | `"10m"` |  |
| external-dns.resources.requests.memory | string | `"48Mi"` |  |
| external-dns.sources[0] | string | `"gateway-httproute"` |  |
| external-dns.sources[1] | string | `"gateway-grpcroute"` |  |
| external-dns.sources[2] | string | `"gateway-tlsroute"` |  |
| external-dns.txtOwnerId | string | `"sample"` |  |
| secrets.cloudflare.enabled | bool | `false` |  |
| secrets.cloudflare.remoteKey | string | `"external-dns-cloudflare"` |  |
| secrets.store | string | `"platform"` | Reads `external-dns-cloudflare` (`secrets.cloudflare.remoteKey`) from `platform` on `mgmt` and isolated store `dns` on workload clusters. |

## Day-2 notes

- A rejected render names the bad value: `values.schema.json` checks types, formats and enums (Helm prints `at '/<path>'`); cross-field rules live in `templates/validate.yaml`.
- Rotating Cloudflare DNS tokens: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

## Links

- [DNS: external-dns](../../docs/dns.md)