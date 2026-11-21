# Spike: argocd-agent managed mode (#20)

Throwaway evidence for the go/no-go on issue #20; findings, measurements and the recommendation are in the
[issue comment](https://github.com/koorikla/platform/issues/20). Nothing here is wired into `task`, CI or the platform.

`run.sh` makes two k3d clusters on their own Docker network (`spike-principal`, `spike-agent`), never touching
`k3d-platform-mgmt` or the CAPD clusters:

| Cluster | Runs |
|---|---|
| `spike-principal` (hub, stands in for mgmt) | full Argo CD v3.6.1 (same pin as addons/argo-cd) + argocd-agent principal v0.11.0 alongside ("hybrid architecture") |
| `spike-agent` (spoke, stands in for dev1) | Argo CD v3.6.1 application-controller, repo-server, redis + argocd-agent agent v0.11.0, managed mode |

```sh
mise exec -- bash hack/spikes/argocd-agent/run.sh up       # ~3 min
mise exec -- bash hack/spikes/argocd-agent/run.sh addons   # ~5 min: real ApplicationSets from charts/platform
mise exec -- bash hack/spikes/argocd-agent/run.sh down
```

`addons` renders `charts/platform` for `installations/local`, keeps five real addon ApplicationSets
(gateway-api-crds, cert-manager, priority-classes, reloader, keda) and changes only what the agent needs:
`destination.name: '{{ .name }}'` instead of `destination.server`, plus the principal's label selector
(`argocd-agent: "true"`) on the generated Applications and the `platform` AppProject. The agent's cluster secret gets
dev1-like `platform.koorikla.io/*` labels, so the unchanged cluster generator selects it.

The script applies upstream's install manifests with `kubectl -k` only because the clusters are throwaway; no
Kustomize lands in this repo, and a real rollout would ship as Helm wrapper addons (migration outline in #20).

Pitfalls the script works around (v0.11.0):
- Argo CD's `argocd-redis` NetworkPolicy must admit the principal, or hub Application status silently stops updating.
- The principal's NetworkPolicy admits agents only from pods in the same cluster; remote agents get `connection refused`.
- Upstream kustomize for the spoke pulls Argo CD `ref=stable`; the script pins it to v3.6.1.
- The docs' `argocd-agentctl agent create --resource-proxy-username/--resource-proxy-password` flags no longer exist.
- Live resources, logs and resource actions go through the agent's ServiceAccount, which by default can read only Argo
  CD's own kinds (`PermissionDenied` in the UI): `proxy-rbac.yaml`.
- Applications reach a new spoke with the hub's last status (Synced/Healthy) until its controller reconciles: judge
  convergence by the workloads, not by the Application status.
- `argocd-agentctl pki` is marked NON-PROD; production PKI would be a cert-manager Issuer backed by OpenBao.
