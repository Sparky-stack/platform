# argo-cd

## Purpose

Wrapper chart for `argo-cd` (`10.18.0` / `v3.6.1`) on the management cluster. Adopts the bootstrap `argocd` Helm release and reconciles `Application/root`, `ApplicationSet`s, and every workload cluster in push mode.

## Where it runs

- **Roles / providers:** `roles: [mgmt]`, all providers (`namespace: argocd`, `releaseName: argocd`).
- **Catalog label:** `addons.platform.koorikla.io/argo-cd` (`default: true`, opt-out with `"false"`).

## Key values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| argo-cd.applicationSet.enabled | bool | `true` |  |
| argo-cd.applicationSet.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.applicationSet.resources.requests.cpu | string | `"25m"` |  |
| argo-cd.applicationSet.resources.requests.memory | string | `"64Mi"` |  |
| argo-cd.commitServer.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.configs.cm."helm.dependencies.enabled" | string | `"true"` | `"true"` so `repo-server` builds HTTPS and OCI wrapper dependencies (`ARGOCD_EXEC_TIMEOUT=180s`). |
| argo-cd.configs.cm."resource.customizations.health.PersistentVolumeClaim" | string | `"hs = {}\nif obj.status ~= nil and obj.status.phase ~= nil then\n  if obj.status.phase == \"Bound\" then\n    hs.status = \"Healthy\"\n    hs.message = obj.status.phase\n    return hs\n  end\n  if obj.status.phase == \"Pending\" then\n    hs.status = \"Healthy\"\n    hs.message = \"Waiting for first consumer (WaitForFirstConsumer)\"\n    return hs\n  end\nend\nhs.status = \"Progressing\"\nreturn hs\n"` | Treats `Pending` `WaitForFirstConsumer` PVCs as `Healthy` so hook Jobs can bind volumes. |
| argo-cd.configs.cm."resource.customizations.health.addons.cluster.x-k8s.io_ClusterResourceSet" | string | `"hs = {}\nlocal reconciled = false\nif obj.status ~= nil and obj.status.conditions ~= nil then\n  for _, c in ipairs(obj.status.conditions) do\n    if c.type == \"ResourcesApplied\" then\n      if c.status == \"True\" then\n        hs.status = \"Healthy\"\n        hs.message = \"cluster resource set is applied\"\n      elseif c.status == \"False\" then\n        hs.status = \"Degraded\"\n        hs.message = (c.message ~= nil and c.message ~= \"\") and c.message or (c.reason or \"not applied\")\n      else\n        hs.status = \"Progressing\"\n        hs.message = c.message or \"applying\"\n      end\n      return hs\n    end\n    if c.observedGeneration ~= nil and obj.metadata.generation ~= nil\n        and c.observedGeneration >= obj.metadata.generation then\n      reconciled = true\n    end\n  end\nend\nif reconciled then\n  hs.status = \"Healthy\"\n  hs.message = \"No cluster matches the selector: nothing to apply\"\nelse\n  hs.status = \"Progressing\"\n  hs.message = \"Initializing cluster resource set\"\nend\nreturn hs\n"` |  |
| argo-cd.configs.cm."resource.customizations.health.policies.kyverno.io_DeletingPolicy" | string | `"hs = {}\nlocal cs = nil\nif obj.status ~= nil then\n  cs = obj.status.conditionStatus\nend\nif cs ~= nil then\n  if cs.conditions ~= nil then\n    for _, c in ipairs(cs.conditions) do\n      if c.status == \"False\" then\n        hs.status = \"Degraded\"\n        hs.message = c.type .. \": \" .. (c.message or \"\")\n        return hs\n      end\n    end\n  end\n  if cs.ready == false then\n    hs.status = \"Degraded\"\n    hs.message = (cs.message ~= nil and cs.message ~= \"\") and cs.message or \"Policy is not ready\"\n    return hs\n  end\nend\nhs.status = \"Healthy\"\nif obj.status ~= nil and obj.status.lastExecutionTime ~= nil then\n  hs.message = \"Last run \" .. obj.status.lastExecutionTime\nelse\n  hs.message = \"Scheduled, not run yet\"\nend\nreturn hs\n"` |  |
| argo-cd.configs.cm."resource.customizations.health.policies.kyverno.io_NamespacedDeletingPolicy" | string | `"hs = {}\nlocal cs = nil\nif obj.status ~= nil then\n  cs = obj.status.conditionStatus\nend\nif cs ~= nil then\n  if cs.conditions ~= nil then\n    for _, c in ipairs(cs.conditions) do\n      if c.status == \"False\" then\n        hs.status = \"Degraded\"\n        hs.message = c.type .. \": \" .. (c.message or \"\")\n        return hs\n      end\n    end\n  end\n  if cs.ready == false then\n    hs.status = \"Degraded\"\n    hs.message = (cs.message ~= nil and cs.message ~= \"\") and cs.message or \"Policy is not ready\"\n    return hs\n  end\nend\nhs.status = \"Healthy\"\nif obj.status ~= nil and obj.status.lastExecutionTime ~= nil then\n  hs.message = \"Last run \" .. obj.status.lastExecutionTime\nelse\n  hs.message = \"Scheduled, not run yet\"\nend\nreturn hs\n"` |  |
| argo-cd.configs.cm."timeout.reconciliation" | string | `"120s"` | Upstream default 120s. An app whose first comparison fails (a new workload cluster's Argo secret lands before its API serves) is only retried on this period: with 300s+60s jitter dev1's addons idled ~8 min. |
| argo-cd.configs.cm."timeout.reconciliation.jitter" | string | `"30s"` |  |
| argo-cd.configs.params."controller.diff.server.side" | bool | `true` | `true` so CAPI, ESO, cert-manager, and OpenChoreo CRD defaults do not cause permanent diffs. |
| argo-cd.configs.params."controller.operation.processors" | int | `10` |  |
| argo-cd.configs.params."controller.status.processors" | int | `20` | Upstream defaults (20/10): ~45 apps converge at once on a clean bootstrap; 10/5 queued them. |
| argo-cd.configs.params."server.insecure" | bool | `true` |  |
| argo-cd.controller.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` | Argo CD image tag pinned by multi-arch index digest (shared across `controller`, `server`, `repoServer`, `applicationSet`, `dex`, `notifications`). |
| argo-cd.controller.resources.requests.cpu | string | `"100m"` |  |
| argo-cd.controller.resources.requests.memory | string | `"256Mi"` |  |
| argo-cd.dex.enabled | bool | `false` |  |
| argo-cd.dex.initImage.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.fullnameOverride | string | `"argocd"` |  |
| argo-cd.global.domain | string | `"localhost"` |  |
| argo-cd.global.networkPolicy.create | bool | `false` |  |
| argo-cd.notifications.enabled | bool | `false` |  |
| argo-cd.notifications.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.redis.image.tag | string | `"8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"` |  |
| argo-cd.redis.resources.requests.cpu | string | `"25m"` |  |
| argo-cd.redis.resources.requests.memory | string | `"64Mi"` |  |
| argo-cd.redisSecretInit.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.repoServer.env[0].name | string | `"ARGOCD_EXEC_TIMEOUT"` |  |
| argo-cd.repoServer.env[0].value | string | `"180s"` |  |
| argo-cd.repoServer.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.repoServer.resources.requests.cpu | string | `"50m"` |  |
| argo-cd.repoServer.resources.requests.memory | string | `"256Mi"` |  |
| argo-cd.server.image.tag | string | `"v3.6.1@sha256:296e3d74f449b2ce45265613fcb68c18ed7366488360c8ea32f5f2a93d2e5c54"` |  |
| argo-cd.server.resources.requests.cpu | string | `"50m"` |  |
| argo-cd.server.resources.requests.memory | string | `"128Mi"` |  |
| argo-cd.server.service.type | string | `"ClusterIP"` |  |

## Day-2 notes

- Stuck or `OutOfSync` applications: [incidents](../../docs/runbooks/incidents.md#argo-app-stuck-or-outofsync).
- Emergency controller freeze (`selfHeal` pause): [break-glass](../../docs/runbooks/break-glass.md#freezing-argo-cd-self-heal) and [upgrades](../../docs/runbooks/upgrades.md).

## Links

- [Architecture](../../docs/architecture.md)
- [Supply chain](../../docs/supply-chain.md)