#!/usr/bin/env bash
# Mesh PKI admission guards (addon mesh-root-ca templates/admission.yaml), evaluated offline with the kyverno CLI
# (CEL, same expression language as the API server): what charts/cluster renders is admitted, everything that would
# turn a <name>-client-ca issuer or a mesh root into a general signing API is denied (negative cases below).
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

helm template mesh-root-ca addons/mesh-root-ca --namespace cert-manager --set 'mesh.groups={local}' > "$TMP/mrc.yaml"
helm template cert-manager addons/cert-manager --namespace cert-manager \
  | yq 'select(.kind == "CustomResourceDefinition" and .spec.group == "cert-manager.io")' > "$TMP/crds.yaml"
for p in $(yq -N 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$TMP/mrc.yaml"); do
  yq "select(.metadata.name == \"$p\" and .kind == \"ValidatingAdmissionPolicy\")" "$TMP/mrc.yaml" > "$TMP/policy-$p.yaml"
  b=$(yq -N "select(.kind == \"ValidatingAdmissionPolicyBinding\" and .spec.policyName == \"$p\") | .spec.validationActions[]" "$TMP/mrc.yaml")
  assert_eq "$b" "Deny" "binding for $p denies"
done

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

inter() {   # inter <extra spec yaml> [namespace] [name]
  printf 'apiVersion: cert-manager.io/v1\nkind: Certificate\nmetadata: { name: %s, namespace: %s }\nspec:\n  commonName: dev1-mesh-ca\n  secretName: dev1-mesh-ca\n  issuerRef: { group: cert-manager.io, kind: ClusterIssuer, name: mesh-root-local }\n%s\n' "${3:-dev1-mesh-ca}" "${2:-fleet}" "$1"
}
I_OK='  isCA: true
  duration: 336h
  usages: [cert sign, crl sign, digital signature]'
P=platform-mesh-intermediate-certificates
inter "$I_OK" | check $P "$ARGO" pass "the intermediate charts/cluster renders, applied by Argo CD"
inter "$I_OK" | check $P alice fail "negative: created by anyone but Argo CD (not from git)"
inter "$I_OK" default | check $P "$ARGO" fail "negative: outside fleet"
inter "$I_OK" fleet rogue-ca | check $P "$ARGO" fail "negative: not a <cluster>-mesh-ca"
inter '  isCA: true
  duration: 2160h
  usages: [cert sign, crl sign, digital signature]' | check $P "$ARGO" fail "negative: duration > 14d"
inter '  isCA: true
  duration: 336h
  usages: [cert sign, crl sign, digital signature, key encipherment]' | check $P "$ARGO" fail "negative: key encipherment on a CA"
inter '  duration: 168h
  usages: [client auth]' | check $P "$ARGO" fail "negative: leaf cert straight from a mesh root"

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
cr ClusterIssuer mesh-root-local '  isCA: true
  duration: 336h
  usages: [cert sign, crl sign, digital signature]' | check $P "$CM" pass "intermediate request from cert-manager"
cr ClusterIssuer mesh-root-local '  isCA: true
  duration: 336h
  usages: [cert sign, crl sign, digital signature]' default | check $P "$CM" fail "negative: mesh root request outside fleet"
cr ClusterIssuer mesh-root-local '  isCA: true
  duration: 8760h
  usages: [cert sign, crl sign, digital signature]' | check $P "$CM" fail "negative: intermediate request > 14d"
cr ClusterIssuer letsencrypt '  duration: 2160h
  usages: [server auth]' default | check $P alice skip "other issuers are not affected"

P=platform-mesh-issuers
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: dev1-client-ca, namespace: fleet }\nspec:\n  ca: { secretName: dev1-cca }\n' \
  | check $P "$ARGO" pass "Issuer fleet/<x>-client-ca over <x>-cca"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: mine, namespace: fleet }\nspec:\n  ca: { secretName: dev1-cca }\n' \
  | check $P alice fail "negative: second issuer over a CAPI client CA"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: dev1-client-ca, namespace: fleet }\nspec:\n  ca: { secretName: prod1-cca }\n' \
  | check $P alice fail "negative: client-ca issuer over another cluster's CA"
printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata: { name: x, namespace: fleet }\nspec:\n  ca: { secretName: dev1-mesh-ca }\n' \
  | check $P alice fail "negative: issuer over a mesh intermediate"
printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata: { name: mesh-root-local }\nspec:\n  ca: { secretName: mesh-root-local }\n' \
  | check $P "$ARGO" pass "ClusterIssuer mesh-root-<group> over its own root"
printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata: { name: anything }\nspec:\n  ca: { secretName: mesh-root-local }\n' \
  | check $P alice fail "negative: another ClusterIssuer over a mesh root"
printf 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata: { name: selfsigned }\nspec:\n  selfSigned: {}\n' \
  | check $P alice skip "unrelated issuers are not affected"

# What charts/cluster actually renders for every mesh member is admitted (Argo CD applies it).
n=0
for f in "${RENDERED_DIR:-/nonexistent}"/cluster-*.yaml; do
  [[ -f "$f" ]] || continue
  for c in $(yq -N 'select(.kind == "Certificate" and (.metadata.name | test("-mesh-(ca|reader)$"))) | .metadata.name' "$f"); do
    n=$((n + 1))
    case "$c" in *-mesh-ca) P=platform-mesh-intermediate-certificates ;; *) P=platform-mesh-reader-certificates ;; esac
    yq "select(.kind == \"Certificate\" and .metadata.name == \"$c\")" "$f" | check $P "$ARGO" pass "rendered $(basename "$f" .yaml): $c"
  done
  for i in $(yq -N 'select(.kind == "Issuer" and (.metadata.name | test("-client-ca$"))) | .metadata.name' "$f"); do
    yq "select(.kind == \"Issuer\" and .metadata.name == \"$i\")" "$f" | check platform-mesh-issuers "$ARGO" pass "rendered $(basename "$f" .yaml): Issuer $i"
  done
done
tally
if [[ -n "${RENDERED_DIR:-}" ]]; then assert_match "$n" '^[1-9]' "rendered mesh Certificates found"; fi
for i in $(yq -N 'select(.kind == "ClusterIssuer") | .metadata.name' "$TMP/mrc.yaml"); do
  yq "select(.kind == \"ClusterIssuer\" and .metadata.name == \"$i\")" "$TMP/mrc.yaml" | check platform-mesh-issuers "$ARGO" pass "rendered ClusterIssuer $i"
done
tally

finish
