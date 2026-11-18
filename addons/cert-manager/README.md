# cert-manager

## Purpose

Wrapper chart for `cert-manager` (`v1.21.3`). Issues X.509 CAs and leaf certificates for platform control planes, admission webhooks, Gateway API TLS listeners, OpenChoreo per-cluster agent PKI, and Vault/OpenBao issuers.

## Where it runs

- **Roles / providers:** `roles: [mgmt, workload]`, all providers (`namespace: cert-manager`).
- **Catalog label:** `addons.platform.koorikla.io/cert-manager` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cert-manager.acmesolver.image.digest | string | `"sha256:c8c1225bb2fe8ab37a330b77f0d8c2ee6a41210fcb54fc07ca606ab9a022b8b7"` |  |
| cert-manager.acmesolver.image.tag | string | `"v1.21.3"` |  |
| cert-manager.cainjector.image.digest | string | `"sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f"` |  |
| cert-manager.cainjector.image.tag | string | `"v1.21.3"` |  |
| cert-manager.cainjector.resources.requests.cpu | string | `"25m"` |  |
| cert-manager.cainjector.resources.requests.memory | string | `"64Mi"` |  |
| cert-manager.config.enableGatewayAPI | bool | `true` | `true` so Gateway API `Gateway` listeners can request certificates. |
| cert-manager.crds.enabled | bool | `true` | `true` (installs cert-manager CRDs with the chart). |
| cert-manager.image.digest | string | `"sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc"` |  |
| cert-manager.image.tag | string | `"v1.21.3"` | `v1.21.3` pinned by multi-arch index `digest` (alongside `webhook.image`, `cainjector.image`, `startupapicheck.image`, `acmesolver.image`). |
| cert-manager.resources.requests.cpu | string | `"25m"` |  |
| cert-manager.resources.requests.memory | string | `"64Mi"` |  |
| cert-manager.startupapicheck.image.digest | string | `"sha256:1c519d4afca1413d1e4ccd78bdc756184418ab55a34569a3b3de39d32f9974e1"` |  |
| cert-manager.startupapicheck.image.tag | string | `"v1.21.3"` |  |
| cert-manager.webhook.image.digest | string | `"sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458"` |  |
| cert-manager.webhook.image.tag | string | `"v1.21.3"` |  |
| cert-manager.webhook.resources.requests.cpu | string | `"10m"` |  |
| cert-manager.webhook.resources.requests.memory | string | `"32Mi"` |  |

## Day-2 notes

- Inspecting renewal times and rotating CAs or leaf certificates: [certificates and secrets](../../docs/runbooks/certificates-and-secrets.md#1-cert-manager-cas-and-leaf-certificates).
- Chart version and digest bumps: [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [Architecture](../../docs/architecture.md)
- [Networking](../../docs/networking.md)