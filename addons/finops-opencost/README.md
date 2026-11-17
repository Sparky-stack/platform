# finops-opencost

## Purpose

Wrapper chart for OpenChoreo's `finops-opencost` module (`0.2.1`) on `mgmt`. Runs OpenCost and its OpenChoreo adapter beside the observability plane to attribute cluster and workload resource cost for the opt-in FinOps agent.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-observability-plane`).
- **Catalog label:** `addons.platform.koorikla.io/finops-opencost` (`default: false`, opt-in via `installation.yaml` `mgmt.addons.finops-opencost: "true"`).

## Key values

- `finops-opencost.opencost.opencost.exporter.defaultClusterId`: default cluster attribution ID (`mgmt`).
- `finops-opencost.opencost.opencost.exporter.securityContext`: hardened to meet Pod Security `restricted` (`runAsNonRoot: true`, drop `ALL`).
- `finops-opencost.adapter.image.tag`: `0.2.1` pinned by multi-arch index digest.

## Day-2 notes

- Verifying Prometheus metrics backing OpenCost: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#3-addon-chart-bumps-and-staged-rollout-addonsrevision).

## Links

- [OpenChoreo AI agents](../../docs/ai-agents.md)
