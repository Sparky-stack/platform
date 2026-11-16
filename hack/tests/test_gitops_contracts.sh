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
  for key in platform.koorikla.io/name platform.koorikla.io/role platform.koorikla.io/provider platform.koorikla.io/region platform.koorikla.io/environment platform.koorikla.io/installation platform.koorikla.io/cni addons.platform.koorikla.io/cilium mesh.platform.koorikla.io/group mesh.platform.koorikla.io/network addons.platform.koorikla.io/istio-eastwest addons.platform.koorikla.io/istio-csr; do
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

# 2b2. multicluster mesh (docs/multicluster.md): names shared between charts/cluster, addon openbao (mesh CA on mgmt),
# addon istio-csr (members) and istio-eastwest; istio-ambient's multi-network settings driven by the mesh labels.
PV="$ROOT/charts/platform/values.yaml"
OB="$ROOT/addons/openbao/values.yaml"
IC="$ROOT/addons/istio-csr/values.yaml"
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  helm template cluster-dev1 "$ROOT/charts/cluster" --namespace fleet \
    --values "$ROOT/installations/local/installation.yaml" --values "$ROOT/installations/local/clusters/dev1.yaml" \
    --set mesh.group=contract --set 'mesh.groups={contract}' --set mgmt.addons.openbao=true > "$TMP/dev1-mesh.yaml"
  helm template openbao "$ROOT/addons/openbao" --namespace openbao --values "$ROOT/installations/local/installation.yaml" \
    --set 'mesh.groups={contract}' > "$TMP/openbao.yaml"
  helm template istio-csr "$ROOT/addons/istio-csr" --namespace istio-system \
    --values "$ROOT/installations/local/installation.yaml" --set-string mesh.group=contract --set-string cluster.name=dev1 \
    > "$TMP/istio-csr.yaml"
  # trust payload <- openbao-ca-bundle (public certs) through store mgmt-openbao
  trust_store=$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "dev1-mesh-trust") | .spec.secretStoreRef.name' "$TMP/dev1-mesh.yaml")
  assert_eq "$trust_store" "$(yq '.caPublic.store' "$OB")" "mesh trust payload reads the store addon openbao publishes"
  assert_match "$(yq -o=json -I=0 '.caPublic.namespaces' "$OB")" '"fleet"' "store mgmt-openbao admits fleet (charts/cluster)"
  root_key=$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "dev1-mesh-trust") | .spec.data[] | select(.secretKey == "root") | .remoteRef.property' "$TMP/dev1-mesh.yaml")
  assert_match "$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "openbao-ca-bundle") | .spec.data[].secretKey' "$TMP/openbao.yaml" | tr '\n' ' ')" "(^| )$root_key " \
    "the group root key charts/cluster pins ($root_key) is published by addon openbao"
  # OpenBao inputs: label and store agree, and the store admits the openbao namespace
  oc_label=$(yq '.meshClients.label' "$OB")
  assert_eq "$(yq "select(.kind == \"ExternalSecret\" and .metadata.name == \"dev1-mesh-openbao\") | .spec.target.template.metadata.labels[\"$oc_label\"]" "$TMP/dev1-mesh.yaml")" "true" \
    "charts/cluster labels the member's OpenBao inputs with addon openbao's meshClients.label"
  stores_ss=$(helm template secret-stores "$ROOT/addons/secret-stores" --namespace external-secrets)
  assert_match "$(printf '%s\n' "$stores_ss" | yq -o=json -I=0 'select(.kind == "ClusterSecretStore" and .metadata.name == "mgmt-fleet") | .spec.conditions[].namespaces')" \
    "\"$(yq '.addons.openbao.namespace' "$PV")\"" "store mgmt-fleet admits the openbao namespace (mesh-clients)"
  # member auth: istio-csr's Vault Issuer == what the reconcile configures for this cluster
  iss() { yq "select(.kind == \"Issuer\" and .metadata.name == \"$(yq '.issuer.name' "$IC")\") | $1" "$TMP/istio-csr.yaml"; }
  ic_ns=$(yq '.addons["istio-csr"].namespace' "$PV")
  assert_eq "$(yq '.memberAuth.audience' "$OB")" "vault://$ic_ns/$(yq '.issuer.name' "$IC")" "OpenBao accepts exactly cert-manager's issuer audience (vault://<ns>/<issuer>)"
  assert_eq "$(yq '.memberAuth.serviceAccount' "$OB")" "$ic_ns:$(yq '.issuer.serviceAccount' "$IC")" "OpenBao binds the istio-csr issuer's ServiceAccount"
  assert_eq "$(iss .spec.vault.auth.kubernetes.role)" "$(yq '.memberAuth.role' "$OB")" "Vault Issuer role == OpenBao member role"
  assert_eq "$(iss .spec.vault.auth.kubernetes.mountPath)" "/v1/auth/mesh-dev1" "Vault Issuer logs in at auth/mesh-<cluster>"
  assert_eq "$(iss .spec.vault.path)" "pki-mesh-contract-int/sign/dev1" "Vault Issuer signs at pki-mesh-<group>-int/sign/<cluster>"
  RS="$ROOT/addons/openbao/files/mesh-reconcile.sh"
  assert_match "$(cat "$RS")" 'auth enable -path="mesh-\$c"' "the reconcile creates auth/mesh-<cluster>"
  assert_match "$(cat "$RS")" 'int="pki-mesh-\$g-int"' "the reconcile names the group intermediate pki-mesh-<group>-int"
  assert_match "$(cat "$RS")" 'write "\$int/roles/\$c"' "the reconcile creates role <cluster> in that mount"
  assert_eq "$(iss .spec.vault.server)" "https://$(yq '.mesh.ca.host' "$ROOT/installations/local/installation.yaml"):$(yq '.mesh.ca.port' "$ROOT/installations/local/installation.yaml")" \
    "Vault Issuer dials installation.yaml mesh.ca"
  assert_eq "$(yq 'select(.kind == "Gateway") | .spec.listeners[0].hostname' "$TMP/openbao.yaml")" "$(yq '.mesh.ca.host' "$ROOT/installations/local/installation.yaml")" \
    "OpenBao's passthrough listener serves mesh.ca.host"
  assert_match "$(yq 'select(.kind == "Certificate" and .metadata.name == "openbao-tls") | .spec.dnsNames[]' "$TMP/openbao.yaml" | tr '\n' ' ')" \
    "$(yq '.mesh.ca.host' "$ROOT/installations/local/installation.yaml")" "OpenBao's listener cert names mesh.ca.host"
  # PKI profile: what istio-csr requests is what the OpenBao roles allow
  csr_dns=$(yq '.["cert-manager-istio-csr"].app.tls.certificateDNSNames[]' "$IC")
  for d in istiod.istio-system.svc $csr_dns; do
    assert_match "$(yq '.pki.allowedDomains[]' "$OB" | tr '\n' ' ')" "(^| )$d( |$)" "OpenBao roles allow DNS name $d"
  done
  assert_eq "$(yq '.["cert-manager-istio-csr"].app.tls.trustDomain' "$IC")" "$(yq '.pki.trustDomain' "$OB")" "istio-csr trust domain == OpenBao roles' SPIFFE trust domain"
  hours() { local v=$1; case "$v" in *h) echo "${v%h}" ;; *m) echo 0 ;; *) echo 999999 ;; esac; }
  wmax=$(hours "$(yq '.pki.workloadMaxTTL' "$OB")")
  for k in '.app.server.maxCertificateDuration' '.app.tls.certificateDuration' '.app.tls.istiodCertificateDuration'; do
    v=$(yq ".[\"cert-manager-istio-csr\"]$k" "$IC")
    assert_eq "$([[ $(hours "$v") -le $wmax ]] && echo ok || echo "$v")" ok "istio-csr $k ($v) <= OpenBao workloadMaxTTL"
  done
  assert_eq "$(yq '.ztunnel.caAddress' "$ROOT/addons/istio-ambient/values/mesh-member.yaml")" "cert-manager-istio-csr.$ic_ns.svc:443" "ztunnel's CA is istio-csr's Service"
  assert_eq "$(yq '.istiod.env.ENABLE_CA_SERVER' "$ROOT/addons/istio-ambient/values/mesh-member.yaml")" "false" "istiod runs no CA on mesh members"
  # reader identity (remote secrets) shared by charts/cluster, istio-eastwest and the admission guard
  reader_cn=$(yq 'select(.kind == "Certificate" and .metadata.name == "dev1-mesh-reader") | .spec.commonName' "$TMP/dev1-mesh.yaml")
  assert_eq "$reader_cn" "$(yq '.reader.user' "$ROOT/addons/istio-eastwest/values.yaml")" "remote-secret client cert CN == user istio-eastwest binds"
  assert_eq "$reader_cn" "$(yq '.admission.readerUser' "$OB")" "remote-secret client cert CN == the only CN the client-ca admission policy admits"
  assert_eq "$(yq 'select(.kind == "Certificate" and .metadata.name == "dev1-mesh-reader") | .spec.duration' "$TMP/dev1-mesh.yaml")" "$(yq '.admission.readerMaxDuration' "$OB")" "reader cert lifetime == the admission limit (7d)"
  # every fleet file's mesh.group has a root (charts/cluster fails the render otherwise; this names the installation)
  for inst_dir in "$ROOT"/installations/*; do
    [[ -f "$inst_dir/installation.yaml" ]] || continue
    for cf in "$inst_dir"/clusters/*.yaml; do
      g=$(yq '.mesh.group // ""' "$cf")
      [[ -n "$g" ]] || continue
      assert_match "$(yq -o=json -I=0 '.mesh.groups // []' "$inst_dir/installation.yaml")" "\"$g\"" "$(basename "$inst_dir")/$(basename "$cf"): mesh.group $g listed in mesh.groups"
    done
  done
  mesh_net=$(yq 'select(.kind == "Cluster") | .metadata.labels["mesh.platform.koorikla.io/network"]' "$TMP/dev1-mesh.yaml")
  assert_eq "$mesh_net" "dev1" "mesh network label == cluster name"
  assert_match "$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "dev1-mesh-trust") | .spec.target.template.data["mesh-trust.yaml"]' "$TMP/dev1-mesh.yaml")" \
    'topology.istio.io/network: dev1' "istio-system network label == mesh network label"
fi

# 2b3. Invariant 4: no CA private key in any ClusterResourceSet payload or workload-cluster ExternalSecret.
#   ca_key_refs <render>: "<ExternalSecret> <remote key>/<property>" for every private-key property (tls.key, *.key, key)
#   an ExternalSecret reads from a CA Secret (<x>-ca, <x>-cca, ca/root/intermediate-named keys) - must be empty for
#   every CRS payload; client identities (<x>-agent-tls, <x>-mesh-reader) are the only private keys a payload carries.
ca_key_refs() {
  yq -N 'select(.kind == "ExternalSecret") | .metadata.name as $n | .spec.data[]?
    | select((.remoteRef.property // "") | test("(^|\\.)key$|^tls\\.key$"))
    | select(.remoteRef.key | test("(-ca|-cca|root|intermediate|cacerts)$|^pki-"))
    | $n + " " + .remoteRef.key + "/" + .remoteRef.property' "$1" 2>/dev/null | grep -v '^$' || true
}
crs_key_refs() {   # private keys read by CRS payload ExternalSecrets that are not a cluster's own client identity
  yq -N 'select(.kind == "ExternalSecret" and .spec.target.template.type == "addons.cluster.x-k8s.io/resource-set")
    | .metadata.name as $n | .spec.data[]? | select((.remoteRef.property // "") | test("key"))
    | select(.remoteRef.key | test("-(agent-tls|mesh-reader)$") | not)
    | $n + " " + .remoteRef.key + "/" + .remoteRef.property' "$1" 2>/dev/null | grep -v '^$' || true
}
for inst_dir in "$ROOT"/installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf")
    helm template "cluster-$c" "$ROOT/charts/cluster" --namespace fleet --values "$inst_dir/installation.yaml" --values "$cf" \
      > "$TMP/inv4-$c.yaml" 2>/dev/null || continue
    lbl="$(basename "$inst_dir")/$c"
    assert_eq "$(ca_key_refs "$TMP/inv4-$c.yaml")" "" "$lbl: no ExternalSecret reads a CA private key"
    assert_eq "$(crs_key_refs "$TMP/inv4-$c.yaml")" "" "$lbl: CRS payloads carry only the cluster's own client keys"
    payloads=$(yq 'select(.kind == "ExternalSecret" and .spec.target.template.type == "addons.cluster.x-k8s.io/resource-set") | .spec.target.template.data[]' "$TMP/inv4-$c.yaml")
    assert_eq "$(printf '%s\n' "$payloads" | grep -cE 'name: cacerts|ca-key\.pem|PRIVATE KEY' || true)" 0 "$lbl: no CA key Secret (cacerts) in any CRS payload"
  done
done
for addon_dir in "$ROOT"/addons/*; do   # workload-role addons: their ExternalSecrets never read a key of any kind from a CA
  a=$(basename "$addon_dir")
  yq -e ".addons[\"$a\"].roles[] | select(. == \"workload\")" "$PV" >/dev/null 2>&1 || continue
  helm template "$a" "$addon_dir" --namespace x --set-string cluster.role=workload --set-string mesh.group=contract \
    --set-string cluster.name=dev1 > "$TMP/wl-$a.yaml" 2>/dev/null || continue
  assert_eq "$(ca_key_refs "$TMP/wl-$a.yaml")" "" "workload addon $a: no ExternalSecret reads a CA private key"
done
# negative: the checks catch the old design (an intermediate key delivered as cacerts) and a CA key read
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: dev1-mesh-cacerts }\nspec:\n  target:\n    template:\n      type: addons.cluster.x-k8s.io/resource-set\n      data: { x.yaml: "kind: Secret\\nmetadata: { name: cacerts }" }\n  data:\n    - { secretKey: k, remoteRef: { key: dev1-mesh-ca, property: tls.key } }\n' > "$TMP/bad-crs.yaml"
assert_eq "$(ca_key_refs "$TMP/bad-crs.yaml")" "dev1-mesh-cacerts dev1-mesh-ca/tls.key" "negative: contract catches a CA key read"
assert_eq "$(crs_key_refs "$TMP/bad-crs.yaml")" "dev1-mesh-cacerts dev1-mesh-ca/tls.key" "negative: contract catches a CA key in a CRS payload"

# 2b4. OpenBao's member endpoint is published on the local k3d load balancer (loopback on the host), else CAPD members
#      cannot reach the mesh CA through the serverlb (coredns-local).
for inst_file in "$ROOT"/installations/*/installation.yaml; do
  [[ "$(yq '.mgmt.addons.openbao // false' "$inst_file")" == true ]] || continue
  [[ "$(yq '.mgmt.provider // "docker"' "$inst_file")" == docker ]] || continue
  port=$(yq '.mesh.ca.port' "$inst_file")
  assert_eq "$(yq "[.ports[] | select((.port | test(\":$port:$port\$\")) and (.nodeFilters[] == \"loadbalancer\"))] | length" "$ROOT/bootstrap/k3d-mgmt.yaml")" 1 \
    "bootstrap/k3d-mgmt.yaml publishes mesh.ca.port $port on the load balancer ($(basename "$(dirname "$inst_file")"))"
  assert_match "$(yq ".ports[] | select(.port | test(\":$port:$port\$\")) | .port" "$ROOT/bootstrap/k3d-mgmt.yaml")" '^127\.0\.0\.1:' "mesh.ca.port $port bound to loopback only"
done
for f in addons/kyverno-policies/values.yaml addons/kyverno/values.yaml; do   # in Kyverno's scope like harbor
  assert_eq "$(grep -cE '^ *- openbao$' "$ROOT/$f" || true)" 0 "openbao not excluded from Kyverno ($f)"
done
ob_pss=$(yq 'select(.kind == "StatefulSet" or .kind == "Job" or .kind == "CronJob")' "$TMP/openbao.yaml" 2>/dev/null \
  | grep -E 'privileged: true|host(Network|PID|IPC): true|hostPath:|hostPort:|^ *add:' || true)
assert_eq "$ob_pss" "" "OpenBao workloads meet Pod Security baseline"

ia_params=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-istio-ambient") | .spec.template.spec.source.helm.parameters[] | .name + "=" + .value' "$TMP/platform.yaml")
assert_match "$ia_params" 'global.network=\{\{ index .metadata.labels "mesh.platform.koorikla.io/network" \}\}' "istio-ambient network comes from the mesh network label"
assert_match "$ia_params" 'global.meshID=\{\{ index .metadata.labels "mesh.platform.koorikla.io/group" \}\}' "istio-ambient meshID comes from the mesh group label"
assert_match "$ia_params" 'istiod.env.AMBIENT_ENABLE_MULTI_NETWORK=.*addons.platform.koorikla.io/istio-eastwest.*else \}\}false' "ambient multi-network only on istio-eastwest clusters"
assert_match "$ia_params" 'ztunnel.podAnnotations.mesh\\.platform\\.koorikla\\.io/group=\{\{ index .metadata.labels "mesh.platform.koorikla.io/group" \}\}' "a group change rolls ztunnel (pod annotation from the mesh group label)"
assert_match "$ia_params" 'global.multiCluster.clusterName=\{\{ index .metadata.labels "platform.koorikla.io/name" \}\}' "istio clusterName == cluster name"
ia_vf=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-istio-ambient") | .spec.template.spec.source.helm.valueFiles[]' "$TMP/platform.yaml")
assert_match "$ia_vf" 'values/mesh-\{\{ if index .metadata.labels "mesh.platform.koorikla.io/group" \}\}member\{\{ else \}\}none\{\{ end \}\}.yaml' "mesh members get values/mesh-member.yaml"
csr_params=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-istio-csr") | .spec.template.spec.source.helm.parameters[] | .name + "=" + .value' "$TMP/platform.yaml")
assert_match "$csr_params" 'cert-manager-istio-csr.app.server.clusterID=\{\{ index .metadata.labels "platform.koorikla.io/name" \}\}' "istio-csr cluster ID == istio clusterName (cluster name)"
for a in istio-eastwest istio-csr; do
  sel=$(yq "select(.kind == \"ApplicationSet\" and .metadata.name == \"addon-$a\") | .spec.generators[0].clusters.selector.matchExpressions[] | select(.key == \"addons.platform.koorikla.io/$a\") | .operator" "$TMP/platform.yaml")
  assert_eq "$sel" "In" "addon-$a is opt-in by label"
done

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

finish
