# external-dns

## Purpose

Wrapper chart for `external-dns` (`1.23.0` / `v0.23.0`). Publishes DNS records for Gateway API `HTTPRoute`, `GRPCRoute`, and `TLSRoute` resources to Route 53 or Cloudflare according to `installation.yaml` `dns.provider`.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all infra providers (`namespace: external-dns`; layers `values/dns-<dns.provider>.yaml` and `values/role-<role>.yaml`).
- **Catalog label:** `addons.platform.koorikla.io/external-dns` (`default: false`, opt-in with `"true"` per cluster).

## Key values

- `dns.{provider,domainFilters}`: `none`, `route53` (workload identity only), or `cloudflare` (scoped API token), plus allowed DNS zones.
- `external-dns.{policy,registry,txtOwnerId}`: `upsert-only` with `txt` ownership set to `<installation>-<cluster>`.
- `secrets.{store,cloudflare.remoteKey}`: reads `external-dns-cloudflare` from `platform` on `mgmt` and isolated store `dns` on workload clusters.

## Day-2 notes

- Rotating Cloudflare DNS tokens: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#6-eso-backed-platform-and-workload-secrets).

## Links

- [DNS: external-dns](../../docs/dns.md)
