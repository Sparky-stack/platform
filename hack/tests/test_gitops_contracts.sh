#!/usr/bin/env bash
# Cross-chart contract tests: label agreement, catalog contracts, AppProjects, and bootstrap/GitOps alignment.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_gitops_contracts =="

helm template platform "$ROOT/charts/platform" --namespace argocd \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/platform.yaml"

# 1. mgmt cluster secret carries all selection labels + addons-revision annotation
for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation; do
  mgmt_v=$(yq "select(.kind == \"Secret\" and .metadata.name == \"in-cluster\") | .metadata.labels[\"$key\"]" "$TMP/platform.yaml")
  assert_nonempty "$mgmt_v" "in-cluster carries $key"
done
mgmt_rev=$(yq 'select(.kind == "Secret" and .metadata.name == "in-cluster") | .metadata.annotations["platform.koorikla.io/addons-revision"]' "$TMP/platform.yaml")
assert_eq "$mgmt_rev" "HEAD" "in-cluster addons-revision defaults to HEAD"

# 2. If capi-cluster.yaml is present, verify cluster secret labels match CAPI Cluster labels
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  helm template cluster-dev1 "$ROOT/charts/cluster" --namespace fleet \
    --values "$ROOT/installations/local/installation.yaml" \
    --values "$ROOT/installations/local/clusters/dev1.yaml" > "$TMP/dev1.yaml"
  for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation platform.koorikla.io/cni addons.platform.koorikla.io/cilium; do
    capi_v=$(yq "select(.kind == \"Cluster\" and .metadata.name == \"dev1\") | .metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    wl_v=$(yq "select(.kind == \"ExternalSecret\" and .metadata.name == \"dev1-argocd-cluster\") | .spec.target.template.metadata.labels[\"$key\"]" "$TMP/dev1.yaml")
    assert_eq "$wl_v" "$capi_v" "dev1 argocd cluster label $key matches CAPI Cluster"
  done
fi

# 2b. networking: the cilium addon follows the cluster's cni and reaches the API server via the cluster secret's server
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  dev1_cni=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["platform.koorikla.io/cni"]' "$TMP/dev1.yaml")
  dev1_cil=$(yq 'select(.kind == "Cluster" and .metadata.name == "dev1") | .metadata.labels["addons.platform.koorikla.io/cilium"]' "$TMP/dev1.yaml")
  assert_eq "$dev1_cil" "$([[ "$dev1_cni" == cilium ]] && echo true || echo false)" "dev1 cilium addon label follows cni ($dev1_cni)"
fi
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
    external-dns) continue ;;  # external-dns meets PSS restricted: policed like a workload (check 9b)
    keda|strimzi|cnpg-system) continue ;;   # opt-in data-service operators meet PSS restricted: policed (test_data_services.sh)
    crossplane-system) continue ;;          # Crossplane core, Functions, providers meet PSS restricted: policed (test_crossplane_render.sh)
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
cc_ssd=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-clusterclasses") | .spec.template.spec.syncPolicy.syncOptions[] | select(. == "ServerSideDiff=true")' "$TMP/platform.yaml")
assert_eq "$cc_ssd" "ServerSideDiff=true" "clusterclasses enables ServerSideDiff"
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

# 7. secret-stores creates platform, mgmt-fleet, mgmt-openchoreo on mgmt and default on workload
helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets \
  --values "$ROOT/addons/secret-stores/values/role-mgmt.yaml" > "$TMP/ss-mgmt.yaml"
for s in platform mgmt-fleet mgmt-openchoreo; do
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
  idx_paths=$(helm template cc "$ROOT/addons/clusterclasses" --values "$inst_file" 2>/dev/null \
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
    done < <(yq '.k3s.dockerLeaderElectionArgs[]' "$ROOT/addons/clusterclasses/values.yaml")
  done
  printf '%s' "$miss"
}
assert_eq "$(yq '.k3s.dockerLeaderElectionArgs | length' "$ROOT/addons/clusterclasses/values.yaml")" 3 \
  "clusterclasses k3s.dockerLeaderElectionArgs sets lease duration, renew deadline and retry period"
assert_eq "$(k3d_le_missing "$ROOT/bootstrap/k3d-mgmt.yaml")" "" "bootstrap/k3d-mgmt.yaml passes the CAPD leader election to every embedded controller"
yq 'del(.options.k3s.extraArgs[] | select(.arg == "--kube-scheduler-arg=*"))' "$ROOT/bootstrap/k3d-mgmt.yaml" > "$TMP/k3d-nole.yaml"
assert_match "$(k3d_le_missing "$TMP/k3d-nole.yaml")" "kube-scheduler-arg=leader-elect-lease-duration" "contract catches a k3d config without the scheduler leader election"

# 9b. external-dns is NOT a Kyverno-excluded platform namespace either: the chart defaults meet Pod Security restricted.
for f in addons/kyverno-policies/values.yaml addons/kyverno/values.yaml; do
  assert_eq "$(grep -cE '^ *- external-dns( |$)' "$ROOT/$f" || true)" 0 "external-dns not excluded from Kyverno ($f)"
done
helm template external-dns "$ROOT/addons/external-dns" --namespace external-dns -f "$ROOT/addons/external-dns/values/role-workload.yaml" \
  -f "$ROOT/addons/external-dns/values/dns-route53.yaml" --set dns.provider=route53 --set 'dns.domainFilters={a.example.com}' \
  --set 'external-dns.domainFilters={a.example.com}' --set-string external-dns.txtOwnerId=sample > "$TMP/edns-pss.yaml"
edns_pod='select(.kind == "Deployment") | .spec.template.spec'
assert_eq "$(yq "$edns_pod | .securityContext.runAsNonRoot" "$TMP/edns-pss.yaml")" true "external-dns pod runAsNonRoot"
assert_eq "$(yq "$edns_pod | .securityContext.seccompProfile.type // .containers[0].securityContext.seccompProfile.type" "$TMP/edns-pss.yaml")" RuntimeDefault "external-dns seccomp RuntimeDefault"
assert_eq "$(yq "$edns_pod | .containers[0].securityContext.allowPrivilegeEscalation" "$TMP/edns-pss.yaml")" false "external-dns no privilege escalation"
assert_eq "$(yq -o=json -I=0 "$edns_pod | .containers[0].securityContext.capabilities.drop" "$TMP/edns-pss.yaml")" '["ALL"]' "external-dns drops ALL capabilities"

# 9. Harbor is NOT a Kyverno-excluded platform namespace: its pods meet Pod Security baseline, so the Audit policies
#    report on it like any workload (no blanket exclusion, no PolicyException needed). Guard both halves.
for f in addons/kyverno-policies/values.yaml addons/kyverno/values.yaml; do
  assert_eq "$(grep -cE '^ *- harbor$' "$ROOT/$f" || true)" 0 "harbor not excluded from Kyverno ($f)"
done
helm template harbor "$ROOT/addons/harbor" --namespace harbor --values "$ROOT/installations/local/installation.yaml" \
  --set harbor.externalURL=https://harbor.openchoreo.localhost:9443 > "$TMP/harbor.yaml"
pss=$(yq 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob")' "$TMP/harbor.yaml" \
  | grep -E 'privileged: true|host(Network|PID|IPC): true|hostPath:|hostPort:|^ *add:' || true)
assert_eq "$pss" "" "Harbor workloads meet Pod Security baseline (no privileged/host namespaces/hostPath/hostPort/added caps)"

# 10. Platform-workflow egress: the promotion gate's pod labels are exactly the selector of the workflow plane's
#     NetworkPolicy platform-workflows-openchoreo (else the gate cannot reach the OpenChoreo API / Thunder / observer).
gate_labels=$(yq -o=json -I=0 '.promotionGate.podLabels' "$ROOT/addons/openchoreo-platform/values.yaml")
wp_labels=$(yq -o=json -I=0 '.runNetworkPolicy.platformWorkflows.podLabels' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")
assert_eq "$gate_labels" "$wp_labels" "promotionGate.podLabels == runNetworkPolicy.platformWorkflows.podLabels"
assert_eq "$(yq '.runNetworkPolicy.platformWorkflows.controlPlane.port' "$ROOT/addons/openchoreo-workflow-plane/values.yaml")" \
  "$(yq '.promotionGate.controlPlanePort' "$ROOT/addons/openchoreo-platform/values.yaml")" \
  "platform-workflow egress port == promotionGate.controlPlanePort"

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

finish
