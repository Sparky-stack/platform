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
# addon mesh (istio-csr + east-west on members via values/mesh-member.yaml; ambient multi-network driven by the mesh labels).
PV="$ROOT/charts/platform/values.yaml"
OB="$ROOT/addons/openbao/values.yaml"
IC="$ROOT/addons/mesh/values.yaml"
MM="$ROOT/addons/mesh/values/mesh-member.yaml"
if [[ -f "$ROOT/charts/cluster/templates/capi-cluster.yaml" ]]; then
  helm template cluster-dev1 "$ROOT/charts/cluster" --namespace fleet \
    --values "$ROOT/installations/local/installation.yaml" --values "$ROOT/installations/local/clusters/dev1.yaml" \
    --set mesh.group=contract --set 'mesh.groups={contract}' --set mgmt.addons.openbao=true > "$TMP/dev1-mesh.yaml"
  helm template openbao "$ROOT/addons/openbao" --namespace openbao --values "$ROOT/installations/local/installation.yaml" \
    --set 'mesh.groups={contract}' > "$TMP/openbao.yaml"
  helm template mesh "$ROOT/addons/mesh" --namespace istio-system --values "$MM" \
    --values "$ROOT/installations/local/installation.yaml" --set-string mesh.group=contract --set-string cluster.name=dev1 \
    > "$TMP/mesh-member.yaml"
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
  iss() { yq "select(.kind == \"Issuer\" and .metadata.name == \"$(yq '.issuer.name' "$IC")\") | $1" "$TMP/mesh-member.yaml"; }
  ic_ns=$(yq '.addons["mesh"].namespace' "$PV")
  assert_eq "$(yq '.memberAuth.audience' "$OB")" "vault://$ic_ns/$(yq '.issuer.name' "$IC")" "OpenBao accepts exactly cert-manager's issuer audience (vault://<ns>/<issuer>)"
  assert_eq "$(yq '.memberAuth.serviceAccount' "$OB")" "$ic_ns:$(yq '.issuer.serviceAccount' "$IC")" "OpenBao binds the istio-csr issuer's ServiceAccount"
  assert_eq "$(iss .spec.vault.auth.kubernetes.role)" "$(yq '.memberAuth.role' "$OB")" "Vault Issuer role == OpenBao member role"
  assert_eq "$(iss .spec.vault.auth.kubernetes.mountPath)" "/v1/auth/mesh-dev1" "Vault Issuer logs in at auth/mesh-<cluster>"
  assert_eq "$(iss .spec.vault.path)" "pki-mesh-contract-int/sign/dev1" "Vault Issuer signs at pki-mesh-<group>-int/sign/<cluster>"
  RS="$ROOT/addons/openbao/files/mesh-reconcile.sh"
  # shellcheck disable=SC2016  # literal script text ($c, $g, $int) matched in mesh-reconcile.sh
  assert_match "$(cat "$RS")" 'auth enable -path="mesh-\$c"' "the reconcile creates auth/mesh-<cluster>"
  # shellcheck disable=SC2016
  assert_match "$(cat "$RS")" 'int="pki-mesh-\$g-int"' "the reconcile names the group intermediate pki-mesh-<group>-int"
  # shellcheck disable=SC2016
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
  assert_eq "$(yq '.ztunnel.caAddress' "$MM")" "cert-manager-istio-csr.$ic_ns.svc:443" "ztunnel's CA is istio-csr's Service"
  assert_eq "$(yq '.istiod.env.ENABLE_CA_SERVER' "$MM")" "false" "istiod runs no CA on mesh members"
  # reader identity (remote secrets) shared by charts/cluster, addon mesh (east-west reader RBAC) and the admission guard
  reader_cn=$(yq 'select(.kind == "Certificate" and .metadata.name == "dev1-mesh-reader") | .spec.commonName' "$TMP/dev1-mesh.yaml")
  assert_eq "$reader_cn" "$(yq '.reader.user' "$IC")" "remote-secret client cert CN == user addon mesh binds"
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
  # owner decision (docs/multicluster.md "Reader RBAC"): no installation opts peers into reading Secrets
  assert_eq "$(yq '.reader.remoteCredentialsSecrets' "$IC")" false "mesh reader.remoteCredentialsSecrets defaults to false"
  secrets_optin=""
  while IFS= read -r f; do
    if [[ "$(yq '.reader.remoteCredentialsSecrets // false' "$f" 2>/dev/null)" != false ]]; then secrets_optin="$secrets_optin ${f#"$ROOT"/}"; fi
  done < <(find "$ROOT/installations" -path '*/addons/mesh/*.yaml' -type f)
  assert_eq "$secrets_optin" "" "no installation enables mesh reader.remoteCredentialsSecrets"
  # issuer discovery (OpenBao fetches the member's JWKS anonymously): delivered by the member's CRS from a static
  # ConfigMap (exists before the mesh reconcile), exactly one binding of the read-only discovery role, single owner
  oidc=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "dev1-mesh-oidc") | .data["oidc-discovery.yaml"]' "$TMP/dev1-mesh.yaml")
  assert_eq "$(printf '%s\n' "$oidc" | yq -N '.kind + " " + .roleRef.kind + "/" + .roleRef.name')" \
    "ClusterRoleBinding ClusterRole/system:service-account-issuer-discovery" "member CRS binds only the read-only issuer-discovery role"
  assert_eq "$(printf '%s\n' "$oidc" | yq -o=json -I=0 '.subjects')" '[{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"system:unauthenticated"}]' \
    "issuer discovery is the only thing granted to system:unauthenticated"
  assert_match "$(yq -o=json -I=0 'select(.kind == "ClusterResourceSet" and .metadata.name == "dev1-mesh-trust") | .spec.resources' "$TMP/dev1-mesh.yaml")" \
    '"kind":"ConfigMap","name":"dev1-mesh-oidc"' "the mesh-trust CRS applies the issuer-discovery ConfigMap"
  # one owner: the CRS, never an addon synced after the reconcile
  helm template mesh "$ROOT/addons/mesh" --namespace istio-system --values "$MM" --set-string mesh.group=contract --set-string cluster.name=dev1 \
    2>/dev/null > "$TMP/oidc-mesh.yaml" || true
  assert_eq "$(yq 'select(.kind == "ClusterRoleBinding" and .roleRef.name == "system:service-account-issuer-discovery") | .metadata.name' "$TMP/oidc-mesh.yaml")" "" \
    "negative: addon mesh does not (also) bind issuer discovery"
  mesh_net=$(yq 'select(.kind == "Cluster") | .metadata.labels["mesh.platform.koorikla.io/network"]' "$TMP/dev1-mesh.yaml")
  assert_eq "$mesh_net" "dev1" "mesh network label == cluster name"
  assert_match "$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "dev1-mesh-trust") | .spec.target.template.data["mesh-trust.yaml"]' "$TMP/dev1-mesh.yaml")" \
    'topology.istio.io/network: dev1' "istio-system network label == mesh network label"
fi

# 2b3. Invariant 4: no CA private key in any ClusterResourceSet payload or workload-cluster ExternalSecret.
#   ca_key_refs <render>: "<ExternalSecret> <remote key>/<property>" for every private-key property (tls.key, *.key, key)
#   an ExternalSecret reads from a CA Secret (<x>-ca, <x>-cca, ca/root/intermediate-named keys) - must be empty for
#   every CRS payload; client identities (<x>-agent-tls, <x>-mesh-reader) are the only private keys a payload carries.
#   Both also cover spec.dataFrom: extract of a CA Secret pulls every property including the key ("<key>/*"), and any
#   find (by name regexp, path or tags) can match a CA Secret, so a find in these ExternalSecrets is always reported.
CA_KEY_RE='(-ca|-cca|root|intermediate|cacerts)$|^pki-'
ca_key_refs() {
  # shellcheck disable=SC2016  # yq variables ($n), not shell
  yq -N 'select(.kind == "ExternalSecret") | .metadata.name as $n | (
      (.spec.data[]?
        | select((.remoteRef.property // "") | test("(^|\\.)key$|^tls\\.key$"))
        | select(.remoteRef.key | test("'"$CA_KEY_RE"'"))
        | $n + " " + .remoteRef.key + "/" + .remoteRef.property),
      (.spec.dataFrom[]? | select(.extract) | select(.extract.key | test("'"$CA_KEY_RE"'"))
        | $n + " " + .extract.key + "/" + (.extract.property // "*")),
      (.spec.dataFrom[]? | select(.find) | $n + " find:" + (.find | tojson(0))))' "$1" 2>/dev/null | grep -v '^$' || true
}
crs_key_refs() {   # private keys read by CRS payload ExternalSecrets that are not a cluster's own client identity
  # shellcheck disable=SC2016  # yq variables ($n), not shell
  yq -N 'select(.kind == "ExternalSecret" and .spec.target.template.type == "addons.cluster.x-k8s.io/resource-set")
    | .metadata.name as $n | (
      (.spec.data[]? | select((.remoteRef.property // "") | test("key"))
        | select(.remoteRef.key | test("-(agent-tls|mesh-reader)$") | not)
        | $n + " " + .remoteRef.key + "/" + .remoteRef.property),
      (.spec.dataFrom[]? | select(.extract)
        | select(.extract.key | test("-(agent-tls|mesh-reader)$") | not)
        | select((.extract.key | test("'"$CA_KEY_RE"'|tls|key")) or ((.extract.property // "") | test("key")))
        | $n + " " + .extract.key + "/" + (.extract.property // "*")),
      (.spec.dataFrom[]? | select(.find) | $n + " find:" + (.find | tojson(0))))' "$1" 2>/dev/null | grep -v '^$' || true
}
render_fail() {   # a render that fails is a contract failure, never a skipped check
  FAIL=$((FAIL + 1)); printf '  FAIL: %s does not render: %s\n' "$1" "$(head -c 300 "$2")" >&2
}
for inst_dir in "$ROOT"/installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq '.name' "$cf")
    lbl="$(basename "$inst_dir")/$c"
    if ! helm template "cluster-$c" "$ROOT/charts/cluster" --namespace fleet --values "$inst_dir/installation.yaml" --values "$cf" \
      > "$TMP/inv4-$c.yaml" 2> "$TMP/inv4-$c.err"; then
      render_fail "$lbl (charts/cluster)" "$TMP/inv4-$c.err"; continue
    fi
    assert_eq "$(ca_key_refs "$TMP/inv4-$c.yaml")" "" "$lbl: no ExternalSecret reads a CA private key"
    assert_eq "$(crs_key_refs "$TMP/inv4-$c.yaml")" "" "$lbl: CRS payloads carry only the cluster's own client keys"
    payloads=$(yq 'select(.kind == "ExternalSecret" and .spec.target.template.type == "addons.cluster.x-k8s.io/resource-set") | .spec.target.template.data[]' "$TMP/inv4-$c.yaml")
    assert_eq "$(printf '%s\n' "$payloads" | grep -cE 'name: cacerts|ca-key\.pem|PRIVATE KEY' || true)" 0 "$lbl: no CA key Secret (cacerts) in any CRS payload"
  done
done
for addon_dir in "$ROOT"/addons/*; do   # workload-role addons: their ExternalSecrets never read a key of any kind from a CA
  a=$(basename "$addon_dir")
  yq -e ".addons[\"$a\"].roles[] | select(. == \"workload\")" "$PV" >/dev/null 2>&1 || continue
  # the per-cluster parameters the addon ApplicationSet passes (clusterServerParameters, planeID == cluster name)
  if ! helm template "$a" "$addon_dir" --namespace x --set-string cluster.role=workload --set-string mesh.group=contract \
    --set-string cluster.name=dev1 --set-string cilium.k8sServiceHost=dev1.example.test \
    --set-string openchoreo-data-plane.clusterAgent.planeID=dev1 > "$TMP/wl-$a.yaml" 2> "$TMP/wl-$a.err"; then
    render_fail "workload addon $a" "$TMP/wl-$a.err"; continue
  fi
  assert_eq "$(ca_key_refs "$TMP/wl-$a.yaml")" "" "workload addon $a: no ExternalSecret reads a CA private key"
done
# negative: the checks catch the old design (an intermediate key delivered as cacerts) and a CA key read - through
# spec.data, through dataFrom.extract (whole CA Secret) and through dataFrom.find
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: dev1-mesh-cacerts }\nspec:\n  target:\n    template:\n      type: addons.cluster.x-k8s.io/resource-set\n      data: { x.yaml: "kind: Secret\\nmetadata: { name: cacerts }" }\n  data:\n    - { secretKey: k, remoteRef: { key: dev1-mesh-ca, property: tls.key } }\n' > "$TMP/bad-crs.yaml"
assert_eq "$(ca_key_refs "$TMP/bad-crs.yaml")" "dev1-mesh-cacerts dev1-mesh-ca/tls.key" "negative: contract catches a CA key read"
assert_eq "$(crs_key_refs "$TMP/bad-crs.yaml")" "dev1-mesh-cacerts dev1-mesh-ca/tls.key" "negative: contract catches a CA key in a CRS payload"
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: dev1-x }\nspec:\n  target:\n    template:\n      type: addons.cluster.x-k8s.io/resource-set\n  dataFrom:\n    - { extract: { key: dev1-mesh-ca } }\n' > "$TMP/bad-extract.yaml"
assert_eq "$(ca_key_refs "$TMP/bad-extract.yaml")" "dev1-x dev1-mesh-ca/*" "negative: contract catches dataFrom.extract of a CA Secret"
assert_eq "$(crs_key_refs "$TMP/bad-extract.yaml")" "dev1-x dev1-mesh-ca/*" "negative: contract catches dataFrom.extract of a CA Secret in a CRS payload"
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: dev1-y }\nspec:\n  target:\n    template:\n      type: addons.cluster.x-k8s.io/resource-set\n  dataFrom:\n    - { find: { name: { regexp: "^dev1-.*" } } }\n' > "$TMP/bad-find.yaml"
assert_eq "$(ca_key_refs "$TMP/bad-find.yaml")" 'dev1-y find:{"name":{"regexp":"^dev1-.*"}}' "negative: contract reports dataFrom.find (may match a CA Secret)"
assert_eq "$(crs_key_refs "$TMP/bad-find.yaml")" 'dev1-y find:{"name":{"regexp":"^dev1-.*"}}' "negative: contract reports dataFrom.find in a CRS payload"
printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: dev1-seed-ok }\nspec:\n  target:\n    template:\n      type: addons.cluster.x-k8s.io/resource-set\n  dataFrom:\n    - { extract: { key: falco-webhook } }\n    - { extract: { key: dev1-mesh-reader } }\n' > "$TMP/ok-extract.yaml"
assert_eq "$(crs_key_refs "$TMP/ok-extract.yaml")$(ca_key_refs "$TMP/ok-extract.yaml")" "" "positive control: credential seeds and the cluster's own client identity pass"
# negative: a cluster that fails to render is a failure, not a skip
fails_before=$FAIL
render_fail "negative-control" <(echo "simulated render error") 2>/dev/null
assert_eq "$((FAIL - fails_before))" 1 "negative: a render failure counts as a contract failure"; FAIL=$fails_before

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

ia_params=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-mesh") | .spec.template.spec.source.helm.parameters[] | .name + "=" + .value' "$TMP/platform.yaml")
assert_match "$ia_params" 'global.network=\{\{ index .metadata.labels "mesh.platform.koorikla.io/network" \}\}' "mesh network comes from the mesh network label"
assert_match "$ia_params" 'global.meshID=\{\{ index .metadata.labels "mesh.platform.koorikla.io/group" \}\}' "mesh meshID comes from the mesh group label"
assert_eq "$(yq '.istiod.env.AMBIENT_ENABLE_MULTI_NETWORK' "$ROOT/addons/mesh/values.yaml"):$(yq '.istiod.env.AMBIENT_ENABLE_MULTI_NETWORK' "$ROOT/addons/mesh/values/mesh-member.yaml")" "false:true" "ambient multi-network only on mesh members"
assert_match "$ia_params" 'ztunnel.podAnnotations.mesh\\.platform\\.koorikla\\.io/group=\{\{ index .metadata.labels "mesh.platform.koorikla.io/group" \}\}' "a group change rolls ztunnel (pod annotation from the mesh group label)"
assert_match "$ia_params" 'global.multiCluster.clusterName=\{\{ index .metadata.labels "platform.koorikla.io/name" \}\}' "istio clusterName == cluster name"
ia_vf=$(yq 'select(.kind == "ApplicationSet" and .metadata.name == "addon-mesh") | .spec.template.spec.source.helm.valueFiles[]' "$TMP/platform.yaml")
assert_match "$ia_vf" 'values/mesh-\{\{ if index .metadata.labels "mesh.platform.koorikla.io/group" \}\}member\{\{ else \}\}none\{\{ end \}\}.yaml' "mesh members get values/mesh-member.yaml"
assert_match "$ia_params" 'cert-manager-istio-csr.app.server.clusterID=\{\{ index .metadata.labels "platform.koorikla.io/name" \}\}' "istio-csr cluster ID == istio clusterName (cluster name)"
assert_eq "$(yq '(.mesh.csr.enabled|tostring) + ":" + (.mesh.eastwest.enabled|tostring)' "$ROOT/addons/mesh/values.yaml")" "false:false" "istio-csr and east-west are off by default"
assert_eq "$(yq '(.mesh.csr.enabled|tostring) + ":" + (.mesh.eastwest.enabled|tostring)' "$ROOT/addons/mesh/values/mesh-member.yaml")" "true:true" "mesh members turn istio-csr and east-west on"

# 2b5. Istio ambient, STRICT mTLS in cell namespaces (#53): while addon kyverno-policies generates STRICT
# PeerAuthentications into the cells (templates/cell-mesh.yaml), ztunnel refuses plaintext there, so every in-cluster
# client of cell pods has to be in the mesh: the data-plane gateway proxy (ingress) and the data-service operators
# (instance / broker / scaler endpoints in cells). Addon telemetry must stay out: ztunnel's DNS proxy answers the local
# installation's *.localhost ingest hosts with loopback, which cut every remote write to mgmt on dev1.
if [[ "$(yq '.ambientEnrollment.enabled and .ambientEnrollment.mtls.strict' "$ROOT/addons/kyverno-policies/values.yaml")" == true ]]; then
  render_standalone_addon openchoreo-data-plane "$TMP/mc-odp.yaml"
  gw=$(yq 'select(.kind == "Gateway" and .metadata.name == "gateway-default") | .spec.infrastructure.labels["istio.io/dataplane-mode"]' "$TMP/mc-odp.yaml")
  assert_eq "$gw" ambient "STRICT cells: the data-plane gateway proxy pods are in the ambient mesh"
  render_standalone_addon telemetry "$TMP/mc-telemetry.yaml"
  tl=$(yq 'select(.kind == "Namespace") | .metadata.labels["istio.io/dataplane-mode"]' "$TMP/mc-telemetry.yaml")
  assert_eq "$tl" none "addon telemetry stays out of the ambient mesh (ztunnel DNS resolves *.localhost ingest hosts to loopback)"
  for a in cloudnative-pg keda strimzi; do
    render_standalone_addon "$a" "$TMP/mc-$a.yaml"
    ns=$(yq ".addons[\"$a\"].namespace" "$ROOT/charts/platform/values.yaml")
    l=$(yq "select(.kind == \"Namespace\" and .metadata.name == \"$ns\") | .metadata.labels[\"istio.io/dataplane-mode\"]" "$TMP/mc-$a.yaml")
    assert_eq "$l" ambient "STRICT cells: addon $a (namespace $ns) reaches cell pods from inside the mesh"
  done
fi

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

# 9c. reloader (#50) is NOT a Kyverno-excluded platform namespace, meets Pod Security restricted with no ClusterRole,
#     watches openchoreo-data-plane, and cluster-agent's Reloader annotations match the CRS-delivered Secret/ConfigMap.
for f in addons/kyverno-policies/values.yaml addons/kyverno/values.yaml; do
  assert_eq "$(grep -cE '^ *- reloader( |$)' "$ROOT/$f" || true)" 0 "reloader not excluded from Kyverno ($f)"
done
rel_ns=$(yq '.addons.reloader.namespace' "$PV")
dp_ns=$(yq '.addons["openchoreo-data-plane"].namespace' "$PV")
helm template reloader "$ROOT/addons/reloader" --namespace "$rel_ns" > "$TMP/reloader-pss.yaml"
rel_pod='select(.kind == "Deployment") | .spec.template.spec'
assert_eq "$(yq "$rel_pod | .securityContext.runAsNonRoot" "$TMP/reloader-pss.yaml")" true "reloader pod runAsNonRoot"
assert_eq "$(yq "$rel_pod | .securityContext.seccompProfile.type" "$TMP/reloader-pss.yaml")" RuntimeDefault "reloader seccomp RuntimeDefault"
assert_eq "$(yq "$rel_pod | .containers[0].securityContext.allowPrivilegeEscalation" "$TMP/reloader-pss.yaml")" false "reloader no privilege escalation"
assert_eq "$(yq "$rel_pod | .containers[0].securityContext.readOnlyRootFilesystem" "$TMP/reloader-pss.yaml")" true "reloader readOnlyRootFilesystem"
assert_eq "$(yq -o=json -I=0 "$rel_pod | .containers[0].securityContext.capabilities.drop" "$TMP/reloader-pss.yaml")" '["ALL"]' "reloader drops ALL capabilities"
assert_eq "$(yq 'select(.kind == "ClusterRole" or .kind == "ClusterRoleBinding") | .metadata.name' "$TMP/reloader-pss.yaml")" "" "reloader renders no ClusterRole or ClusterRoleBinding"
assert_eq "$(NS="$dp_ns" yq 'select(.kind == "Role" and .metadata.namespace == strenv(NS)) | .metadata.name' "$TMP/reloader-pss.yaml")" reloader-role "reloader grants a Role in $dp_ns"
helm template openchoreo-control-plane "$ROOT/addons/openchoreo-control-plane" --namespace openchoreo-control-plane \
  -s templates/gateway-ca-crs.yaml > "$TMP/gw-ca-crs.yaml"
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
helm template platform "$ROOT/charts/platform" --namespace argocd -s templates/projects.yaml > "$TMP/pv-projects.yaml"
pv_kinds=$(yq 'select(.metadata.name == "previews") | .spec.namespaceResourceWhitelist[] | .group + "/" + .kind' \
  "$TMP/pv-projects.yaml" | sort | tr '\n' ' ')
helm template p "$ROOT/charts/preview" --set project=demo,component=hello-world,pullRequest=7 \
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

finish
