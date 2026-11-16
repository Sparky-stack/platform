#!/usr/bin/env bash
# Opt-in integration test of the mesh CA (task test:openbao; needs docker, openssl, python3; not part of hack/test.sh):
# runs the pinned OpenBao image with the configuration the chart renders (static seal, self-initialisation, audit),
# then the reconcile script with the Job's rendered environment and a scoped login, then plays a member:
#   - JWT login against auth/mesh-<cluster> with a token signed by that cluster's key (served as JWKS over TLS)
#   - signs a SPIFFE workload cert and istiod's cert at its role; chain ends at the group root
#   - negatives: wrong audience / subject / other cluster's key, foreign DNS names, other trust domain, another
#     cluster's role, the root mount, sys/ paths
#   - restart: auto-unseals with the static key; prune removes a member's auth
# Kubernetes-only parts are faked: a dummy ServiceAccount mount for the Kubernetes auth config, and a userpass user
# with the reconcile's policy (instead of the projected-token login) - initialised in a test-only extra stanza.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
echo "== openbao_integration =="
for b in docker openssl python3 helm yq; do command -v "$b" >/dev/null || { echo "  SKIP: needs $b"; exit 0; }; done
docker info >/dev/null 2>&1 || { echo "  SKIP: docker not reachable"; exit 0; }
cd "$ROOT"
W="$TMP/w"; mkdir -p "$W"/{tls,unseal,sa,inputs,jwks1/openid/v1,jwks2/openid/v1}
IMG=$(yq '.openbao.server.image | .registry + "/" + .repository + ":" + .tag' addons/openbao/values.yaml)
PYIMG=$(yq '.config.image' addons/harbor/values.yaml)   # pinned python image already used by the repo
NET="openbao-it-$$"
cleanup() {
  docker rm -f "$NET-bao" "$NET-jwks" >/dev/null 2>&1 || true
  docker volume rm "$NET-data" >/dev/null 2>&1 || true    # raft data: a named volume, owned by the container user
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- TLS, seal key, fake ServiceAccount, config from the chart --------------------------------------------------------
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=it-ca -keyout "$W/ca.key" -out "$W/tls/ca.crt" 2>/dev/null
printf 'subjectAltName=DNS:openbao,DNS:jwks,IP:127.0.0.1\n' > "$W/san.cnf"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=openbao -keyout "$W/tls/tls.key" -out "$W/tls.csr" 2>/dev/null
openssl x509 -req -in "$W/tls.csr" -CA "$W/tls/ca.crt" -CAkey "$W/ca.key" -CAcreateserial -days 1 -extfile "$W/san.cnf" -out "$W/tls/tls.crt" 2>/dev/null
printf '%s' "$(openssl rand -hex 32)" > "$W/unseal/key"
cp "$W/tls/ca.crt" "$W/sa/ca.crt"; printf 'dummy' > "$W/sa/token"; printf 'openbao' > "$W/sa/namespace"
chmod -R a+rX "$W"
helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml --set 'mesh.groups={local}' \
  -s charts/openbao/templates/server-config-configmap.yaml | yq '.data["extraconfig-from-values.hcl"]' \
  | python3 -c '
import re, sys
s = sys.stdin.read()
s = re.sub(r"\n\s*retry_join \{.*?\n\s*\}", "", s, flags=re.S)       # single node, no peers
s = s.replace("service_registration \"kubernetes\" {}", "")          # no Kubernetes API here
s = s.replace("storage \"raft\" {", "storage \"raft\" {\n  node_id = \"it-0\"")
print(s)' > "$W/config.hcl"
IT_PW=$(openssl rand -hex 16)   # throwaway login for the disposable container
cat >> "$W/config.hcl" <<EOF
initialize "zz-integration-test-only" {
  request "userpass" {
    operation = "update"
    path      = "sys/auth/userpass"
    data      = { type = "userpass" }
  }
  request "reconciler" {
    operation = "update"
    path      = "auth/userpass/users/reconciler"
    data      = { password = "$IT_PW", token_policies = ["platform-mesh-config"], token_no_default_policy = true }
  }
}
EOF

# --- members' ServiceAccount keys, JWKS over TLS ------------------------------------------------------------------------
for i in 1 2; do openssl genrsa -out "$W/sa$i.key" 2048 2>/dev/null; done
cat > "$W/jwt.py" <<'EOF'
import base64, json, subprocess, sys, time
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def jwks(key, kid):
    n = subprocess.check_output(["openssl", "rsa", "-in", key, "-noout", "-modulus"]).decode().strip().split("=")[1]
    print(json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid, "n": b64(bytes.fromhex(n)), "e": "AQAB"}]}))
def jwt(key, kid, sub, aud):
    h = b64(json.dumps({"alg": "RS256", "kid": kid, "typ": "JWT"}).encode())
    t = int(time.time())
    p = b64(json.dumps({"iss": "https://kubernetes.default.svc.cluster.local", "sub": sub, "aud": aud.split(","), "iat": t, "nbf": t, "exp": t + 600}).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=(h + "." + p).encode(), capture_output=True, check=True).stdout
    print(h + "." + p + "." + b64(sig))
{"jwks": jwks, "jwt": jwt}[sys.argv[1]](*sys.argv[2:])
EOF
python3 "$W/jwt.py" jwks "$W/sa1.key" k1 > "$W/jwks1/openid/v1/jwks"
python3 "$W/jwt.py" jwks "$W/sa2.key" k2 > "$W/jwks2/openid/v1/jwks"
cat > "$W/srv.py" <<'EOF'
import http.server, os, ssl, sys
class Deny(http.server.BaseHTTPRequestHandler):   # a member whose issuer discovery is not public: 403 for anonymous
    def do_GET(self):
        self.send_response(403); self.end_headers(); self.wfile.write(b'{"reason":"Forbidden","message":"system:anonymous"}')
h = http.server.SimpleHTTPRequestHandler
if sys.argv[1] == "deny":
    h = Deny
else:
    os.chdir(sys.argv[1])
s = http.server.HTTPServer(("0.0.0.0", int(sys.argv[2])), h)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("/w/tls/tls.crt", "/w/tls/tls.key")
s.socket = c.wrap_socket(s.socket, server_side=True); s.serve_forever()
EOF
chmod -R a+rX "$W"

docker network create "$NET" >/dev/null
docker run -d --name "$NET-jwks" --network "$NET" --network-alias jwks -v "$W:/w:ro" "$PYIMG" \
  sh -c 'python3 /w/srv.py /w/jwks1 8443 & python3 /w/srv.py /w/jwks2 8444 & python3 /w/srv.py deny 8445' >/dev/null
docker volume create "$NET-data" >/dev/null
docker run --rm --user 0 -v "$NET-data:/d" --entrypoint chown "$IMG" 100:1000 /d   # the image runs as openbao (100)
start_bao() {
  docker run -d --name "$NET-bao" --network "$NET" --network-alias openbao \
    -v "$W/sa:/var/run/secrets/kubernetes.io/serviceaccount:ro" -v "$W/tls:/openbao/tls:ro" -v "$W/unseal:/openbao/unseal:ro" \
    -v "$NET-data:/openbao/data" -v "$W/config.hcl:/cfg/config.hcl:ro" \
    -e BAO_API_ADDR=https://openbao:8200 -e BAO_CLUSTER_ADDR=https://openbao:8201 "$IMG" server -config=/cfg/config.hcl >/dev/null
}
bao_in() {   # bao_in <script>: run a shell snippet in a throwaway OpenBao CLI container on the test network
  docker run --rm --network "$NET" -v "$W:/w:ro" -v "$ROOT/addons/openbao/files:/scripts:ro" \
    -e BAO_ADDR=https://openbao:8200 -e BAO_CACERT=/w/tls/ca.crt -e HOME=/tmp --entrypoint sh "$IMG" -c "$1"
}
wait_unsealed() {
  local i
  for i in $(seq 1 40); do
    bao_in 'bao status -format=json' 2>/dev/null | grep -q '"sealed": false' && return 0
    sleep 2
  done
  return 1
}
start_bao
rc=0; wait_unsealed || rc=$?
assert_eq "$rc" 0 "OpenBao self-initialises and auto-unseals (static seal)"
[[ $rc -eq 0 ]] || { docker logs "$NET-bao" 2>&1 | grep -v '^{' | tail -20 >&2; finish; }
assert_match "$(docker logs "$NET-bao" 2>&1 | grep -c 'revoked lease: lease_id=auth/token/root' || true)" '^[1-9]' "self-initialisation revoked its root token"
assert_eq "$(bao_in 'bao read sys/mounts >/dev/null 2>&1 && echo open || echo denied')" denied "no token -> nothing"

# --- reconcile with the Job's rendered environment (scoped login) ---------------------------------------------------
helm template openbao addons/openbao --namespace openbao --values installations/local/installation.yaml --set 'mesh.groups={local}' \
  -s templates/reconcile.yaml | yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name != "BAO_ADDR" and .name != "BAO_CACERT" and .name != "INPUT_DIR") | "export " + .name + "=\"" + .value + "\""' > "$W/env.sh"
printf '%s' "$IT_PW" > "$W/it-pw"
for c in 1 2 3; do   # c3: JWKS answers 403 to anonymous (the live-boot failure)
  printf 'local' > "$W/inputs/c$c.group"; printf 'https://jwks:844%s' "$((c + 2))" > "$W/inputs/c$c.server"; cp "$W/tls/ca.crt" "$W/inputs/c$c.ca"
done
chmod -R a+rX "$W"
# shellcheck disable=SC2016  # runs inside the container
RECONCILE='. /w/env.sh; export INPUT_DIR=/w/inputs BAO_TOKEN=$(bao write -field=token auth/userpass/login/reconciler password=@/w/it-pw); sh /scripts/mesh-reconcile.sh'
rc=0; out=$(bao_in "$RECONCILE" 2>&1) || rc=$?
assert_eq "$rc" 0 "reconcile runs with the scoped policy only"; [[ $rc -eq 0 ]] || printf '%s\n' "$out" >&2
assert_match "$out" 'done: configured=\[c1 c2\] failed=\[c3\]' "c1 + c2 configured, c3 (JWKS 403) reported and skipped"
assert_match "$out" 'member c3 \(group local\): FAILED' "real OpenBao refuses c3's config while its JWKS is forbidden"
out=$(bao_in "$RECONCILE" 2>&1)
assert_eq "$(printf '%s\n' "$out" | grep -c 'generate\|enable' || true)" 0 "second run is a no-op (idempotent)"

# --- play member c1 -----------------------------------------------------------------------------------------------------
AUD="vault://istio-system/openbao-mesh"; SUB="system:serviceaccount:istio-system:istio-csr-openbao"
good=$(python3 "$W/jwt.py" jwt "$W/sa1.key" k1 "$SUB" "$AUD,https://openbao.example:8200")
bad_aud=$(python3 "$W/jwt.py" jwt "$W/sa1.key" k1 "$SUB" "https://kubernetes.default.svc.cluster.local")
bad_sub=$(python3 "$W/jwt.py" jwt "$W/sa1.key" k1 "system:serviceaccount:default:app" "$AUD")
other=$(python3 "$W/jwt.py" jwt "$W/sa2.key" k2 "$SUB" "$AUD")
login() { bao_in "bao write -field=token auth/mesh-c1/login role=istio-csr jwt=$1 >/dev/null 2>&1 && echo ok || echo denied"; }
assert_eq "$(login "$good")" ok "c1 logs in with its own ServiceAccount token (audience + subject bound)"
assert_eq "$(login "$bad_aud")" denied "negative: API-server audience is rejected"
assert_eq "$(login "$bad_sub")" denied "negative: another ServiceAccount is rejected"
assert_eq "$(login "$other")" denied "negative: c2's token is rejected at c1's mount"
mkcsr() { openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -subj "${2:-/}" -addext "subjectAltName=$3" -out "$W/$1.csr" 2>/dev/null; }
mkcsr wl / "URI:spiffe://cluster.local/ns/eastwest-demo/sa/client"
mkcsr istiod /CN=istiod.istio-system.svc "DNS:istiod.istio-system.svc,URI:spiffe://cluster.local/ns/istio-system/sa/istiod-service-account"
mkcsr evil /CN=evil.example "DNS:evil.example"
mkcsr td / "URI:spiffe://evil.org/ns/a/sa/b"
chmod a+r "$W"/*.csr
sign() { bao_in "export BAO_TOKEN=\$(bao write -field=token auth/mesh-c1/login role=istio-csr jwt=$good); bao write $1 >/dev/null 2>&1 && echo ok || echo denied"; }
assert_eq "$(sign 'pki-mesh-local-int/sign/c1 csr=@/w/wl.csr uri_sans=spiffe://cluster.local/ns/eastwest-demo/sa/client')" ok "c1 signs a SPIFFE workload cert"
assert_eq "$(sign 'pki-mesh-local-int/sign/c1 csr=@/w/istiod.csr common_name=istiod.istio-system.svc alt_names=istiod.istio-system.svc uri_sans=spiffe://cluster.local/ns/istio-system/sa/istiod-service-account')" ok "c1 signs istiod's serving cert"
assert_eq "$(sign 'pki-mesh-local-int/sign/c1 csr=@/w/evil.csr common_name=evil.example')" denied "negative: foreign DNS name"
assert_eq "$(sign 'pki-mesh-local-int/sign/c1 csr=@/w/td.csr uri_sans=spiffe://evil.org/ns/a/sa/b')" denied "negative: other trust domain"
assert_eq "$(sign 'pki-mesh-local-int/sign/c2 csr=@/w/wl.csr uri_sans=spiffe://cluster.local/ns/eastwest-demo/sa/client')" denied "negative: c2's role"
assert_eq "$(sign 'pki-mesh-local-root/root/sign-intermediate csr=@/w/wl.csr')" denied "negative: the group root"
assert_eq "$(sign 'sys/policies/acl/x policy=x')" denied "negative: sys/"
chain=$(bao_in "export BAO_TOKEN=\$(bao write -field=token auth/mesh-c1/login role=istio-csr jwt=$good); bao write -format=json pki-mesh-local-int/sign/c1 csr=@/w/wl.csr uri_sans=spiffe://cluster.local/ns/eastwest-demo/sa/client")
root=$(bao_in 'bao read -field=certificate pki-mesh-local-root/cert/ca')
last=$(printf '%s' "$chain" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["ca_chain"][-1].strip())')
assert_eq "$last" "$(printf '%s' "$root" | tr -d '\r')" "issued chain ends at the group root (cert-manager's ca.crt == the pinned root)"
ttl=$(printf '%s' "$chain" | python3 -c 'import json,sys,time; d=json.load(sys.stdin)["data"]; print(int((d["expiration"]-time.time())/3600))')
assert_eq "$([[ $ttl -le 24 ]] && echo ok || echo "$ttl h")" ok "default workload TTL <= 24h"

# --- restart auto-unseals; prune ----------------------------------------------------------------------------------------
docker restart "$NET-bao" >/dev/null
rc=0; wait_unsealed || rc=$?
assert_eq "$rc" 0 "restart: auto-unseal with the static key"
rm -f "$W"/inputs/c2.*
out=$(bao_in "$RECONCILE" 2>&1)
assert_match "$out" 'prune auth mesh-c2' "removed member: auth mount pruned"
assert_eq "$(printf '%s\n' "$out" | grep -c 'prune auth mesh-c3' || true)" 0 "failing member still in the inputs is not pruned"
assert_eq "$(bao_in "bao write -field=token auth/mesh-c2/login role=istio-csr jwt=$other >/dev/null 2>&1 && echo ok || echo denied")" denied "removed member can no longer log in"

finish
