#!/usr/bin/env bash
# Multicluster mesh contracts (docs/multicluster.md) across charts/cluster, addon openbao (mesh CA on mgmt) and addon
# mesh: shared names, the mesh CA's member auth and PKI profile, no CA private key in any ClusterResourceSet payload or
# workload ExternalSecret, OpenBao's member endpoint on the k3d load balancer, ambient STRICT mTLS in cells.
# A mismatch here breaks mesh trust only on a live multi-cluster install, which no single-chart test renders.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
# shellcheck source=../lib/portable.sh
source "$ROOT/hack/lib/portable.sh"
# shellcheck source=../lib/addons.sh
source "$ROOT/hack/lib/addons.sh"

helm template platform "$ROOT/charts/platform" --namespace argocd \
  --values "$ROOT/installations/local/installation.yaml" > "$TMP/platform.yaml"

# 1. names shared between charts/cluster, addon openbao (mesh CA on mgmt),
# addon mesh (istio-csr + east-west on members via values/mesh-member.yaml; ambient multi-network driven by the mesh labels).
PV="$ROOT/charts/platform/values.yaml"
OB="$ROOT/addons/openbao/values.yaml"
IC="$ROOT/addons/mesh/values.yaml"
MM="$ROOT/addons/mesh/values/mesh-member.yaml"
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

# 2. Invariant 4: no CA private key in any ClusterResourceSet payload or workload-cluster ExternalSecret.
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

# 3. OpenBao's member endpoint is published on the local k3d load balancer (loopback on the host), else CAPD members
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

# 4. Istio ambient, STRICT mTLS in cell namespaces (#53): while addon kyverno-policies generates STRICT
# PeerAuthentications into the cells (templates/cell-mesh.yaml), ztunnel refuses plaintext there, so every in-cluster
# client of cell pods has to be in the mesh: the data-plane gateway proxy (ingress) and the data-service operators
# (instance / broker / scaler endpoints in cells), and the telemetry Prometheus agent (PodMonitors into cells, #209).
# Only the agent pod of addon telemetry joins (operator --labels; the namespace stays `none`), and docker clusters run
# without ambient DNS capture: ztunnel answers the local installation's *.localhost ingest hosts with loopback, which
# cut every remote write to mgmt on dev1.
if [[ "$(yq '.ambientEnrollment.enabled and .ambientEnrollment.mtls.strict' "$ROOT/addons/kyverno-policies/values.yaml")" == true ]]; then
  render_standalone_addon openchoreo-data-plane "$TMP/mc-odp.yaml"
  gw=$(yq 'select(.kind == "Gateway" and .metadata.name == "gateway-default") | .spec.infrastructure.labels["istio.io/dataplane-mode"]' "$TMP/mc-odp.yaml")
  assert_eq "$gw" ambient "STRICT cells: the data-plane gateway proxy pods are in the ambient mesh"
  render_standalone_addon telemetry "$TMP/mc-telemetry.yaml"
  tl=$(yq 'select(.kind == "Namespace") | .metadata.labels["istio.io/dataplane-mode"]' "$TMP/mc-telemetry.yaml")
  assert_eq "$tl" none "addon telemetry stays out of the ambient mesh (ztunnel DNS resolves *.localhost ingest hosts to loopback)"
  # the agent pod: ambient + the peer label platform-mesh-hbone admits on HBONE 15008 (else the CNI drops the tunnel)
  args=$(yq 'select(.kind == "Deployment") | .spec.template.spec.containers[].args[]' "$TMP/mc-telemetry.yaml" | grep '^--labels=' || true)
  assert_match "$args" '(=|,)istio\.io/dataplane-mode=ambient(,|$)' "STRICT cells: the telemetry Prometheus agent pod is in the ambient mesh"
  helm template kyverno-policies "$ROOT/addons/kyverno-policies" --namespace kyverno > "$TMP/mc-kp.yaml"
  peer=$(yq 'select(.kind == "GeneratingPolicy" and .metadata.name == "openchoreo-cell-hbone") | .spec.generate[0].template.value' "$TMP/mc-kp.yaml" \
    | yq '.spec.ingress[0].from[] | select(.namespaceSelector) | .podSelector.matchExpressions[0].key')
  assert_match "$args" "(=|,)$peer=[a-z-]+(,|\$)" "STRICT cells: the agent pod carries the HBONE peer label ($peer) of platform-mesh-hbone"
  render_platform local "$TMP/mc-platform.yaml"
  render_layered_addon local mesh "$TMP/mc-mesh-dev1.yaml" "$TMP/mc-platform.yaml" workload dev1 docker development local \
    cilium https://192.0.2.10:6443
  if [[ "$(yq '.openchoreo.controlPlane.host' "$ROOT/installations/local/installation.yaml")" == *.localhost ]]; then
    assert_eq "$(yq 'select(.kind == "ConfigMap" and .metadata.name == "istio-cni-config") | .data.AMBIENT_DNS_CAPTURE' "$TMP/mc-mesh-dev1.yaml")" \
      false "local dev1: no ambient DNS capture (ztunnel would resolve the *.localhost remote-write host to loopback)"
  fi
  for a in cloudnative-pg keda strimzi; do
    render_standalone_addon "$a" "$TMP/mc-$a.yaml"
    ns=$(yq ".addons[\"$a\"].namespace" "$ROOT/charts/platform/values.yaml")
    l=$(yq "select(.kind == \"Namespace\" and .metadata.name == \"$ns\") | .metadata.labels[\"istio.io/dataplane-mode\"]" "$TMP/mc-$a.yaml")
    assert_eq "$l" ambient "STRICT cells: addon $a (namespace $ns) reaches cell pods from inside the mesh"
  done
fi

finish
