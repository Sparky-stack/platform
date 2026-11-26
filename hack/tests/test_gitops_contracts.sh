#!/usr/bin/env bash
# Cross-chart contract tests: label agreement, catalog contracts, AppProjects, and bootstrap/GitOps alignment. Each
# chart renders fine alone; these catch two charts disagreeing on a name. Mesh contracts: test_mesh_contracts.sh.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

helm template platform "$ROOT/charts/platform" --namespace argocd \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/platform.yaml"
PV="$ROOT/charts/platform/values.yaml"

# 1. mgmt cluster secret carries all selection labels + addons-revision annotation
for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation; do
  mgmt_v=$(yq "select(.kind == \"Secret\" and .metadata.name == \"in-cluster\") | .metadata.labels[\"$key\"]" "$TMP/platform.yaml")
  assert_nonempty "$mgmt_v" "in-cluster carries $key"
done
mgmt_rev=$(yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.annotations["platform.koorikla.io/addons-revision"]' "$TMP/platform.yaml")
assert_eq "$mgmt_rev" "HEAD" "in-cluster addons-revision defaults to HEAD"

# 2. the workload cluster secret (Argo CD) carries the same labels as its CAPI Cluster
helm template cluster-dev1 "$ROOT/charts/cluster" --namespace fleet \
  --values "$ROOT/installations/local/installation.yaml" \
  --values "$ROOT/installations/local/clusters/dev1.yaml" > "$TMP/dev1.yaml"
for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation platform.koorikla.io/cni addons.platform.koorikla.io/cilium mesh.platform.koorikla.io/group mesh.platform.koorikla.io/network; do
  capi_v=$(yq "select(.kind == \"Cluster\" and .metadata.name == \"dev1\") | .metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
  wl_v=$(yq "select(.kind == \"ExternalSecret\" and .metadata.name == \"dev1-argocd-cluster\") | .spec.target.template.metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
  assert_eq "$wl_v" "$capi_v" "dev1 argocd cluster label $key matches CAPI Cluster"
done

# 2b. networking: the cilium addon follows the cluster's cni and reaches the API server via the cluster secret's server
dev1_cni=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["platform.koorikla.io/cni"]' "$TMP/dev1.yaml")
dev1_cil=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["addons.platform.koorikla.io/cilium"]' "$TMP/dev1.yaml")
assert_eq "$dev1_cil" "$([[ "$dev1_cni" == cilium ]] && echo true || echo false)" "dev1 cilium addon label follows cni ($dev1_cni)"
cil_params=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cilium") | .spec.template.spec.source.helm.parameters[] | .name + "=" + .value' "$TMP/platform.yaml")
assert_match "$cil_params" 'cilium.k8sServiceHost=\{\{ \(urlParse \.server\)\.hostname \}\}' "addon-cilium sets k8sServiceHost from the cluster server"
assert_match "$cil_params" 'cilium.k8sServicePort=.*urlParse \.server' "addon-cilium sets k8sServicePort from the cluster server"
cil_sel=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cilium") | .spec.generators[0].clusters.selector.matchExpressions[] | select(.key == "addons.platform.koorikla.io/cilium") | .operator' "$TMP/platform.yaml")
assert_eq "$cil_sel" "In" "addon-cilium is opt-in by label"
mgmt_cni=$(yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.labels["platform.koorikla.io/cni"]' "$TMP/platform.yaml")
assert_eq "$mgmt_cni" "flannel" "in-cluster (k3d mgmt) carries platform.koorikla.io/cni=flannel"

# 2c. Kyverno: the platform namespaces outside Kyverno's webhooks are exactly the ones the policies exclude
kyv_ns=$(yq -o=json -I=0 '.kyverno.config.webhooks.namespaceSelector.matchExpressions[0].values' "$ROOT/addons/kyverno/values.yaml")
kp_ns=$(yq -o=json -I=0 '.platformNamespaces' "$ROOT/addons/kyverno-policies/values.yaml")
assert_eq "$kp_ns" "$kyv_ns" "kyverno webhook exclusions == kyverno-policies platformNamespaces"
for ns in $(yq '.addons[].namespace' "$ROOT/charts/platform/values.yaml" | sort -u); do
  case "$ns" in
    default) continue ;;       # OpenChoreo org namespace on mgmt (CRs only), deliberately in scope
    argo-events) continue ;;   # externally reachable webhook receiver: deliberately in scope (PSS, Kyverno reports)
    harbor) continue ;;        # Harbor meets PSS baseline: policed like a workload (check 9)
    openbao) continue ;;       # mesh CA: restricted pod security, policed like a workload (check 2b4)
    external-dns) continue ;;  # external-dns meets PSS restricted: policed like a workload (check 9b)
    reloader) continue ;;      # reloader meets PSS restricted: policed like a workload (check 9c)
    keda|strimzi|cnpg-system|moco-system) continue ;;   # opt-in data-service operators meet PSS restricted: policed (test_data_services.sh, addons/moco tests)
    crossplane-system) continue ;;          # Crossplane core, Functions, providers meet PSS restricted: policed (test_crossplane_render.sh)
    dex) continue ;;                        # Dex OIDC broker meets PSS restricted: policed like a workload (check 9e)
  esac
  assert_match "$kp_ns" "\"$ns\"" "catalog namespace $ns is a Kyverno-excluded platform namespace"
done

# 3. argo-cd ApplicationSet uses releaseName argo-cd and fullnameOverride argocd (matching bootstrap/bootstrap.sh)
argo_rel=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-argo-cd") | .spec.template.spec.source.helm.releaseName' "$TMP/platform.yaml")
assert_eq "$argo_rel" "argocd" "addon-argo-cd releaseName is argocd (= bootstrap helm release)"
argo_fn=$(yq '.argo-cd.fullnameOverride' "$ROOT/addons/argo-cd/values.yaml")
assert_eq "$argo_fn" "argocd" "addons/argo-cd fullnameOverride is argocd (matches bootstrap release)"

# 4. fleet ApplicationSet targets project fleet, charts/cluster, and uses ServerSideDiff=true
fleet_proj=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.project' "$TMP/platform.yaml")
fleet_path=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.source.path' "$TMP/platform.yaml")
fleet_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "fleet") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$fleet_proj" "fleet" "fleet appset uses project fleet"
assert_eq "$fleet_path" "charts/cluster" "fleet appset uses charts/cluster"
assert_eq "$fleet_ssd" "ServerSideDiff=true" "fleet appset enables ServerSideDiff"

# 5. Catalog alignment checks
odp_param=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-openchoreo-data-plane") | .spec.template.spec.source.helm.parameters[0].name' "$TMP/platform.yaml")
assert_eq "$odp_param" "openchoreo-data-plane.clusterAgent.planeID" "openchoreo-data-plane sets planeID parameter"
cc_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cluster-fleet") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$cc_ssd" "ServerSideDiff=true" "cluster-fleet (ClusterClasses) enables ServerSideDiff"
cf_src=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-cluster-fleet") | .spec.template.spec.source | .path + " " + (.helm.parameters[] | select(.name == "scope") | .value)' "$TMP/platform.yaml")
assert_eq "$cf_src" "charts/cluster fleet" "cluster-fleet renders charts/cluster in scope fleet"
kgw_ns=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-kgateway") | .spec.template.spec.destination.namespace' "$TMP/platform.yaml")
assert_eq "$kgw_ns" "kgateway-system" "kgateway deploys into kgateway-system"
coredns_roles=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-coredns-local") | .spec.generators[0].clusters.selector.matchExpressions[] | select(.key == "platform.koorikla.io/role") | .values | join(",")' "$TMP/platform.yaml")
assert_eq "$coredns_roles" "mgmt,workload" "coredns-local targets mgmt and workload"

# 6. argo-cd PVC health Lua treats Pending as Healthy and server stays ClusterIP
helm template argo-cd "$ROOT/addons/argo-cd" --namespace argocd > "$TMP/argocd.yaml"
pvc_lua=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-cm") | .data["resource.customizations.health.PersistentVolumeClaim"]' "$TMP/argocd.yaml")
assert_match "$pvc_lua" 'Pending' "argocd-cm PVC health customization handles Pending"
svc_type=$(yq 'select(.kind == "Service" and .metadata.name == "argocd-server") | .spec.type' "$TMP/argocd.yaml")
assert_eq "$svc_type" "ClusterIP" "argocd-server Service stays ClusterIP"

# 7. secret-stores creates platform, workflows, mgmt-fleet, mgmt-openchoreo on mgmt and default on workload
helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets \
  --values "$ROOT/addons/secret-stores/values/role-mgmt.yaml" > "$TMP/ss-mgmt.yaml"
for s in platform workflows mgmt-fleet mgmt-openchoreo; do
  found=$(yq "select(.kind == \"ClusterSecretStore\" and .metadata.name == \"$s\") | .metadata.name" "$TMP/ss-mgmt.yaml")
  assert_eq "$found" "$s" "mgmt secret-stores creates ClusterSecretStore $s"
done
helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets \
  --values "$ROOT/addons/secret-stores/values/role-workload.yaml" > "$TMP/ss-wl.yaml"
wl_store=$(yq 'select(.kind == "ClusterSecretStore" and .metadata.name == "default") | .metadata.name' "$TMP/ss-wl.yaml")
assert_eq "$wl_store" "default" "workload secret-stores creates ClusterSecretStore default"

# ClusterClass patches: CAPI's webhook rejects replace/remove ops on array elements (".../files/0/content"); the
# offline simulator does not, so guard it here for every installation's classes.
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  idx_paths=$(helm template cc "$ROOT/charts/cluster" --values "$inst_file" --set scope=fleet 2>/dev/null \
    | yq 'select(.kind == "ClusterClass") | .spec.patches[].definitions[].jsonPatches[] | select(.op == "replace" or .op == "remove") | .path' \
    | grep -E '/[0-9]+(/|$)' || true)
  assert_eq "$idx_paths" "" "ClusterClass replace/remove patches avoid array indices ($(basename "$(dirname "$inst_file")"))"
done

# Tenant projects: the VAP openchoreo-gated-bindings-from-git accepts a gated Application <project>-<app>-<env> for
# bindings of <project>, so no project may be "<other project>-..." (its apps would look like the other's).
for tdir in "$ROOT"/installations/*/tenants; do
  [[ -d "$tdir" ]] || continue
  projects=$(for f in "$tdir"/*.yaml; do [[ -f "$f" ]] && yq '.project' "$f"; done)
  clash=""
  for a in $projects; do for b in $projects; do
    [[ "$a" != "$b" && "$b" == "$a-"* ]] && clash="$clash $b (prefix $a-)"
  done; done
  assert_eq "$clash" "" "tenant projects are not '<other project>-' prefixed ($(basename "$(dirname "$tdir")"))"
done
# ... and every Application name <project>-<app>[-<gated env>] is unique across an installation's tenant files: names
# are joined with dashes, so a-b/c and a/b-c (or one project in two files) give the same name. The VAP identifies the
# gated Application of a component by that name alone (and Argo CD would merge two such Applications into one).
tenant_app_dups() {   # tenant_app_dups <installation.yaml> <tenant file>... -> duplicated Application names
  local inst=$1 f
  shift
  for f in "$@"; do
    helm template t "$ROOT/charts/tenant" --values "$inst" --values "$f" -s templates/applications.yaml \
      | yq -N 'select(.kind == "Application") | .metadata.name'
  done | tr -d '\r' | sort | uniq -d
}
for tdir in "$ROOT"/installations/*/tenants; do
  [[ -d "$tdir" ]] || continue
  tfiles=()
  for f in "$tdir"/*.yaml; do [[ -f "$f" ]] && tfiles+=("$f"); done
  [[ ${#tfiles[@]} -gt 0 ]] || continue
  inst_name=$(basename "$(dirname "$tdir")")
  assert_eq "$(tenant_app_dups "$(dirname "$tdir")/installation.yaml" "${tfiles[@]}")" "" \
    "tenant Application names <project>-<app>[-<env>] are unique across tenant files ($inst_name)"
done
mkdir -p "$TMP/tenants-clash"
printf 'project: a\napps: [{name: b-c, repoURL: https://example.com/x.git}]\n' > "$TMP/tenants-clash/a.yaml"
printf 'project: a-b\napps: [{name: c, repoURL: https://example.com/y.git}]\n' > "$TMP/tenants-clash/a-b.yaml"
dups=$(tenant_app_dups "$ROOT/installations/local/installation.yaml" "$TMP/tenants-clash/a.yaml" "$TMP/tenants-clash/a-b.yaml")
assert_eq "$dups" "$(printf 'a-b-c\na-b-c-production')" "negative: a/b-c and a-b/c collide (main and gated Application)"
# 8. Local Harbor: bootstrap/k3d-mgmt.yaml publishes the registry.host port on the load balancer (loopback), else
#    host docker login and CAPD node pulls through the serverlb fail. Negative check: a k3d file without it is caught.
k3d_publishes() {   # k3d_publishes <k3d file> <port> -> yes|no
  local p
  p=$(PORT=$2 yq '[.ports[] | select((.port | test(":" + strenv(PORT) + ":" + strenv(PORT) + "$")) and (.nodeFilters[] == "loadbalancer"))] | length' "$1")
  [[ "$p" -ge 1 ]] && echo yes || echo no
}
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  [[ "$(yq '.registry.type // ""' "$inst_file")" == harbor ]] || continue
  [[ "$(yq '.mgmt.provider // "docker"' "$inst_file")" == docker ]] || continue
  host=$(yq '.registry.host' "$inst_file")
  port=443; [[ "$host" == *:* ]] && port=${host##*:}
  assert_eq "$(k3d_publishes "$ROOT/bootstrap/k3d-mgmt.yaml" "$port")" yes \
    "bootstrap/k3d-mgmt.yaml publishes registry port $port on the load balancer ($(basename "$(dirname "$inst_file")"))"
  assert_match "$(yq ".ports[] | select(.port | test(\":$port:$port\$\")) | .port" "$ROOT/bootstrap/k3d-mgmt.yaml")" '^127\.0\.0\.1:' \
    "registry port $port bound to loopback only"
done
yq 'del(.ports[] | select(.port | test(":9443:9443$")))' "$ROOT/bootstrap/k3d-mgmt.yaml" > "$TMP/k3d-noharbor.yaml"
assert_eq "$(k3d_publishes "$TMP/k3d-noharbor.yaml" 9443)" no "contract catches a k3d config without the registry port"

# 8b. Leader election: the k3d mgmt k3s gets the CAPD ClusterClass values (k3s.dockerLeaderElectionArgs) for every
#     embedded controller, or a slow etcd fsync restarts mgmt k3s ("leaderelection lost", #82). Negative check below.
k3d_le_missing() {   # k3d_le_missing <k3d file> -> the --kube-<component>-arg=<value> flags it lacks
  local comp v miss=""
  for comp in kube-controller-manager kube-scheduler kube-cloud-controller-manager; do
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      FLAG="--$comp-arg=$v" yq -e '[.options.k3s.extraArgs[] | select(.arg == strenv(FLAG))] | length > 0' "$1" >/dev/null 2>&1 \
        || miss="$miss --$comp-arg=$v"
    done < <(yq '.k3s.dockerLeaderElectionArgs[]' "$ROOT/charts/cluster/values.yaml")
  done
  printf '%s' "$miss"
}
assert_eq "$(yq '.k3s.dockerLeaderElectionArgs | length' "$ROOT/charts/cluster/values.yaml")" 3 \
  "charts/cluster k3s.dockerLeaderElectionArgs sets lease duration, renew deadline and retry period"
assert_eq "$(k3d_le_missing "$ROOT/bootstrap/k3d-mgmt.yaml")" "" "bootstrap/k3d-mgmt.yaml passes the CAPD leader election to every embedded controller"
yq 'del(.options.k3s.extraArgs[] | select(.arg == "--kube-scheduler-arg=*"))' "$ROOT/bootstrap/k3d-mgmt.yaml" > "$TMP/k3d-nole.yaml"
assert_match "$(k3d_le_missing "$TMP/k3d-nole.yaml")" "kube-scheduler-arg=leader-elect-lease-duration" "contract catches a k3d config without the scheduler leader election"

# 8c. etcd stalls (#344): k3s's own wrangler leases ("k3s", "k3s-etcd": 45 s / 30 s upstream) ignore the args above and a
#     29-31 s fsync-bound stall killed mgmt k3s. The mgmt etcd skips fsync and k3s's leases tolerate 90 s.
k3d_stall_missing() {   # k3d_stall_missing <k3d file> -> the stall guards it lacks
  local miss="" kv
  yq -e '[.options.k3s.extraArgs[] | select(.arg == "--etcd-arg=unsafe-no-fsync=true" and (.nodeFilters[] == "server:0"))] | length > 0' \
    "$1" >/dev/null 2>&1 || miss="$miss unsafe-no-fsync"
  for kv in CATTLE_ELECTION_LEASE_DURATION=120s CATTLE_ELECTION_RENEW_DEADLINE=90s CATTLE_ELECTION_RETRY_PERIOD=10s; do
    KV="$kv" yq -e '[.env[] | select(.envVar == strenv(KV) and (.nodeFilters[] == "server:*"))] | length > 0' "$1" >/dev/null 2>&1 \
      || miss="$miss ${kv%%=*}"
  done
  printf '%s' "$miss"
}
assert_eq "$(k3d_stall_missing "$ROOT/bootstrap/k3d-mgmt.yaml")" "" "bootstrap/k3d-mgmt.yaml guards mgmt k3s against etcd stalls (no fsync, long k3s leases)"
yq 'del(.env)' "$ROOT/bootstrap/k3d-mgmt.yaml" > "$TMP/k3d-noenv.yaml"
assert_match "$(k3d_stall_missing "$TMP/k3d-noenv.yaml")" "CATTLE_ELECTION_RENEW_DEADLINE" "contract catches a k3d config with upstream k3s leases"
yq 'del(.options.k3s.extraArgs[] | select(.arg == "--etcd-arg=*"))' "$ROOT/bootstrap/k3d-mgmt.yaml" > "$TMP/k3d-fsync.yaml"
assert_match "$(k3d_stall_missing "$TMP/k3d-fsync.yaml")" "unsafe-no-fsync" "contract catches a k3d config with fsync in the mgmt etcd"

# 9b. external-dns is NOT a Kyverno-excluded platform namespace either: the chart defaults meet Pod Security restricted.
assert_kyverno_not_excluded external-dns
helm template external-dns "$ROOT/addons/external-dns" --namespace external-dns -f "$ROOT/addons/external-dns/values/role-workload.yaml" \
  -f "$ROOT/addons/external-dns/values/dns-route53.yaml" --set dns.provider=route53 --set 'dns.domainFilters={a.example.com}' \
  --set 'external-dns.domainFilters={a.example.com}' --set-string external-dns.txtOwnerId=sample > "$TMP/edns-pss.yaml"
edns_pod='select(.kind == "Deployment") | .spec.template.spec'
assert_eq "$(yq "$edns_pod | .securityContext.runAsNonRoot" "$TMP/edns-pss.yaml")" true "external-dns pod runAsNonRoot"
assert_eq "$(yq "$edns_pod | .securityContext.seccompProfile.type // .containers[0].securityContext.seccompProfile.type" "$TMP/edns-pss.yaml")" RuntimeDefault "external-dns seccomp RuntimeDefault"
assert_eq "$(yq "$edns_pod | .containers[0].securityContext.allowPrivilegeEscalation" "$TMP/edns-pss.yaml")" false "external-dns no privilege escalation"
assert_eq "$(yq -o=json -I=0 "$edns_pod | .containers[0].securityContext.capabilities.drop" "$TMP/edns-pss.yaml")" '["ALL"]' "external-dns drops ALL capabilities"

# 9c. reloader (#50) is NOT a Kyverno-excluded platform namespace, meets Pod Security restricted, may roll workloads in
#     openchoreo-data-plane (and tenant cells, #268: cluster-wide watch fenced by VAP reloader-rollout-only, CEL in
#     test_reloader_admission.sh), and cluster-agent's Reloader annotations match the CRS-delivered Secret/ConfigMap.
assert_kyverno_not_excluded reloader
rel_ns=$(yq '.addons.reloader.namespace' "$PV")
dp_ns=$(yq '.addons["openchoreo-data-plane"].namespace' "$PV")
helm template reloader "$ROOT/addons/reloader" --namespace "$rel_ns" > "$TMP/reloader-pss.yaml"
rel_pod='select(.kind == "Deployment") | .spec.template.spec'
assert_eq "$(yq "$rel_pod | .securityContext.runAsNonRoot" "$TMP/reloader-pss.yaml")" true "reloader pod runAsNonRoot"
assert_eq "$(yq "$rel_pod | .securityContext.seccompProfile.type" "$TMP/reloader-pss.yaml")" RuntimeDefault "reloader seccomp RuntimeDefault"
assert_eq "$(yq "$rel_pod | .containers[0].securityContext.allowPrivilegeEscalation" "$TMP/reloader-pss.yaml")" false "reloader no privilege escalation"
assert_eq "$(yq "$rel_pod | .containers[0].securityContext.readOnlyRootFilesystem" "$TMP/reloader-pss.yaml")" true "reloader readOnlyRootFilesystem"
assert_eq "$(yq -o=json -I=0 "$rel_pod | .containers[0].securityContext.capabilities.drop" "$TMP/reloader-pss.yaml")" '["ALL"]' "reloader drops ALL capabilities"
assert_eq "$(yq -N 'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.policyName + " " + (.spec.validationActions | join(","))' "$TMP/reloader-pss.yaml")" \
  "reloader-rollout-only Deny" "reloader's cluster-wide RBAC comes with its rollout guard"
assert_match "$(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .spec.validations[0].expression' "$TMP/reloader-pss.yaml")" \
  "request.namespace in \\['$dp_ns'\\]" "reloader may roll workloads in $dp_ns"
helm template openchoreo-control-plane "$ROOT/addons/openchoreo-control-plane" --namespace openchoreo-control-plane \
  -s templates/gateway-ca-crs.yaml > "$TMP/gw-ca-crs.yaml"
# the data plane as its workload ApplicationSet renders it (per-cluster parameters as in test_mesh_contracts.sh)
helm template openchoreo-data-plane "$ROOT/addons/openchoreo-data-plane" --namespace x --set-string cluster.role=workload \
  --set-string mesh.group=contract --set-string cluster.name=dev1 --set-string cilium.k8sServiceHost=dev1.example.test \
  --set-string openchoreo-data-plane.clusterAgent.planeID=dev1 > "$TMP/wl-openchoreo-data-plane.yaml"
crs_secret_name=$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "dev1-openchoreo-agent") | .spec.target.template.data["openchoreo-agent.yaml"]' "$TMP/dev1.yaml" \
  | sed 's/{{.*}}/placeholder/' | yq 'select(.kind == "Secret") | .metadata.name')
crs_cm_name=$(yq 'select(.kind == "ExternalSecret") | .spec.target.template.data["cluster-gateway-ca.yaml"]' "$TMP/gw-ca-crs.yaml" \
  | sed 's/{{.*}}/placeholder/' | yq 'select(.kind == "ConfigMap") | .metadata.name')
dp_reload_targets() {
  yq 'select(.kind == "Deployment" and .metadata.name == "cluster-agent-dataplane") | (.spec.template.metadata.annotations // {})
    | (.["secret.reloader.stakater.com/reload"] // "<none>") + "/" + (.["configmap.reloader.stakater.com/reload"] // "<none>")' "$1"
}
assert_eq "$(dp_reload_targets "$TMP/wl-openchoreo-data-plane.yaml")" "$crs_secret_name/$crs_cm_name" \
  "cluster-agent-dataplane Reloader annotations match CRS Secret ($crs_secret_name) and ConfigMap ($crs_cm_name)"
yq 'del(select(.kind == "Deployment").spec.template.metadata.annotations["secret.reloader.stakater.com/reload"])' \
  "$TMP/wl-openchoreo-data-plane.yaml" > "$TMP/dp-noreload.yaml"
assert_eq "$(dp_reload_targets "$TMP/dp-noreload.yaml")" "<none>/$crs_cm_name" \
  "negative: contract catches a cluster-agent Deployment missing the Secret Reloader annotation"

# 9d. reloader on mgmt (values/role-mgmt.yaml) restarts OpenChoreo's Backstage on a config change: the catalog runs
#     it on mgmt, it watches Backstage's namespace with autoReloadAll, and its ConfigMap label selector matches every
#     ConfigMap the Backstage Deployment of addon openchoreo-control-plane mounts (backstage-extra-config included).
assert_match "$(yq -o=json -I=0 '.addons.reloader.roles' "$PV")" '"mgmt"' "reloader runs on mgmt (catalog roles)"
cp_ns=$(yq '.addons["openchoreo-control-plane"].namespace' "$PV")
helm template reloader "$ROOT/addons/reloader" --namespace "$rel_ns" \
  --values "$ROOT/addons/reloader/values/role-mgmt.yaml" > "$TMP/reloader-mgmt.yaml"
rel_args=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$TMP/reloader-mgmt.yaml")
rel_watch=$(printf '%s\n' "$rel_args" | sed -n 's/^--namespaces=//p')
rel_sel=$(printf '%s\n' "$rel_args" | sed -n 's/^--resource-label-selector=//p')
assert_match ",$rel_watch," ",$cp_ns," "mgmt reloader watches $cp_ns"
assert_match "$rel_args" '--auto-reload-all=true' "mgmt reloader auto-reloads workloads that mount a watched ConfigMap"
assert_match "$rel_sel" '^[^,=]+=[^,=]+$' "mgmt reloader selects ConfigMaps by one label (key=value)"
helm template openchoreo-control-plane "$ROOT/addons/openchoreo-control-plane" --namespace "$cp_ns" > "$TMP/cp-backstage.yaml"
bs_cms=$(yq 'select(.kind == "Deployment" and .metadata.name == "backstage")
  | .spec.template.spec.volumes[] | select(.configMap) | .configMap.name' "$TMP/cp-backstage.yaml")
assert_match "$bs_cms" '(^|[[:space:]])backstage-extra-config($|[[:space:]])' "Backstage mounts ConfigMap backstage-extra-config"
for cm in $bs_cms; do
  got=$(CM="$cm" K="${rel_sel%%=*}" yq 'select(.kind == "ConfigMap" and .metadata.name == strenv(CM))
    | .metadata.labels[strenv(K)] // "<none>"' "$TMP/cp-backstage.yaml")
  assert_eq "$got" "${rel_sel#*=}" "Backstage ConfigMap $cm carries the mgmt reloader label $rel_sel"
done

# 9e. dex is NOT a Kyverno-excluded platform namespace: its pod meets Pod Security restricted.
assert_kyverno_not_excluded dex
helm template dex "$ROOT/addons/dex" --namespace dex > "$TMP/dex-pss.yaml"
dex_pod='select(.kind == "Deployment") | .spec.template.spec'
assert_eq "$(yq "$dex_pod | .securityContext.runAsNonRoot" "$TMP/dex-pss.yaml")" true "dex pod runAsNonRoot"
assert_eq "$(yq "$dex_pod | .securityContext.seccompProfile.type" "$TMP/dex-pss.yaml")" RuntimeDefault "dex seccomp RuntimeDefault"
assert_eq "$(yq "$dex_pod | .containers[0].securityContext.allowPrivilegeEscalation" "$TMP/dex-pss.yaml")" false "dex no privilege escalation"
assert_eq "$(yq "$dex_pod | .containers[0].securityContext.readOnlyRootFilesystem" "$TMP/dex-pss.yaml")" true "dex readOnlyRootFilesystem"
assert_eq "$(yq -o=json -I=0 "$dex_pod | .containers[0].securityContext.capabilities.drop" "$TMP/dex-pss.yaml")" '["ALL"]' "dex drops ALL capabilities"

# 9. Harbor is NOT a Kyverno-excluded platform namespace: its pods meet Pod Security baseline, so the Audit policies
#    report on it like any workload (no blanket exclusion, no PolicyException needed). Guard both halves.
assert_kyverno_not_excluded harbor
helm template harbor "$ROOT/addons/harbor" --namespace harbor --values "$ROOT/installations/local/installation.yaml" \
  --set harbor.externalURL=https://harbor.openchoreo.localhost:9443 > "$TMP/harbor.yaml"
assert_pss_baseline "$TMP/harbor.yaml" '.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob"' \
  "Harbor workloads meet Pod Security baseline (no privileged/host namespaces/hostPath/hostPort/added caps)"

# 10. Platform-workflow egress + Prometheus ingress: the promotion gate's pod labels are the exact selector of the
#     workflow plane's NetworkPolicy platform-workflows-openchoreo AND the observability plane's NetworkPolicy
#     prometheus-platform-workflows, and both policies select the observability Prometheus Service's pods.
gate_labels=$(yq -o=json -I=0 '.promotionGate.podLabels' "$ROOT/addons/openchoreo-platform/values.yaml")
wp_labels=$(yq -o=json -I=0 '.runNetworkPolicy.platformWorkflows.podLabels' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")
op_from_labels=$(yq -o=json -I=0 '.prometheusIngress.fromPodLabels' "$ROOT/addons/openchoreo-observability-plane/values.yaml")
assert_eq "$gate_labels" "$wp_labels" "promotionGate.podLabels == runNetworkPolicy.platformWorkflows.podLabels"
assert_eq "$gate_labels" "$op_from_labels" "promotionGate.podLabels == openchoreo-observability-plane prometheusIngress.fromPodLabels"
assert_eq "$(yq '.runNetworkPolicy.platformWorkflows.controlPlane.port' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")" \
  "$(yq '.promotionGate.controlPlanePort' "$ROOT/addons/openchoreo-platform/values.yaml")" \
  "platform-workflow egress port == promotionGate.controlPlanePort"
helm template openchoreo-observability-plane "$ROOT/addons/openchoreo-observability-plane" \
  --namespace openchoreo-observability-plane > "$TMP/obs-plane.yaml"
prom_svc_sel=$(yq -o=json -I=0 'select(.kind == "Service" and .metadata.name == "openchoreo-observability-prometheus") | .spec.selector' \
  "$TMP/obs-plane.yaml")
wp_prom_sel=$(yq -o=json -I=0 '.runNetworkPolicy.platformWorkflows.observability.prometheus.podLabels' \
  "$ROOT/addons/openchoreo-workflow-plane/values.yaml")
op_prom_sel=$(yq -o=json -I=0 '.prometheusIngress.podLabels' "$ROOT/addons/openchoreo-observability-plane/values.yaml")
assert_eq "$wp_prom_sel" "$prom_svc_sel" "workflow-plane Prometheus egress podLabels == Service openchoreo-observability-prometheus selector"
assert_eq "$op_prom_sel" "$prom_svc_sel" "observability-plane prometheusIngress.podLabels == Service openchoreo-observability-prometheus selector"
prom_http_web='select(.kind == "Service" and .metadata.name == "openchoreo-observability-prometheus") | .spec.ports[] | select(.name == "http-web")'
prom_target="[$(yq "$prom_http_web | .targetPort" "$TMP/obs-plane.yaml")]"
assert_eq "$(yq -o=json -I=0 '.runNetworkPolicy.platformWorkflows.observability.prometheus.ports' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")" \
  "$prom_target" "workflow-plane Prometheus egress ports == Service http-web targetPort (NetworkPolicy matches after DNAT)"
assert_eq "$(yq -o=json -I=0 '.prometheusIngress.ports' "$ROOT/addons/openchoreo-observability-plane/values.yaml")" \
  "$prom_target" "observability-plane prometheusIngress.ports == Service http-web targetPort"
gate_prom=$(yq '.promotionGate.prometheusURL' "$ROOT/addons/openchoreo-platform/values.yaml")
prom_port=$(yq "$prom_http_web | .port" "$TMP/obs-plane.yaml")
assert_eq "$gate_prom" "http://openchoreo-observability-prometheus.openchoreo-observability-plane:$prom_port" \
  "promotionGate.prometheusURL == Service openchoreo-observability-prometheus http-web port"

# 11. The promotion gate's Thunder client (addon thunder bootstrap script 70) is the client the gate authenticates as,
#     with the secret from the same store key (else the gate fails at the token step).
ocp_values="$ROOT/addons/openchoreo-platform/values.yaml"
thunder_values="$ROOT/addons/thunder/values.yaml"
gate_client=$(yq '.thunderid.bootstrap.scripts["70-openchoreo-promotion-gate-app.yaml"]' "$thunder_values" \
  | yq '.inboundAuthConfig[0].config.clientId')
assert_eq "$gate_client" "$(yq '.promotionGate.clientID' "$ocp_values")" \
  "thunder script 70 clientId == openchoreo-platform promotionGate.clientID"
assert_eq "$(yq '.bootstrapSecret.promotionGate.remoteKey + "/" + .bootstrapSecret.promotionGate.property' "$thunder_values")" \
  "$(yq '.promotionGate.clientSecret.key + "/" + .promotionGate.clientSecret.property' "$ocp_values")" \
  "thunder bootstrapSecret.promotionGate == openchoreo-platform promotionGate.clientSecret"

# 12. Gated Components (charts/tenant authz.yaml) are protected by the component:delete role addon openchoreo-platform
#     defines, for the same restricted groups (defaults; installation.yaml `promotion` overrides both).
tenant_values="$ROOT/charts/tenant/values.yaml"
deleter=$(yq '.promotion.componentDeleterRole' "$tenant_values")
helm template openchoreo-platform "$ROOT/addons/openchoreo-platform" --namespace default -s templates/promotion-authz.yaml \
  > "$TMP/promotion-authz.yaml"
assert_eq "$(D="$deleter" yq 'select(.kind == "ClusterAuthzRole" and .metadata.name == strenv(D)) | .spec.actions | join(",")' \
  "$TMP/promotion-authz.yaml")" "component:delete" "charts/tenant componentDeleterRole is the addon's component:delete ClusterAuthzRole"
binding_actions="releasebinding:create,releasebinding:update,releasebinding:delete,projectreleasebinding:create,projectreleasebinding:update,projectreleasebinding:delete,resourcereleasebinding:create,resourcereleasebinding:update,resourcereleasebinding:delete"
assert_eq "$(yq 'select(.kind == "ClusterAuthzRole" and .metadata.name == "promotion-release-binding-writer") | .spec.actions | join(",")' \
  "$TMP/promotion-authz.yaml")" "$binding_actions" "promotion-release-binding-writer covers component, project and resource release bindings"
assert_eq "$(yq 'select(.kind == "ClusterAuthzRoleBinding" and .metadata.name == "promotion-deny-developers") | .spec.roleMappings[0].conditions[0].actions | join(",")' \
  "$TMP/promotion-authz.yaml")" "$binding_actions" "promotion-deny-developers condition actions match promotion-release-binding-writer"
# 12b. Developer authz is per project (#335). Org-wide, group developers holds read-only roles only (upstream binds it to
#      role developer: write access to every project); each tenant's developer groups get role developer scoped to that
#      project only, gated binding writes excluded by a condition (a deny on `developers` would not revoke them).
assert_eq "$(yq '.promotion.bindingWriteActions | join(",")' "$tenant_values")" "$binding_actions" \
  "charts/tenant promotion.bindingWriteActions == promotion-release-binding-writer actions"
authz_mappings='.openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[]'
assert_eq "$(yq "$authz_mappings | select(.name == \"developer-binding\") | [.roleMappings[].roleRef.name] | join(\",\")" \
  "$ROOT/addons/openchoreo-control-plane/values.yaml")" "cluster-reader,namespace-reader" \
  "negative: org-wide group developers gets read-only roles only"
assert_eq "$(yq "[$authz_mappings | select(.entitlement.claim == \"groups\" and .roleMappings[].roleRef.name == \"developer\")] | length" \
  "$ROOT/addons/openchoreo-control-plane/values.yaml")" 0 "negative: no group gets role developer cluster-wide"
helm template t "$ROOT/charts/tenant" --namespace argocd -f "$ROOT/installations/local/installation.yaml" \
  -f "$ROOT/installations/local/tenants/demo.yaml" > "$TMP/tenant-demo.yaml"
helm template t "$ROOT/charts/tenant" --namespace argocd -f "$ROOT/installations/local/installation.yaml" \
  --set project=billing --set description=Billing > "$TMP/tenant-billing.yaml"
for p in demo billing; do
  allow='select(.kind == "AuthzRoleBinding" and .spec.effect == "allow")'
  assert_eq "$(yq ea "[$allow] | length" "$TMP/tenant-$p.yaml")" 1 "tenant $p: one allow AuthzRoleBinding (its developers)"
  assert_eq "$(yq ea "[$allow | .spec.roleMappings[] | .scope.project // \"<namespace-wide>\"] | unique | join(\",\")" "$TMP/tenant-$p.yaml")" "$p" \
    "negative: tenant $p grants developer rights in project $p only (never another project or namespace-wide)"
  want_grp="$([ "$p" = demo ] && echo developers || echo "$p-developers")"
  assert_eq "$(yq "$allow | .spec.entitlement.value" "$TMP/tenant-$p.yaml")" "$want_grp" "tenant $p: developer group $want_grp"
done
helm template openchoreo-platform "$ROOT/addons/openchoreo-platform" --namespace default \
  -s templates/upstream-defaults.yaml > "$TMP/upstream-defaults.yaml"
assert_eq "$(yq 'select(.kind == "ClusterTrait" and .metadata.name == "observability-alert-rule") | .spec.creates[0].template.kind' \
  "$TMP/upstream-defaults.yaml")" "ObservabilityAlertRule" "upstream-defaults ships ClusterTrait observability-alert-rule"
for ct in service web-application worker; do
  assert_eq "$(CT="$ct" yq 'select(.kind == "ClusterComponentType" and .metadata.name == strenv(CT)) | .spec.allowedTraits[] | select(.name == "observability-alert-rule") | .kind' \
    "$TMP/upstream-defaults.yaml")" "ClusterTrait" "ClusterComponentType $ct allows ClusterTrait observability-alert-rule"
done
assert_eq "$(yq -o=json -I=0 '.promotion.restrictedGroups' "$tenant_values")" \
  "$(yq -o=json -I=0 '.promotion.restrictedGroups' "$ocp_values")" "promotion.restrictedGroups: charts/tenant == openchoreo-platform"

# 13. No literal env value in a ClusterWorkflow run template looks like a JSON list or map: OpenChoreo's WorkflowRun
#     renderer decodes such a string into a list/map, and Argo's workflow controller panics on the resulting
#     non-string env value (CrashLoopBackOff, no run of any workflow proceeds). Pass JSON base64-encoded instead.
# shellcheck disable=SC2016  # yq expression, not shell
json_env='select(.kind == "ClusterWorkflow") | .metadata.name as $w | .spec.runTemplate.spec.templates[]
  | (.script, .container) | select(.) | .env[]? | select((.value | tag) == "!!str" and (.value | test("^\\s*[\\[{]")))
  | $w + "/" + .name'
helm template openchoreo-platform "$ROOT/addons/openchoreo-platform" --namespace default \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/openchoreo-platform.yaml"
assert_eq "$(yq "$json_env" "$TMP/openchoreo-platform.yaml" | grep -v '^---$' || true)" "" \
  "ClusterWorkflow env values are never JSON-looking (rendered as lists/maps by OpenChoreo)"
printf 'kind: ClusterWorkflow\nmetadata: {name: bad}\nspec:\n  runTemplate:\n    spec:\n      templates:\n        - script:\n            env: [{name: L, value: '"'"'["production"]'"'"'}]\n' \
  > "$TMP/json-env-negative.yaml"
assert_eq "$(yq "$json_env" "$TMP/json-env-negative.yaml")" "bad/L" "check 13 flags a JSON-looking env value (negative case)"

# 14. Every run without a pod token (automountServiceAccountToken: false) names an executor ServiceAccount whose token
#     Secret <sa>.service-account-token the workflow plane renders in the run namespace: Argo mounts the executor token
#     from that Secret, and without it every run pod hangs in Init (FailedMount) until its deadline.
token_sa=$(yq '.runExecutorToken.serviceAccount' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")
helm template openchoreo-workflow-plane "$ROOT/addons/openchoreo-workflow-plane" --namespace openchoreo-workflow-plane \
  -s templates/cluster-workflow-templates.yaml -s templates/run-executor-token.yaml > "$TMP/workflow-plane.yaml"
assert_eq "$(yq 'select(.kind == "Secret" and .type == "kubernetes.io/service-account-token") | .metadata.name' \
  "$TMP/workflow-plane.yaml")" "$token_sa.service-account-token" "workflow plane renders the executor token Secret"
# shellcheck disable=SC2016  # yq expression, not shell
executors='[(select(.kind == "ClusterWorkflowTemplate") | .spec), (select(.kind == "ClusterWorkflow") | .spec.runTemplate.spec)][]
  | select(.automountServiceAccountToken == false) | (.executor.serviceAccountName // "<none>")'
assert_eq "$(yq "$executors" "$TMP/workflow-plane.yaml" "$TMP/openchoreo-platform.yaml" | grep -v '^---$' | sort -u)" \
  "$token_sa" "every token-less ClusterWorkflow(Template) uses the executor ServiceAccount with a rendered token"

# 15. Harbor image verification on workload clusters (#15): the ConfigMap and pull Secret charts/cluster delivers into
#     Kyverno's namespace are exactly what addon kyverno-policies reads (resource.Get, credentials.secrets) and addon
#     kyverno mounts as registry CA (values/role-workload.yaml). A rename on one side alone would make Harbor images fail
#     verification (denied in production) or Kyverno distrust Harbor's certificate.
iv_ns=$(yq '.imageVerification.namespace' "$ROOT/charts/cluster/values.yaml")
iv_cm=$(yq '.imageVerification.configMap' "$ROOT/charts/cluster/values.yaml")
iv_ps=$(yq '.imageVerification.pullSecret' "$ROOT/charts/cluster/values.yaml")
assert_eq "$(yq '.imageVerification.platformKey.cluster | [.namespace, .configMap, .pullSecret] | join(" ")' \
  "$ROOT/addons/kyverno-policies/values.yaml")" "$iv_ns $iv_cm $iv_ps" \
  "kyverno-policies reads the image-verification ConfigMap/pull Secret charts/cluster delivers"
assert_eq "$(yq '.addons.kyverno.namespace' "$ROOT/charts/platform/values.yaml")" "$iv_ns" \
  "image-verification material lands in addon kyverno's namespace"
assert_eq "$(yq '[.kyverno.admissionController.extraVolumes[], .kyverno.reportsController.extraVolumes[]] | map(.configMap.name) | unique | join(" ")' \
  "$ROOT/addons/kyverno/values/role-workload.yaml")" "$iv_cm" \
  "Kyverno admission + reports controllers mount the registry CA from the delivered ConfigMap"


# 16. Auto-build (#164): every installation selects a trigger explicitly, and whichever it selects ends in the one
#     WorkflowTemplate that creates the per-commit WorkflowRun: poll = CronWorkflow in the run namespace; webhook = the
#     argo-events Sensor creating Workflows from that same template (names and namespace agree across both addons).
#     The template reads the GitHub App only through the scoped store `workflows` (key allowed there) and its pods are
#     under the run namespace's default-deny NetworkPolicy.
ab_tpl=$(yq '.autoBuild.workflowTemplate' "$ocp_values")
assert_eq "$(yq '.autoBuildWebhook.workflowTemplate' "$ROOT/addons/argo-events/values.yaml")" "$ab_tpl" \
  "argo-events autoBuildWebhook.workflowTemplate == openchoreo-platform autoBuild.workflowTemplate"
assert_eq "$(yq '.autoBuild.secretStore' "$ocp_values")" \
  "$(yq '.clusterWorkflowPlane.secretStore' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")" \
  "autoBuild.secretStore == the ClusterWorkflowPlane's secret store"
ab_key=$(yq '.autoBuild.github.key' "$ocp_values")
assert_eq "$(K="$ab_key" yq '.workflowStore.keys[] | select(. == strenv(K))' "$ROOT/addons/secret-stores/values.yaml")" \
  "$ab_key" "autoBuild.github.key is readable through ClusterSecretStore workflows (workflowStore.keys)"
helm template openchoreo-workflow-plane "$ROOT/addons/openchoreo-workflow-plane" --namespace openchoreo-workflow-plane \
  -s templates/run-network-policy.yaml > "$TMP/run-np.yaml"
assert_eq "$(yq -o=json -I=0 'select(.kind == "NetworkPolicy" and .metadata.name == "build-runs-default-deny") | .spec.podSelector' \
  "$TMP/run-np.yaml")" "{}" "the run namespace's default-deny NetworkPolicy selects every pod (auto-build pods included)"
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  inst=$(basename "$(dirname "$inst_file")")
  trig=$(yq '.openchoreo.workflowPlane.autoBuild // "unset"' "$inst_file")
  assert_match "$trig" '^(poll|webhook)$' "$inst selects an auto-build trigger (openchoreo.workflowPlane.autoBuild: $trig)"
  run_ns="workflows-$(yq '.openchoreo.orgNamespace // "default"' "$inst_file")"
  # with the platform GitHub App (secrets.githubGateApp.enabled, set by bootstrap.sh when seeded); without it neither
  # the trigger nor the webhook renders (#192: their token generators would fail and degrade the apps)
  helm template openchoreo-platform "$ROOT/addons/openchoreo-platform" --namespace default --values "$inst_file" \
    --set secrets.githubGateApp.enabled=true -s templates/auto-build.yaml > "$TMP/ab-$inst.yaml" 2>/dev/null || : > "$TMP/ab-$inst.yaml"
  helm template argo-events "$ROOT/addons/argo-events" --namespace argo-events --values "$inst_file" \
    --set workflowPlane=true --set secrets.githubGateApp.enabled=true --set-string 'falco.clusters={mgmt}' > "$TMP/ae-$inst.yaml"
  assert_eq "$(helm template openchoreo-platform "$ROOT/addons/openchoreo-platform" --namespace default --values "$inst_file" \
    -s templates/auto-build.yaml 2>&1 | grep -c '^kind:' || true)" 0 "$inst: no auto-build without the platform GitHub App"
  assert_eq "$(helm template argo-events "$ROOT/addons/argo-events" --namespace argo-events --values "$inst_file" \
    --set workflowPlane=true --set-string 'falco.clusters={mgmt}' | yq 'select(.metadata.name == "auto-build-webhook") | .kind')" "" \
    "$inst: no auto-build webhook without the platform GitHub App"
  assert_eq "$(N="$ab_tpl" yq 'select(.kind == "WorkflowTemplate" and .metadata.name == strenv(N)) | .metadata.namespace' \
    "$TMP/ab-$inst.yaml")" "$run_ns" "$inst: WorkflowTemplate $ab_tpl renders in $run_ns"
  cron=$(yq 'select(.kind == "CronWorkflow") | .spec.workflowSpec.workflowTemplateRef.name + "@" + .metadata.namespace' "$TMP/ab-$inst.yaml")
  sensor=$(yq 'select(.kind == "Sensor" and .metadata.name == "auto-build") | .spec.triggers[0].template.k8s.source.resource
    | .spec.workflowTemplateRef.name + "@" + .metadata.namespace' "$TMP/ae-$inst.yaml")
  route=$(yq 'select(.kind == "HTTPRoute" and .metadata.name == "auto-build-webhook") | .metadata.name' "$TMP/ae-$inst.yaml")
  if [[ "$trig" == poll ]]; then
    assert_eq "$cron" "$ab_tpl@$run_ns" "$inst (poll): CronWorkflow runs $ab_tpl"
    assert_eq "$sensor$route" "" "$inst (poll): nothing exposed (no webhook Sensor, no route)"
  else
    assert_eq "$sensor" "$ab_tpl@$run_ns" "$inst (webhook): the Sensor creates Workflows from $ab_tpl"
    assert_eq "$route" "auto-build-webhook" "$inst (webhook): the GitHub endpoint is routed"
    assert_eq "$cron" "$ab_tpl@$run_ns" "$inst (webhook): resync CronWorkflow runs the same $ab_tpl"
  fi
done

# 17. PR previews (#168): the pieces of one preview agree across charts - the Component opt-in the ApplicationSet selects
#     on is the one the auto-build pass re-checks; the pull request generator's token Secret is the one addon
#     secret-stores mints, in Argo CD's namespace; AppProject previews admits exactly the kinds charts/preview renders;
#     every installation with previews on names a data plane its fleet has, and the policy tier of preview cells (the
#     supply-chain gate's defaultAction: their environment names are not listed) is the development tier.
tenant_values="$ROOT/charts/tenant/values.yaml"
assert_eq "$(yq -o=json -I=0 '.previewOptIn' "$tenant_values")" "$(yq -o=json -I=0 '.autoBuild.previews.optIn' "$ocp_values")" \
  "previews: charts/tenant previewOptIn == openchoreo-platform autoBuild.previews.optIn"
assert_eq "$(yq '.previewToken.secretName' "$tenant_values")" \
  "$(yq '.previewToken.secretName' "$ROOT/addons/secret-stores/values.yaml")" \
  "previews: the pull request generator's tokenRef is the Secret addon secret-stores mints"
assert_eq "$(yq '.argocd.namespace' "$tenant_values")" "$(yq '.previewToken.namespace' "$ROOT/addons/secret-stores/values.yaml")" \
  "previews: the token Secret lives in the ApplicationSets' namespace (tokenRef is namespace-local)"
assert_eq "$(yq '.autoBuild.previews.argocdNamespace' "$ocp_values")" "$(yq '.argocd.namespace' "$tenant_values")" \
  "previews: the auto-build pass lists preview Applications where the ApplicationSets put them"
# The per-tenant cap (#385): the pass grants at most the number Kyverno enforces, with the label the ApplicationSet
# renders resources for, and skips the same bot PRs the ApplicationSet renders empty (defaults; installation.yaml
# feeds all).
assert_eq "$(yq '.previews.maxPerTenant' "$ocp_values")" "$(yq '.previews.maxPerTenant' "$ROOT/addons/kyverno-policies/values.yaml")" \
  "previews: the auto-build pass's cap default == Kyverno platform-preview-cap's"
for k in grantedLabel skipBots botLabel; do
  assert_eq "$(yq ".previews.$k" "$ocp_values")" "$(yq ".previews.$k" "$tenant_values")" \
    "previews: openchoreo-platform previews.$k == charts/tenant previews.$k"
done
helm template platform "$ROOT/charts/platform" --namespace argocd -s templates/projects.yaml > "$TMP/pv-projects.yaml"
pv_kinds=$(yq 'select(.metadata.name == "previews") | .spec.namespaceResourceWhitelist[] | .group + "/" + .kind' \
  "$TMP/pv-projects.yaml" | sort | tr '\n' ' ')
helm template p "$ROOT/charts/preview" --set project=demo,component=hello-world,pullRequest=7,granted=true \
  --set-string commit=0123456789abcdef0123456789abcdef01234567 > "$TMP/pv-chart.yaml"
chart_kinds=$(yq 'select(.kind) | (.apiVersion | sub("/.*", "")) + "/" + .kind' "$TMP/pv-chart.yaml" | grep -v '^---$' | sort -u | tr '\n' ' ')
assert_eq "$pv_kinds" "$chart_kinds" "previews: AppProject previews admits exactly the kinds charts/preview renders"
kp_values="$ROOT/addons/kyverno-policies/values.yaml"
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  inst=$(basename "$(dirname "$inst_file")")
  [[ "$(yq '.previews.enabled // false' "$inst_file")" == true ]] || continue
  dp=$(yq '.previews.dataPlane // ""' "$inst_file")
  dp_ok=no
  for cf in "$(dirname "$inst_file")"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    [[ "$(yq '.name' "$cf")" == "$dp" && "$(yq '.openchoreo.dataPlane.enabled // false' "$cf")" == true ]] && dp_ok=yes
  done
  assert_eq "$dp_ok" yes "$inst: previews.dataPlane $dp is a cluster of the fleet with an OpenChoreo data plane"
  ov="$(dirname "$inst_file")/addons/kyverno-policies/values.yaml"
  ovargs=(); [[ -f "$ov" ]] && ovargs=("$ov")
  # shellcheck disable=SC2016  # $i is a yq variable
  tier=$(yq eval-all '. as $i ireduce ({}; . * $i) | .imageVerification.defaultAction + "/" + .imageVerification.environments.development' \
    "$kp_values" ${ovargs[@]+"${ovargs[@]}"})
  assert_eq "${tier%%/*}" "${tier##*/}" "$inst: preview cells get the development policy tier (imageVerification.defaultAction == development's action: $tier)"
done

# 18. Build git credentials (#34): no long-lived build token anywhere. Each WorkflowRun mints an installation token of
#     the platform GitHub App for its one repository (ESO GithubAccessToken generator); the App key is readable through
#     the ClusterWorkflowPlane's scoped store, and the RoleBinding names the agent ServiceAccount the upstream
#     workflow-plane chart really runs (it applies the per-run generators).
pat=$(git -C "$ROOT" grep -n -I -i -E 'platform-github-build|github_build|github-build' -- . \
  ':!hack/tests/test_gitops_contracts.sh' ':!hack/tests/test_bootstrap_secrets.sh' ':!docs/diagrams/out' || true)
assert_eq "$pat" "" "no build PAT (platform-github-build) referenced anywhere"
bw_key=$(yq '.buildWorkflows.github.key' "$ocp_values")
assert_eq "$(K="$bw_key" yq '.workflowStore.keys[] | select(. == strenv(K))' "$ROOT/addons/secret-stores/values.yaml")" \
  "$bw_key" "buildWorkflows.github.key is readable through ClusterSecretStore workflows (workflowStore.keys)"
assert_eq "$(yq '.buildWorkflows.github.secretStore' "$ocp_values")" \
  "$(yq '.clusterWorkflowPlane.secretStore' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")" \
  "buildWorkflows.github.secretStore == the ClusterWorkflowPlane's secret store"
render_standalone_addon openchoreo-workflow-plane "$TMP/wp-all.yaml"
agent="$(yq '.buildWorkflows.github.agent.namespace + "/" + .buildWorkflows.github.agent.serviceAccount' "$ocp_values")"
assert_eq "$(A="$agent" yq 'select(.kind == "ServiceAccount" and (.metadata.namespace + "/" + .metadata.name) == strenv(A)) | .metadata.name' \
  "$TMP/wp-all.yaml")" "${agent#*/}" "buildWorkflows.github.agent is the workflow-plane cluster agent's ServiceAccount"

# 19. Sign in with GitHub (Dex + Thunder 1.1.1 authorizationMapping): every OpenChoreo authz group (claim: groups)
#     has a Thunder authorizationMapping rule (<org>:<team> -> that group's UUID) with sync.groupsAndRoles: override_all,
#     and Dex + Thunder agree on issuer, org, clientId, redirectUri and store key.
dex_values="$ROOT/addons/dex/values.yaml"
oc_cp_values="$ROOT/addons/openchoreo-control-plane/values.yaml"
helm template thunder "$ROOT/addons/thunder" --namespace thunder \
  --set githubLogin.enabled=true --set secrets.githubLogin.enabled=true > "$TMP/thunder-gh.yaml"
yq -N 'select(.kind == "ConfigMap" and .metadata.name == "thunder-github-login") | .data["github-dex-connection.yaml"]' \
  "$TMP/thunder-gh.yaml" > "$TMP/thunder-gh-conn.yaml"
yq -N 'select(.kind == "ConfigMap" and .metadata.name == "thunder-bootstrap") | .data["50-user-schema-and-users.yaml"]' \
  "$TMP/thunder-gh.yaml" > "$TMP/thunder-users.yaml"
gh_org=$(yq '.githubLogin.org' "$thunder_values")
assert_eq "$(yq '.dex.config.connectors[0].config.orgs[0].name' "$dex_values")" "$gh_org" \
  "github-login: Dex GitHub org == Thunder githubLogin.org"
assert_eq "$(yq '.dex.config.issuer' "$dex_values")" "$(yq '.githubLogin.issuer' "$thunder_values")" \
  "github-login: Dex issuer == Thunder githubLogin.issuer"
assert_eq "$(yq '.dex.config.staticClients[0].id' "$dex_values")" "$(yq '.githubLogin.clientId' "$thunder_values")" \
  "github-login: Dex staticClient id == Thunder githubLogin.clientId"
assert_eq "$(yq '.dex.config.staticClients[0].redirectURIs[0]' "$dex_values")" "$(yq '.redirectUri' "$TMP/thunder-gh-conn.yaml")" \
  "github-login: Dex staticClient redirectURI == Thunder connection redirectUri"
assert_eq "$(yq '.secrets.remoteKey' "$dex_values")" "$(yq '.githubLogin.clientSecret.remoteKey' "$thunder_values")" \
  "github-login: Dex and Thunder read the same store key (github-login)"
assert_eq "$(yq '.attributeConfiguration.sync.groupsAndRoles' "$TMP/thunder-gh-conn.yaml")" "override_all" \
  "github-login: Thunder connection syncs groupsAndRoles with override_all"
assert_eq "$(yq '.attributeConfiguration.authorizationMapping.rules[0].valueType' "$TMP/thunder-gh-conn.yaml")" "array" \
  "github-login: Thunder authorizationMapping evaluates groups claim as array"
while IFS= read -r grp; do
  [[ -n "$grp" ]] || continue
  gid=$(G="$grp" yq 'select(.resource_type == "group" and .name == strenv(G)) | .id' "$TMP/thunder-users.yaml" | tr -d '\r')
  assert_match "$gid" '^[0-9a-f-]+$' "github-login: OpenChoreo authz group '$grp' exists in Thunder bootstrap"
  rule_target=$(V="$gh_org:$grp" yq '.attributeConfiguration.authorizationMapping.rules[0].values[] | select(.operator == "includes" and .value == strenv(V)) | .targets[0] | .type + ":" + .id' "$TMP/thunder-gh-conn.yaml" | tr -d '\r')
  assert_eq "$rule_target" "group:$gid" "github-login: OpenChoreo authz group '$grp' has authorizationMapping rule $gh_org:$grp -> group:$gid"
done < <(yq '.openchoreo-control-plane.openchoreoApi.config.security.authorization.bootstrap.mappings[] | select(.entitlement.claim == "groups") | .entitlement.value' "$oc_cp_values" | tr -d '\r' | sort -u)

finish
