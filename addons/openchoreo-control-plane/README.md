# openchoreo-control-plane

## Purpose

Wrapper chart for `openchoreo-control-plane` (`1.3.3`) on `mgmt`. Runs the OpenChoreo controller-manager, API, Backstage console (with golden-path scaffolder templates), and `cluster-gateway`, plus ESO secrets and CA export to `fleet`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-control-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-control-plane` (`default: true`, opt-out with `"false"`).

## Key values

- `openchoreo.{orgNamespace,controlPlane.host,controlPlane.clusterGatewayURL}`: org namespace (`default`), console/API hostnames, and agent WebSocket endpoint.
- `backstageSecrets.{store,remoteKey}` and `scaffolder.githubApp`: pulls Backstage secrets (`openchoreo`) and optional GitHub App credentials from `ClusterSecretStore/platform`.
- `gatewayCA.{enabled,store,namespace,sourceSecret}`: exports `cluster-gateway-ca` via `ClusterSecretStore/mgmt-openchoreo` to `fleet` for workload agent trust.
- `openchoreo-control-plane.backstage.features.{observability,workflows}.enabled`: wired from `installation.yaml` via `installationParameters`.

## Day-2 notes

- Control-plane triage and upgrades: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).

## Links

- [OpenChoreo](../../docs/openchoreo.md)
- [Golden-path project templates](../../docs/project-templates.md)
