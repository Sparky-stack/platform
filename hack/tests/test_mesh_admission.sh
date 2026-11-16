#!/usr/bin/env bash
# Mesh admission guards, evaluated offline with the kyverno CLI (CEL, same expression language as the API server):
#   mgmt    addon openbao templates/mesh-admission.yaml: what charts/cluster renders for the remote-secret reader certs
#           is admitted; everything that would turn a <name>-client-ca issuer into a general signing API is denied
#   members addon istio-csr templates/admission.yaml: only istio-csr / cert-manager may ask the mesh CA (OpenBao) for
#           certificates, only istiod's Certificate may reference it, never a CA, and no second Vault Issuer may obtain
#           a token the mesh CA accepts (ServiceAccount istio-csr-openbao / audience vault://istio-system/openbao-mesh)
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_mesh_admission =="
if ! command -v kyverno >/dev/null 2>&1; then
  echo "  SKIP: kyverno CLI not installed (mise install)"
  exit 0
fi
cd "$ROOT"

ARGO=system:serviceaccount:argocd:argocd-application-controller
CM=system:serviceaccount:cert-manager:cert-manager

{
  helm template openbao addons/openbao --namespace openbao --set 'mesh.groups={local}' -s templates/mesh-admission.yaml
  echo '---'
  helm template istio-csr addons/istio-csr --namespace istio-system --set-string mesh.group=local \
    --set-string cluster.name=dev1 -s templates/admission.yaml
} > "$TMP/mrc.yaml"
helm template cert-manager addons/cert-manager --namespace cert-manager \
  | yq 'select(.kind == "CustomResourceDefinition" and .spec.group == "cert-manager.io")' > "$TMP/crds.yaml"
{ echo '---'; helm template external-secrets addons/external-secrets --namespace external-secrets \
  | yq 'select(.kind == "CustomResourceDefinition" and .metadata.name == "externalsecrets.external-secrets.io")'; } >> "$TMP/crds.yaml"
for p in $(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$TMP/mrc.yaml"); do
  yq "select(.metadata.name == \"$p\" and .kind == \"ValidatingAdmissionPolicy\")" "$TMP/mrc.yaml" > "$TMP/policy-$p.yaml"
  b=$(yq -N "select(.kind == \"ValidatingAdmissionPolicyBinding\" and .spec.policyName == \"$p\") | .spec.validationActions[]" "$TMP/mrc.yaml")
  assert_eq "$b" "Deny" "binding for $p denies"
done
assert_eq "$(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$TMP/mrc.yaml" | sort | tr '\n' ' ')" \
  "platform-mesh-ca-certificates platform-mesh-ca-issuers platform-mesh-ca-requests platform-mesh-certificaterequests platform-mesh-issuers platform-mesh-reader-certificates platform-openbao-fleet-reads " \
  "exactly the reader-cert guards (mgmt) and the mesh-CA guards (members)"

user_file() {   # user_file <username> -> path of a kyverno CLI UserInfo file
  local f="$TMP/user-${1//[^a-zA-Z0-9]/_}.yaml"
  printf 'apiVersion: cli.kyverno.io/v1alpha1\nkind: UserInfo\nmetadata: { name: u }\nuserInfo:\n  username: %s\n' "$1" > "$f"
  printf '%s' "$f"
}

# check <policy> <user> <pass|fail|skip> <label> < resource-yaml. Runs at the end of a pipe (subshell), so results go
# to a file and are asserted in the main shell (tally).
check() {
  local policy=$1 user=$2 want=$3 label=$4 res="$TMP/res.yaml" out got
  cat > "$res"
  out=$(kyverno apply "$TMP/policy-$policy.yaml" --resource "$res" --userinfo "$(user_file "$user")" \
    --crd-paths "$TMP/crds.yaml" 2>&1 || true)
  got=$(printf '%s\n' "$out" | sed -n 's/^pass: \([0-9]*\), fail: \([0-9]*\), warn: [0-9]*, error: \([0-9]*\), skip: \([0-9]*\).*/p\1 f\2 e\3 s\4/p')
  case "$got" in
    "p1 f0 e0 s0") got=pass ;;
    "p0 f1 e0 s0") got=fail ;;
    "p0 f0 e0 s1"|"p0 f0 e0 s0") got=skip ;;
    *) got="unexpected: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" ;;
  esac
  printf '%s\t%s\t%s\n' "$got" "$want" "$policy: $label" >> "$TMP/results"
}
tally() {
  local got want label
  while IFS=$'\t' read -r got want label; do assert_eq "$got" "$want" "$label"; done < "$TMP/results"
  : > "$TMP/results"
}
: > "$TMP/results"

reader() {   # reader <extra spec yaml (indented 2)> [namespace]
  printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: dev1-mesh-reader, namespace: %s }\nspec:\n  secretName: dev1-mesh-reader\n  issuerRef: { kind: Issuer, name: dev1-client-ca }\n%s\n' "${2:-fleet}" "$1"
}
R_OK='  commonName: platform:istio-reader
  duration: 168h
  usages: [client auth, digital signature]'
P=platform-mesh-reader-certificates
reader "$R_OK" | check $P alice pass "the reader cert charts/cluster renders"
reader '  commonName: kubernetes-admin
  subject: { organizations: ["system:masters"] }
  duration: 168h
  usages: [client auth, digital signature]' | check $P alice fail "negative: O=system:masters (cluster-admin)"
reader '  commonName: "system:node:dev1-cp"
  duration: 168h
  usages: [client auth, digital signature]' | check $P alice fail "negative: CN other than the reader user"
reader "$R_OK
  subject: { organizationalUnits: [x] }" | check $P alice fail "negative: any subject (OU)"
reader "$R_OK
  isCA: true" | check $P alice fail "negative: isCA (sub-CA the API server would chain)"
reader '  commonName: platform:istio-reader
  duration: 2160h
  usages: [client auth, digital signature]' | check $P alice fail "negative: duration > 168h"
reader '  commonName: platform:istio-reader
  usages: [client auth, digital signature]' | check $P alice fail "negative: no duration (cert-manager default 90d)"
reader '  commonName: platform:istio-reader
  duration: 168h
  usages: [server auth, client auth]' | check $P alice fail "negative: server auth usage"
reader "$R_OK
  dnsNames: [evil.example]" | check $P alice fail "negative: SANs"
reader "$R_OK" default | check $P alice fail "negative: outside fleet"
printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: web, namespace: default }\nspec:\n  secretName: web\n  dnsNames: [web.example]\n  issuerRef: { kind: ClusterIssuer, name: letsencrypt }\n' \
  | check $P alice skip "other issuers are not affected"

cr() {   # cr <issuer kind> <issuer name> <extra spec yaml> [namespace]
  printf 'apiVersion: cert-manager.io/v1\nkind: CertificateRequest\nmetadata: { name: x-1, namespace: %s }\nspec:\n  request: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURSBSRVFVRVNULS0tLS0K\n  issuerRef: { group: cert-manager.io, kind: %s, name: %s }\n%s\n' "${4:-fleet}" "$1" "$2" "$3"
}
P=platform-mesh-certificaterequests
cr Issuer dev1-client-ca '  duration: 168h
  usages: [client auth, digital signature]' | check $P "$CM" pass "reader request from cert-manager"
cr Issuer dev1-client-ca '  duration: 168h
  usages: [client auth, digital signature]' | check $P alice fail "negative: hand-made request (CSR subject unchecked by CEL)"
cr Issuer dev1-client-ca '  isCA: true
  duration: 168h
  usages: [client auth, digital signature]' | check $P "$CM" fail "negative: CA request on a client CA"
cr Issuer dev1-client-ca '  duration: 2160h
  usages: [client auth, digital signature]' | check $P "$CM" fail "negative: reader request > 168h"
cr Issuer dev1-client-ca '  duration: 168h
  usages: [client auth, digital signature]' default | check $P "$CM" fail "negative: reader request outside fleet"
cr ClusterIssuer letsencrypt '  duration: 2160h
  usages: [server auth]' default | check $P alice skip "other issuers are not affected"

P=platform-mesh-issuers
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: dev1-client-ca, namespace: fleet }\nspec:\n  ca: { secretName: dev1-cca }\n' \
  | check $P "$ARGO" pass "Issuer fleet/<x>-client-ca over <x>-cca"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: mine, namespace: fleet }\nspec:\n  ca: { secretName: dev1-cca }\n' \
  | check $P alice fail "negative: second issuer over a CAPI client CA"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: dev1-client-ca, namespace: fleet }\nspec:\n  ca: { secretName: prod1-cca }\n' \
  | check $P alice fail "negative: client-ca issuer over another cluster's CA"
printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata: { name: dev1-client-ca }\nspec:\n  ca: { secretName: dev1-cca }\n' \
  | check $P alice fail "negative: ClusterIssuer over a CAPI client CA"
printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata: { name: selfsigned }\nspec:\n  selfSigned: {}\n' \
  | check $P alice skip "unrelated issuers are not affected"

# --- mgmt: what the openbao namespace may read through store mgmt-fleet (fleet also holds kubeconfigs, client CA keys)
P=platform-openbao-fleet-reads
helm template openbao addons/openbao --namespace openbao --set 'mesh.groups={local}' -s templates/mesh-clients.yaml \
  | check $P "$ARGO" pass "the chart's mesh-clients (find by label)"
es() {   # es <name> <spec-body> [namespace]
  printf 'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: { name: %s, namespace: %s }\nspec:\n  secretStoreRef: { kind: ClusterSecretStore, name: mgmt-fleet }\n  target: { name: x }\n%s\n' "$1" "${3:-openbao}" "$2"
}
es mesh-clients '  data: [{ secretKey: k, remoteRef: { key: dev1-kubeconfig, property: value } }]' | check $P "$ARGO" fail "negative: reads a kubeconfig by key"
es mesh-clients '  dataFrom: [{ extract: { key: dev1-cca } }]' | check $P "$ARGO" fail "negative: extracts the k3s client CA"
es mesh-clients '  dataFrom: [{ find: { name: { regexp: ".*" } } }]' | check $P "$ARGO" fail "negative: finds every Secret by name"
es mesh-clients '  dataFrom: [{ find: { tags: { cluster.x-k8s.io/cluster-name: dev1 } } }]' | check $P "$ARGO" fail "negative: finds by another label"
es loot '  dataFrom: [{ find: { tags: { mesh.platform.koorikla.io/openbao-client: "true" } } }]' | check $P "$ARGO" fail "negative: another ExternalSecret name"
es x '  data: [{ secretKey: k, remoteRef: { key: dev1-kubeconfig, property: value } }]' fleet | check $P "$ARGO" skip "other namespaces are not affected"

# --- members: who may use the mesh CA (Vault Issuer istio-system/openbao-mesh) ---------------------------------------
CSR=system:serviceaccount:istio-system:cert-manager-istio-csr
P=platform-mesh-ca-requests
cr Issuer openbao-mesh '  duration: 24h
  uris: []' istio-system | check $P "$CSR" pass "workload request from istio-csr"
cr Issuer openbao-mesh '  duration: 48h' istio-system | check $P "$CM" pass "istiod Certificate request from cert-manager"
cr Issuer openbao-mesh '  duration: 24h' istio-system | check $P alice fail "negative: hand-made request (any SPIFFE ID the role allows)"
cr Issuer openbao-mesh '  duration: 24h' default | check $P system:serviceaccount:default:app fail "negative: request from a workload ServiceAccount"
cr Issuer openbao-mesh '  isCA: true
  duration: 24h' istio-system | check $P "$CSR" fail "negative: CA request"
cr Issuer letsencrypt '  duration: 24h' istio-system | check $P alice skip "other issuers are not affected"
P=platform-mesh-ca-certificates
helm template istio-csr addons/istio-csr --namespace istio-system --set-string mesh.group=local --set-string cluster.name=dev1 \
  | yq 'select(.kind == "Certificate" and .metadata.name == "istiod")' | check $P "$ARGO" pass "the chart's istiod Certificate"
printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: impostor, namespace: istio-system }\nspec:\n  secretName: impostor\n  uris: [spiffe://cluster.local/ns/prod/sa/payments]\n  issuerRef: { kind: Issuer, name: openbao-mesh }\n' \
  | check $P alice fail "negative: another Certificate minting a SPIFFE identity"
printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: istiod, namespace: default }\nspec:\n  secretName: x\n  issuerRef: { kind: Issuer, name: openbao-mesh }\n' \
  | check $P alice fail "negative: istiod name outside istio-system"
printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: istiod, namespace: istio-system }\nspec:\n  secretName: istiod-tls\n  isCA: true\n  issuerRef: { kind: Issuer, name: openbao-mesh }\n' \
  | check $P "$ARGO" fail "negative: CA Certificate"

P=platform-mesh-ca-issuers
vault_issuer() {   # vault_issuer <kind> <name> <namespace|""> <serviceAccountRef yaml (flow)>
  local md="{ name: $2 }"; [[ -n "$3" ]] && md="{ name: $2, namespace: $3 }"
  printf 'apiVersion: cert-manager.io/v1\nkind: %s\nmetadata: %s\nspec:\n  vault:\n    server: https://openbao.example:8200\n    path: pki-mesh-local-int/sign/dev1\n    auth:\n      kubernetes:\n        mountPath: /v1/auth/mesh-dev1\n        role: istio-csr\n        serviceAccountRef: %s\n' "$1" "$md" "$4"
}
helm template istio-csr addons/istio-csr --namespace istio-system --set-string mesh.group=local --set-string cluster.name=dev1 \
  | yq 'select(.kind == "Issuer" and .metadata.name == "openbao-mesh")' | check $P "$ARGO" pass "the chart's Issuer openbao-mesh"
vault_issuer Issuer bypass istio-system '{ name: istio-csr-openbao }' | check $P alice fail "negative: second Issuer as istio-csr-openbao"
vault_issuer Issuer bypass istio-system '{ name: istio-csr-openbao, audiences: ["vault://istio-system/openbao-mesh"] }' \
  | check $P alice fail "negative: second Issuer with the mesh audience (the review's bypass)"
vault_issuer Issuer bypass istio-system '{ name: other-sa, audiences: ["x", "vault://istio-system/openbao-mesh"] }' \
  | check $P alice fail "negative: the mesh audience with another ServiceAccount"
vault_issuer ClusterIssuer bypass "" '{ name: istio-csr-openbao, audiences: ["vault://istio-system/openbao-mesh"] }' \
  | check $P alice fail "negative: ClusterIssuer with the mesh ServiceAccount/audience"
vault_issuer Issuer openbao-mesh default '{ name: istio-csr-openbao, audiences: ["vault://istio-system/openbao-mesh"] }' \
  | check $P alice fail "negative: an openbao-mesh Issuer in another namespace"
vault_issuer Issuer vault-app team-a '{ name: app, audiences: ["vault://team-a/vault-app"] }' \
  | check $P alice pass "other Vault Issuers with their own ServiceAccount and audience are admitted"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: selfsigned, namespace: istio-system }\nspec:\n  selfSigned: {}\n' \
  | check $P alice skip "non-Vault issuers are not affected"

# What charts/cluster actually renders for every mesh member is admitted (Argo CD applies it).
n=0
for f in "${RENDERED_DIR:-/nonexistent}"/cluster-*.yaml; do
  [[ -f "$f" ]] || continue
  for c in $(yq -N 'select(.kind == "Certificate" and (.metadata.name | test("-mesh-reader$"))) | .metadata.name' "$f"); do
    n=$((n + 1))
    yq "select(.kind == \"Certificate\" and .metadata.name == \"$c\")" "$f" \
      | check platform-mesh-reader-certificates "$ARGO" pass "rendered $(basename "$f" .yaml): $c"
  done
  for i in $(yq -N 'select(.kind == "Issuer" and (.metadata.name | test("-client-ca$"))) | .metadata.name' "$f"); do
    yq "select(.kind == \"Issuer\" and .metadata.name == \"$i\")" "$f" | check platform-mesh-issuers "$ARGO" pass "rendered $(basename "$f" .yaml): Issuer $i"
  done
done
tally
if [[ -n "${RENDERED_DIR:-}" ]]; then assert_match "$n" '^[1-9]' "rendered mesh Certificates found"; fi

finish
