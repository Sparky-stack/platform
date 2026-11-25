# openchoreo-control-plane

## Purpose

Wrapper chart for `openchoreo-control-plane` (`1.3.3`) on `mgmt`. Runs the OpenChoreo controller-manager, API, Backstage console (with golden-path scaffolder templates), and `cluster-gateway`, plus ESO secrets and CA export to `fleet`.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: openchoreo-control-plane`).
- **Catalog label:** `addons.platform.koorikla.io/openchoreo-control-plane` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| appExtensions | list | the image's 32 entries (values.yaml) | Backstage `app.extensions` of the openchoreo-ui image, verbatim (v1.3.3 /app/app-config.yaml). Backstage REPLACES arrays from earlier config files, so templates/backstage-cost-views.yaml repeats this list before its own entries; a chart bump re-checks it. |
| backstageSecrets.remoteKey | string | `"openchoreo"` |  |
| backstageSecrets.store | string | `"platform"` | Pulls Backstage secrets (`openchoreo`) and optional `scaffolder.githubApp` credentials from `ClusterSecretStore/platform`. |
| costViews.enabled | string | `"false"` | Show the console's cost views. Set by the catalog from the mgmt cluster label `addons.platform.koorikla.io/finops-opencost` (`installation.yaml` `mgmt.addons.finops-opencost`); a string from the ApplicationSet. |
| costViews.extensions | list | `["page:openchoreo-observability/cost-insights","entity-card:openchoreo-observability/cost-insights-summary","entity-content:openchoreo-observability/project-cost-analysis"]` | Backstage extension IDs (`<kind>:<plugin>/<name>`) of the cost views, switched off while `enabled` is false. |
| gatewayCA.enabled | bool | `true` | Exports `cluster-gateway-ca` (`gatewayCA.{enabled,store,namespace,sourceSecret}`) via `ClusterSecretStore/mgmt-openchoreo` to `fleet` for workload agent trust. |
| gatewayCA.name | string | `"openchoreo-gateway-ca"` |  |
| gatewayCA.namespace | string | `"fleet"` |  |
| gatewayCA.sourceSecret | string | `"cluster-gateway-ca"` |  |
| gatewayCA.store | string | `"mgmt-openchoreo"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[0].rules[0].allow[0] | string | `"Group"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[0].target | string | `"/app/catalog-entities/org.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[0].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[10].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[10].target | string | `"/app/templates/create-openchoreo-clusterresourcetype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[10].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[11].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[11].target | string | `"/app/templates/create-openchoreo-clusterprojecttype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[11].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[12].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[12].target | string | `"/app/templates/create-openchoreo-clustertrait/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[12].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[13].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[13].target | string | `"/app/templates/create-openchoreo-clusterworkflow/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[13].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[14].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[14].target | string | `"/app/templates/create-openchoreo-notification-channel/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[14].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[15].target | string | `"https://github.com/Sparky-stack/platform/blob/main/templates/catalog-info.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[15].type | string | `"url"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[1].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[1].target | string | `"/app/templates/create-openchoreo-componenttype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[1].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[2].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[2].target | string | `"/app/templates/create-openchoreo-resourcetype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[2].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[3].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[3].target | string | `"/app/templates/create-openchoreo-projecttype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[3].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[4].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[4].target | string | `"/app/templates/create-openchoreo-trait/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[4].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[5].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[5].target | string | `"/app/templates/create-openchoreo-workflow/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[5].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[6].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[6].target | string | `"/app/templates/create-openchoreo-environment/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[6].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[7].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[7].target | string | `"/app/templates/create-openchoreo-namespace/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[7].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[8].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[8].target | string | `"/app/templates/create-openchoreo-deploymentpipeline/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[8].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[9].rules[0].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[9].target | string | `"/app/templates/create-openchoreo-clustercomponenttype/template.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.locations[9].type | string | `"file"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[0].allow[0] | string | `"API"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[0].allow[1] | string | `"Component"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[0].allow[2] | string | `"Location"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[0].allow[3] | string | `"Resource"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[1].allow[0] | string | `"Template"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[1].locations[0].exact | string | `"https://github.com/Sparky-stack/platform/blob/main/templates/catalog-info.yaml"` |  |
| openchoreo-control-plane.backstage.appConfig.catalog.rules[1].locations[0].type | string | `"url"` |  |
| openchoreo-control-plane.backstage.baseUrl | string | `"http://openchoreo.localhost:8080"` |  |
| openchoreo-control-plane.backstage.extraArgs[0] | string | `"--config"` |  |
| openchoreo-control-plane.backstage.extraArgs[1] | string | `"app-config.cost-views.yaml"` |  |
| openchoreo-control-plane.backstage.extraVolumeMounts[0].mountPath | string | `"/app/app-config.cost-views.yaml"` |  |
| openchoreo-control-plane.backstage.extraVolumeMounts[0].name | string | `"cost-views-config"` |  |
| openchoreo-control-plane.backstage.extraVolumeMounts[0].readOnly | bool | `true` |  |
| openchoreo-control-plane.backstage.extraVolumeMounts[0].subPath | string | `"app-config.cost-views.yaml"` |  |
| openchoreo-control-plane.backstage.extraVolumes[0].configMap.name | string | `"backstage-cost-views"` |  |
| openchoreo-control-plane.backstage.extraVolumes[0].name | string | `"cost-views-config"` |  |
| openchoreo-control-plane.backstage.features.observability.enabled | bool | `true` |  |
| openchoreo-control-plane.backstage.features.workflows.enabled | bool | `true` | Wired from `installation.yaml` via `installationParameters` (alongside `features.observability.enabled`). |
| openchoreo-control-plane.backstage.http.hostnames[0] | string | `"openchoreo.localhost"` |  |
| openchoreo-control-plane.backstage.image.tag | string | `"v1.3.3@sha256:997f6605c620514a34557f64716830c845830119625edd1e13669d2637d3f79c"` |  |
| openchoreo-control-plane.backstage.resources.limits.cpu | string | `"1"` |  |
| openchoreo-control-plane.backstage.resources.limits.memory | string | `"1Gi"` |  |
| openchoreo-control-plane.backstage.resources.requests.cpu | string | `"100m"` |  |
| openchoreo-control-plane.backstage.resources.requests.memory | string | `"256Mi"` |  |
| openchoreo-control-plane.backstage.secretName | string | `"backstage-secrets"` |  |
| openchoreo-control-plane.clusterGateway.image.tag | string | `"v1.3.3@sha256:a3486320d84c4dcbdccb6ecef09550b015d268c7002e504b221021a517cc0360"` |  |
| openchoreo-control-plane.clusterGateway.tls.dnsNames[0] | string | `"cluster-gateway.openchoreo-control-plane.svc"` |  |
| openchoreo-control-plane.clusterGateway.tls.dnsNames[1] | string | `"cluster-gateway.openchoreo-control-plane.svc.cluster.local"` |  |
| openchoreo-control-plane.clusterGateway.tls.dnsNames[2] | string | `"cluster-gateway.openchoreo.localhost"` |  |
| openchoreo-control-plane.clusterGateway.tls.issuerRef.name | string | `"cluster-gateway-server-issuer"` |  |
| openchoreo-control-plane.clusterGateway.tlsRoute.enabled | bool | `true` |  |
| openchoreo-control-plane.clusterGateway.tlsRoute.hosts[0].host | string | `"cluster-gateway.openchoreo.localhost"` |  |
| openchoreo-control-plane.clusterGateway.tlsRoute.hosts[0].paths[0].path | string | `"/"` |  |
| openchoreo-control-plane.clusterGateway.tlsRoute.hosts[0].paths[0].pathType | string | `"Prefix"` |  |
| openchoreo-control-plane.controllerManager.image.tag | string | `"v1.3.3@sha256:ce7e9d6394cd10bdd7d4f9f5746468b3f1f010b714b878a8a51051aac0b97863"` |  |
| openchoreo-control-plane.controllerManager.resources.limits.cpu | string | `"1"` |  |
| openchoreo-control-plane.controllerManager.resources.limits.memory | string | `"1Gi"` |  |
| openchoreo-control-plane.controllerManager.resources.requests.cpu | string | `"100m"` |  |
| openchoreo-control-plane.controllerManager.resources.requests.memory | string | `"256Mi"` |  |
| openchoreo-control-plane.eventForwarder.image.tag | string | `"v1.3.3@sha256:9030b624d60781aa6ec25ccf5d3ff2af229882439a517afe46083fbfe769da9b"` |  |
| openchoreo-control-plane.gateway.httpPort | int | `8080` |  |
| openchoreo-control-plane.gateway.httpsPort | int | `8443` |  |
| openchoreo-control-plane.gateway.tls.enabled | bool | `false` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.image | string | `"registry.k8s.io/kubectl:v1.36.0@sha256:63e5e76b746bb8b891a94968d380736c035e768dab0d56ddad1f50c750a4be39"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].entitlement.claim | string | `"groups"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].entitlement.value | string | `"platform-engineers"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].name | string | `"admin-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[0].roleMappings[0].roleRef.name | string | `"admin"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].entitlement.claim | string | `"groups"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].entitlement.value | string | `"developers"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].name | string | `"developer-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].roleMappings[0].roleRef.name | string | `"cluster-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].roleMappings[1].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[1].roleMappings[1].roleRef.name | string | `"namespace-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].entitlement.claim | string | `"groups"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].entitlement.value | string | `"qa"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].name | string | `"qa-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].roleMappings[0].roleRef.name | string | `"cluster-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].roleMappings[1].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[2].roleMappings[1].roleRef.name | string | `"namespace-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].entitlement.claim | string | `"groups"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].entitlement.value | string | `"release-managers"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].name | string | `"release-manager-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].roleMappings[0].roleRef.name | string | `"cluster-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].roleMappings[1].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[3].roleMappings[1].roleRef.name | string | `"namespace-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].entitlement.value | string | `"service_mcp_client"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].name | string | `"mcp-tryout-client-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[4].roleMappings[0].roleRef.name | string | `"mcp-service"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].entitlement.value | string | `"openchoreo-backstage-client"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].name | string | `"backstage-catalog-reader-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].roleMappings[0].roleRef.name | string | `"backstage-catalog-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[5].system | bool | `true` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].entitlement.value | string | `"openchoreo-finops-agent"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].name | string | `"finops-agent-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].roleMappings[0].roleRef.name | string | `"finops-agent"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[6].system | bool | `true` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].entitlement.value | string | `"openchoreo-rca-agent"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].name | string | `"rca-agent-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].roleMappings[0].roleRef.name | string | `"rca-agent"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[7].system | bool | `true` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].entitlement.value | string | `"openchoreo-workload-publisher-client"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].name | string | `"workload-publisher-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].roleMappings[0].roleRef.name | string | `"workload-publisher"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[8].system | bool | `true` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].effect | string | `"allow"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].entitlement.claim | string | `"client_id"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].entitlement.value | string | `"openchoreo-observer-resource-reader-client"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].kind | string | `"ClusterAuthzRoleBinding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].name | string | `"observer-resource-reader-binding"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].roleMappings[0].roleRef.kind | string | `"ClusterAuthzRole"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].roleMappings[0].roleRef.name | string | `"observer-resource-reader"` |  |
| openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[9].system | bool | `true` |  |
| openchoreo-control-plane.openchoreoApi.config.server.publicUrl | string | `"http://api.openchoreo.localhost:8080"` |  |
| openchoreo-control-plane.openchoreoApi.http.hostnames[0] | string | `"api.openchoreo.localhost"` |  |
| openchoreo-control-plane.openchoreoApi.image.tag | string | `"v1.3.3@sha256:ed0fb79a93c55946a1b38b51fdf34ba9cccec0998a7befbdd62a4e3aae1ef63f"` |  |
| openchoreo-control-plane.security.oidc.authorizationUrl | string | `"http://thunder.openchoreo.localhost:8080/oauth2/authorize"` |  |
| openchoreo-control-plane.security.oidc.issuer | string | `"http://thunder.openchoreo.localhost:8080"` |  |
| openchoreo-control-plane.security.oidc.jwksUrl | string | `"http://thunder.openchoreo.localhost:8080/oauth2/jwks"` |  |
| openchoreo-control-plane.security.oidc.tokenUrl | string | `"http://thunder.openchoreo.localhost:8080/oauth2/token"` |  |
| openchoreo.controlPlane.clusterGatewayURL | string | `"wss://cluster-gateway.openchoreo.localhost:8443/ws"` |  |
| openchoreo.controlPlane.host | string | `"openchoreo.localhost"` | Console/API hostnames (`host`) and agent WebSocket endpoint (`clusterGatewayURL`). |
| openchoreo.observability.enabled | bool | `true` |  |
| scaffolder.githubApp.enabled | bool | `false` |  |
| scaffolder.githubApp.remoteKey | string | `"platform-github-app"` |  |
| scaffolder.githubApp.secretName | string | `"backstage-github-app"` |  |
| scaffolder.githubApp.store | string | `"platform"` |  |

## Day-2 notes

- Control-plane triage and upgrades: [observability first look](../../docs/runbooks/observability-first-look.md) and [upgrades](../../docs/runbooks/upgrades.md#4-openchoreo-and-thunder).
- Console cost views follow the FinOps module (#207): `costViews.enabled` comes from the mgmt label `addons.platform.koorikla.io/finops-opencost`; while false, ConfigMap `backstage-cost-views` (Backstage's last config file) switches off Cost Insights and Cost Analysis. It repeats the image's `app.extensions` (`appExtensions`): re-check that list on an openchoreo-ui bump.
- Values are checked before rendering: `values.schema.json` (hosts, `wss://` gateway URL, stores, required keys) and `templates/validate.yaml` (cross-field: subchart hostnames, gateway port and TLS SANs match `installation.yaml`, GitHub App wiring). A schema error names the failing key path.

## Links

- [OpenChoreo](../../docs/openchoreo.md)
- [Golden-path project templates](../../docs/project-templates.md)