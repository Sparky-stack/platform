# Runbook: Certificates and secrets rotation

<img src="../diagrams/trust.svg" alt="Trust and certificates: per-cluster agent CAs from cert-manager, the OpenBao mesh CA, delivery and rotation" width="100%">

## When to use

Use this runbook to inspect certificate expiry, rotate cert-manager CAs or leaf certificates, manage the OpenBao Istio mesh CA, rotate OpenChoreo data-plane agent certificates, update GitHub App keys or PATs, rotate the `cosign-platform` build signing key, or refresh External Secrets Operator (ESO) secrets ([conventions.md](../conventions.md#secret-keys)).

## Symptoms

- `Certificate` or `ExternalSecret` shows `READY=False` (`SecretSyncedError`, `Issuing`, or expired `notAfter`).
- `cluster-agent-dataplane` logs TLS handshake failures after `<cluster>-agent-tls` or `cluster-gateway-ca` renewed.
- Argo CD fails repository fetches (`platform-repo-creds`), in-cluster builds fail at checkout with `no GitHub token for <repo>` or `promotion-gate` fails GitHub App token minting (both `promotion-gate-github`: App key, permissions, or the App not installed on the repository; `kubectl -n external-secrets logs deploy/external-secrets | grep <run>-git`).
- Workload mesh pods or `cert-manager-istio-csr` fail to sign SPIFFE certificates against `Issuer/openbao-mesh`.
- Falco Critical escalations return `401 Unauthorized` at `argo-events` after `falco-webhook` changed.

## Steps

### 1. cert-manager CAs and leaf certificates

CA private keys stay in their owning namespace on `k3d-platform-mgmt` (Invariant 4); only `ca.crt` crosses namespaces via name-scoped ESO stores (`mgmt-harbor`, `mgmt-openbao`, `mgmt-openchoreo`).

```bash
# Check every cert-manager Certificate and renewal time on mgmt and a workload cluster
kubectl --context k3d-platform-mgmt get certificate -A \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,RENEWAL:.status.renewalTime,EXPIRY:.status.notAfter
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig get certificate -A
```

- **Rotate a leaf certificate immediately** (for example `harbor/harbor-tls`, `openbao/openbao-tls`, `openchoreo-control-plane/cluster-gateway-tls`, or `fleet/dev1-mesh-reader`): delete the target `Secret`; cert-manager re-issues it within seconds (`openbao` reloads TLS automatically via `tls_auto_reload`).
  ```bash
  kubectl --context k3d-platform-mgmt -n openbao delete secret openbao-tls
  kubectl --context k3d-platform-mgmt -n openbao wait --for=condition=Ready certificate/openbao-tls --timeout=60s
  ```
- **Rotate a namespaced CA** (`harbor-ca`, `openbao-ca`, `cluster-gateway-ca`) `(not yet verified live)`: deleting the CA `Secret` mints a new CA and requires deleting its leaf `Secret`s plus forcing ESO refresh on the `*-ca-bundle` `ExternalSecret`s. Rotating `harbor-ca` also changes `/etc/rancher/k3s/registry-ca.crt` in `fleet/<cluster>-registries`, which reaches workload nodes only when CAPI rolls their `Machine`s.

### 2. OpenBao mesh CA (`openbao` + `mesh`)

- **Automatic leaf renewals**: `ztunnel` renews `24h` workload certs at half-life (~`12h`), and `cert-manager` renews `istio-system/istiod` (`48h` TTL) at `24h` through Vault `Issuer/openbao-mesh` ([multicluster.md](../multicluster.md#mesh-ca-openbao)).
- **Cut off a compromised mesh member immediately**: remove `mesh.group` from `installations/<inst>/clusters/<name>.yaml` and merge. Within 5 minutes `CronJob/mesh-reconcile` deletes `auth/mesh-<name>` and entity `mesh-<name>` in OpenBao, blocking new certificates; then delete leftover peer discovery secrets ([multicluster.md](../multicluster.md#removing-a-member-decommissioning)):
  ```bash
  # On each remaining mesh member, remove the decommissioned peer's remote secret
  task kubeconfig CLUSTER=prod1
  kubectl --kubeconfig prod1.kubeconfig -n istio-system delete secret istio-remote-secret-<gone> --ignore-not-found
  # On mgmt, remove the leftover reader cert Secret
  kubectl --context k3d-platform-mgmt -n fleet delete secret <gone>-mesh-reader --ignore-not-found
  ```
- **Root (`10y`) and intermediate (`5y`) rotation** `(not yet verified live)`: generate the new root alongside the active root inside OpenBao, publish both in `openbao-ca-bundle` / `mesh-root-ca`, issue a new intermediate under the new root, then retire the old root once old leaves expire ([#71](https://github.com/koorikla/platform/issues/71), [multicluster.md](../multicluster.md#root-and-intermediate-rotation)).

### 3. OpenChoreo agent certificates

Each workload cluster has its own `10y` CA (`fleet/<cluster>-agent-ca`) signing `fleet/<cluster>-agent-tls` (`1y`, renewed `30d` before expiry), delivered via ESO (`mgmt-fleet`) and `ClusterResourceSet/<cluster>-openchoreo-agent` into `openchoreo-data-plane/cluster-agent-tls` ([openchoreo.md](../openchoreo.md#trust-model)).

OpenChoreo `1.3.3` agents read their TLS files only at startup ([#50](https://github.com/koorikla/platform/issues/50)). After an automatic renewal or manual rotation:

```bash
# 1. Optional: force immediate rotation of dev1's client certificate on mgmt
kubectl --context k3d-platform-mgmt -n fleet delete secret dev1-agent-tls
kubectl --context k3d-platform-mgmt -n fleet wait --for=condition=Ready certificate/dev1-agent-tls --timeout=60s
kubectl --context k3d-platform-mgmt -n fleet annotate externalsecret dev1-openchoreo-agent \
  force-sync="$(date +%s)" --overwrite

# 2. Restart the data-plane agent once ClusterResourceSet updates cluster-agent-tls
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig -n openchoreo-data-plane rollout restart deploy/cluster-agent-dataplane
kubectl --kubeconfig dev1.kubeconfig -n openchoreo-data-plane rollout status deploy/cluster-agent-dataplane --timeout=120s
```

If `openchoreo-control-plane/cluster-gateway-ca` rotates, also force-sync `openchoreo-gateway-ca` (`fleet`) and `cluster-gateway-ca` (`openchoreo-observability-plane`, `openchoreo-workflow-plane`), then restart `deploy/cluster-agent-observabilityplane`, `deploy/cluster-agent-workflowplane`, and every workload `deploy/cluster-agent-dataplane`.

### 4. GitHub App keys and registry PATs

Credentials live in `ClusterSecretStore/platform` keys `platform-github`, `platform-github-app`, `promotion-gate-github`, and `platform-ghcr` ([forking.md](../forking.md#3-credentials), [project-templates.md](../project-templates.md#repository-creation)).

```bash
# Local backend (`secrets.backend: kubernetes`): set new env vars (key stays in a 0600 file, never printed) and re-seed
export GITHUB_APP_ID=<app-id>
export GITHUB_APP_INSTALLATION_ID=<installation-id>
export GITHUB_APP_PRIVATE_KEY_FILE="$HOME/.keys/platform-argocd.pem"
task secrets

# Force ESO to update Argo CD's repository credentials immediately
kubectl --context k3d-platform-mgmt -n argocd annotate externalsecret platform-repo-creds \
  force-sync="$(date +%s)" --overwrite
kubectl --context k3d-platform-mgmt -n argocd get externalsecret platform-repo-creds
```

- **`promotion-gate-github`**: the gate reads it per `WorkflowRun`; builds mint tokens through ExternalSecret `workflows-default/build-github-app` (refresh 1h; force-sync it to use a rotated key at once).
- **`platform-ghcr`**: force-sync `harbor/harbor-platform` (and run a Job from `CronJob/harbor-config`) so Harbor proxy-cache/replication picks it up; workload nodes only pick up rotated `fleet/<cluster>-registries` credentials when replaced.

### 5. `cosign-platform` signing key

In-cluster workflow builds sign images with `cosign-platform` (`cosign.key`, `cosign.pub`, `cosign.password`; [supply-chain.md](../supply-chain.md#wiring-the-key)).

```bash
# 1. Local backend: delete cosign-platform so `task secrets` generates a fresh encrypted keypair (not yet verified live)
kubectl --context k3d-platform-mgmt -n platform-secrets delete secret cosign-platform
task secrets

# 2. Export ONLY the public key (cosign.pub is non-secret) for kyverno-policies
kubectl --context k3d-platform-mgmt -n platform-secrets get secret cosign-platform \
  -o jsonpath='{.data.cosign\.pub}' | base64 -d
```

Update `imageVerification.platformKey.publicKey` in `installations/<inst>/addons/kyverno-policies/values.yaml` via PR **before** promoting builds signed with the new key to `production`.

### 6. ESO-backed platform and workload secrets

 ESO refreshes `ExternalSecret`s every `1h` by default. Force an immediate pull after updating a backend secret, then restart consumers that read secrets only at process start:

```bash
K="kubectl --context k3d-platform-mgmt"

# Example: rotate falco-webhook token (rotates all per-cluster sha256("<cluster>:<token>") tokens; observability.md)
$K -n argo-events annotate externalsecret falco-webhook force-sync="$(date +%s)" --overwrite
$K -n falco annotate externalsecret falcosidekick-escalation force-sync="$(date +%s)" --overwrite
for c in dev1 prod1; do
  $K -n fleet annotate externalsecret "${c}-falco-escalation" force-sync="$(date +%s)" --overwrite
done

# Restart falcosidekick on mgmt and each workload cluster so it reloads the rotated token
$K -n falco rollout restart deploy/falco-falcosidekick
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig -n falco rollout restart deploy/falco-falcosidekick
```

- **`openchoreo` / `promotion-gate`**: trigger a `thunder-mgmt` sync (runs `thunder-setup` to upsert OAuth client secrets) and restart `deploy/backstage` + `deploy/openchoreo-api` in `openchoreo-control-plane`.
- **`openchoreo-observability`**: on the local backend, `charts/cluster` seeds `openchoreo-secrets` on each workload cluster (`secrets.workloadSeed`); sync `cluster-<name>`, force-sync `ExternalSecret`s in `openchoreo-observability-plane` and `telemetry`, and restart `fluent-bit` / `events-collector` / `observer`.
- **`harbor`**: force-sync `harbor/harbor-platform` and trigger a Job from `CronJob/harbor-config` (`kubectl --context k3d-platform-mgmt -n harbor create job --from=cronjob/harbor-config harbor-config-manual`) to update `robot$builder` and `robot$nodes`. Do **not** rotate `secret-key` on a populated Harbor DB without Harbor's upstream key-migration step.
- **`external-dns-cloudflare`**: delivered via `ClusterSecretStore/dns` ([dns.md](../dns.md#credentials)); force-sync the `ExternalSecret` in `external-dns` and restart `deploy/external-dns` `(not yet verified live)`.

## Verify

```bash
# 1. Every Certificate and ExternalSecret on mgmt is Ready=True
kubectl --context k3d-platform-mgmt get certificate,externalsecret -A

# 2. Every Certificate and ExternalSecret on dev1 is Ready=True
task kubeconfig CLUSTER=dev1
kubectl --kubeconfig dev1.kubeconfig get certificate,issuer,externalsecret -A

# 3. OpenChoreo ClusterDataPlanes remain connected
kubectl --context k3d-platform-mgmt get clusterdataplanes
```

## Rollback

- **Rotated secret broke authentication**: restore the previous secret value in the secret backend (or `git revert` the `publicKey` / `mesh.group` commit), re-run the `force-sync` annotation on the affected `ExternalSecret`s, and restart the consumer `Deployment`/`DaemonSet`.
- **Accidental leaf `Secret` deletion while issuer is unhealthy** (for example OpenBao sealed): see [incidents.md](incidents.md#openbao-sealed) to unseal the issuer first; cert-manager retries issuance automatically once the `Issuer` returns to `Ready=True`.

## Related links

- [Operations handbook](../operations.md)
- [Secret keys contract](../conventions.md#secret-keys)
- [OpenChoreo trust model](../openchoreo.md#trust-model)
- [Mesh CA (OpenBao)](../multicluster.md#mesh-ca-openbao)
- [Fork and credential seeding](../forking.md#3-credentials)
- [Wiring the cosign key](../supply-chain.md#wiring-the-key)
- [Falco escalation tokens](../observability.md#falco-response)
- [DNS credentials](../dns.md#credentials)
- [Incidents](incidents.md)
