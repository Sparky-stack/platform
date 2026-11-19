#!/usr/bin/env bash
# hack/demo-check.sh (task demo:check) offline: kubectl, curl, cosign and helm are stubs answering from fixture files,
# so the parsing, the PASS / FAIL / PENDING mapping, the table and the exit code are tested without a cluster.
# Also: read-only (every apply is --dry-run=server, no mutating verb), the pinned cosign identity comes from
# addons/kyverno-policies/values.yaml, kubeconfig secret content never reaches the output, context koorikla is refused.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_demo_check =="

REAL_YQ=$(mise which yq 2>/dev/null || command -v yq)
[[ -x "$REAL_YQ" ]] || { echo "  yq not found" >&2; exit 1; }

R="$TMP/root"; BIN="$TMP/bin"
mkdir -p "$R/hack" "$R/addons/kyverno-policies" "$R/installations" "$R/charts/cluster" "$BIN"
cp "$ROOT/hack/demo-check.sh" "$ROOT/hack/kubeconfig.sh" "$R/hack/"
cp -R "$ROOT/hack/lib" "$R/hack/"
cp "$ROOT/addons/kyverno-policies/values.yaml" "$R/addons/kyverno-policies/"
cp -R "$ROOT/installations/local" "$ROOT/installations/aws-example" "$R/installations/"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_YQ" > "$BIN/yq"

SENTINEL=SentinelKubeToken4711
KUBECONFIG_B64=$(printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://192.0.2.7:6443\nusers:\n- name: u\n  user:\n    token: %s\n' "$SENTINEL" | base64 | tr -d '\n')
UNSIGNED=ghcr.io/koorikla/hello-world@sha256:5760e176af0ec30cb8b06c80e99b3ab1746243c6c2d54997847ff850e8e38ad7
SIGNED=ghcr.io/koorikla/hello-world:abc1234@sha256:889643d395abe5afdae94db0f9790b5c0f922532eefc94d32a691927f87d7988

# kubectl stub: target = --context name or --kubeconfig basename; answer = $FIX/<target>.<key> (exit code from
# <file>.rc if present; a missing file prints nothing).
cat > "$BIN/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "kubectl \$*" >> "\$HLOG/calls"
t=""; prev=""
for a in "\$@"; do
  [[ "\$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }
  case "\$prev" in --context) t=\$a ;; --kubeconfig) t=\$(basename "\$a" .kubeconfig) ;; esac
  prev=\$a
done
[[ -n "\$t" ]] || t=default
a=" \$* "
case "\$a" in
  *" get secret "*"-kubeconfig "*) printf '%s' "$KUBECONFIG_B64"; exit 0 ;;
  *" get secret -n platform-secrets cosign-platform "*) k=cosign-pub ;;
  *" get secret -n harbor harbor-ca-bundle "*) k=registry-ca ;;
  *" get secret -n platform-secrets harbor "*) k=harbor-robot ;;
  *" apply "*)
    body=\$(cat)
    case "\$a" in *" --dry-run=server "*) ;; *) echo "stub: apply without --dry-run=server" >&2; exit 98 ;; esac
    if [[ "\$body" == *"$UNSIGNED"* ]]; then k=apply-unsigned; else k=apply-signed; fi ;;
  *" get --raw "*k8s_cluster_name*) k=prom-clusters ;;
  *" get --raw "*kube_pod_labels*) k=prom-app ;;
  *" get applications.argoproj.io "*sync.status*) k=apps ;;
  *" get applications.argoproj.io "*) [[ -f "\$FIX/\$t.apps" ]] && awk '{ print \$1 }' "\$FIX/\$t.apps"; exit 0 ;;
  *" get clusters.cluster.x-k8s.io "*" -l mesh.platform.koorikla.io/group "*) k=mesh-members ;;
  *" get clusters.cluster.x-k8s.io "*'{.metadata.name}{"\\n"}'*) k=cluster-names ;;
  *" get clusters.cluster.x-k8s.io "*) k=clusters ;;
  *" get clusterdataplanes.openchoreo.dev "*" -o jsonpath={.spec.gateway"*)
    for w in "\$@"; do case "\$w" in dev1|prod1) k=gw-\$w ;; esac; done ;;
  *" get clusterdataplanes.openchoreo.dev "*) k=dataplanes ;;
  *" get clustercomponenttypes.openchoreo.dev "*) k=componenttypes ;;
  *" get environments.openchoreo.dev "*"isProduction==true"*) k=env-production ;;
  *" get environments.openchoreo.dev "*"dataPlaneRef"*)
    for w in "\$@"; do case "\$w" in development|staging|production) k=env-dp-\$w ;; esac; done ;;
  *" get environments.openchoreo.dev "*) k=envs ;;
  *" get machines.cluster.x-k8s.io "*)
    for w in "\$@"; do case "\$w" in *cluster-name=*) k=machine-\${w#*cluster-name=} ;; esac; done ;;
  *" get workloads.openchoreo.dev "*) k=workloads ;;
  *" get namespaces "*) k=cellns ;;
  *" get workflowruns.openchoreo.dev "*) k=workflowruns ;;
  *" get releasebindings.openchoreo.dev "*) k=bindings ;;
  *" get clusterworkflows.openchoreo.dev "*) k=clusterworkflow ;;
  *" get imagevalidatingpolicies"*) k=policies ;;
  *" get daemonsets,deployments "*) k=falco ;;
  *" get deployments "*"priorityClassName"*) k=resilience-deploy ;;
  *" get poddisruptionbudgets "*) k=resilience-pdb ;;
  *" get deployment -n falco falco-falcosidekick "*) k=sidekick-fields ;;
  *" get sensors.argoproj.io "*) k=sensor ;;
  *" get workflowtemplates.argoproj.io "*) k=falco-response ;;
  *" get issuers.cert-manager.io "*) k=mesh-issuer ;;
  *" get certificates.cert-manager.io "*) k=mesh-cert ;;
  *" get clustersecretstores.external-secrets.io "*) k=stores ;;
  *" get compositeresourcedefinitions"*) k=xrds ;;
  *" get deployments "*"openchoreo.dev/component="*) k=app-envfrom ;;
  *" get secret "*".data.GREETING_SECRET"*) k=app-secret ;;
  *" get externalsecrets.external-secrets.io "*) k=app-es ;;
  *) echo "stub: unhandled kubectl \$*" >&2; exit 97 ;;
esac
f="\$FIX/\$t.\$k"
if [[ -f "\$f.rc" ]]; then [[ -f "\$f" ]] && cat "\$f" >&2; exit "\$(cat "\$f.rc")"; fi
[[ -f "\$f" ]] && cat "\$f"
exit 0
EOF

# curl stub: status code from $FIX/http.<host> (000 when absent); logs the call.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >> "$HLOG/calls"
url="${*: -1}"; host=${url#http://}; host=${host%%[:/]*}
if [[ -f "$FIX/http.$host" ]]; then cat "$FIX/http.$host"; else printf '000'; exit 7; fi
EOF

cat > "$BIN/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "cosign $*" >> "$HLOG/calls"
[[ -f "$FIX/cosign.rc" ]] || exit 0
echo "Error: no matching signatures: none of the expected identities matched" >&2
exit 1
EOF

cat > "$BIN/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "helm $*" >> "$HLOG/calls"
printf 'apiVersion: cluster.x-k8s.io/v1beta2\nkind: Cluster\n'
EOF
chmod +x "$BIN/"*

# green <dir>: fixtures of a fully working stack (dev1 + prod1; development/staging on dev1, production on prod1).
green() {
  local d=$1
  mkdir -p "$d"
  printf 'root Synced Healthy\nharbor-mgmt Synced Healthy\nfalco-dev1 Synced Healthy\nopenbao-mgmt Synced Healthy\nmesh-dev1 Synced Healthy\ncrossplane-dev1 Synced Healthy\n' > "$d/k3d-platform-mgmt.apps"
  printf 'dev1\n' > "$d/k3d-platform-mgmt.mesh-members"
  printf 'True https://openbao.openchoreo.localhost:8200' > "$d/dev1.mesh-issuer"
  printf 'True openbao-mesh 2026-11-18T09:00:00Z' > "$d/dev1.mesh-cert"
  printf 'True' > "$d/dev1.xrds"
  printf 'dev1\nprod1\n' > "$d/k3d-platform-mgmt.cluster-names"
  printf 'dev1 Provisioned True\nprod1 Provisioned True\n' > "$d/k3d-platform-mgmt.clusters"
  printf 'dev1 true 1\nprod1 true 1\n' > "$d/k3d-platform-mgmt.dataplanes"
  printf 'dev1.apps.localhost 19080' > "$d/k3d-platform-mgmt.gw-dev1"
  printf 'prod1.apps.localhost 19080' > "$d/k3d-platform-mgmt.gw-prod1"
  printf 'service\nworker\n' > "$d/k3d-platform-mgmt.componenttypes"
  printf 'false development\ntrue production\nfalse staging\n' > "$d/k3d-platform-mgmt.envs"
  printf 'production\n' > "$d/k3d-platform-mgmt.env-production"
  printf 'dev1' > "$d/k3d-platform-mgmt.env-dp-development"
  printf 'dev1' > "$d/k3d-platform-mgmt.env-dp-staging"
  printf 'prod1' > "$d/k3d-platform-mgmt.env-dp-production"
  printf '172.18.0.7\n' > "$d/k3d-platform-mgmt.machine-dev1"
  printf '172.18.0.6\n' > "$d/k3d-platform-mgmt.machine-prod1"
  printf 'other docker.io/x/y:1\nhello-world %s\n' "$SIGNED" > "$d/k3d-platform-mgmt.workloads"
  printf 'dp-default-demo-production-1234\n' > "$d/prod1.cellns"
  printf 'hello-world-1a2b app-production kubernetes.io/hostname topology.kubernetes.io/zone' > "$d/prod1.resilience-deploy"
  printf '1/AlwaysAllow' > "$d/prod1.resilience-pdb"
  printf 'pod/demo-check created (server dry run)\n' > "$d/prod1.apply-signed"
  printf 'Error from server: error when creating "STDIN": admission webhook "ivpol.validate.kyverno.svc-fail" denied the request: Policy openchoreo-verify-images-enforce failed: image (ghcr.io/koorikla/) is not signed by gh-koorikla-hello-world-heads-main; verification details: no signatures found\n' > "$d/prod1.apply-unsigned"
  printf '1\n' > "$d/prod1.apply-unsigned.rc"
  printf '2026-11-16T18:00:00Z build-1 go True/\n2026-11-16T18:33:02Z gate-old promotion-gate /True\n2026-11-16T19:04:37Z gate-new promotion-gate True/\n' > "$d/k3d-platform-mgmt.workflowruns"
  printf 'clusterworkflow.openchoreo.dev/promotion-gate\n' > "$d/k3d-platform-mgmt.clusterworkflow"
  printf 'ImageValidatingPolicy openchoreo-verify-images-enforce true\nValidatingPolicy disallow-host-path true\n' > "$d/dev1.policies"
  cp "$d/dev1.policies" "$d/prod1.policies"
  printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"k8s_cluster_name":"prod1"},"value":[1,"7"]},{"metric":{"k8s_cluster_name":"dev1"},"value":[1,"4"]}]}}' > "$d/k3d-platform-mgmt.prom-clusters"
  printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{"label_openchoreo_dev_environment":"development"},"value":[1,"1"]}]}}' > "$d/k3d-platform-mgmt.prom-app"
  printf 'DaemonSet falco 1 1\nDeployment falco-falcosidekick 1 1\n' > "$d/k3d-platform-mgmt.falco"
  printf 'DaemonSet falco 1 1\nDeployment falco-falcosidekick 1 1\nDeployment falco-talon 1 1\n' > "$d/dev1.falco"
  cp "$d/dev1.falco" "$d/prod1.falco"
  printf 'env:dev,cluster:dev1' > "$d/dev1.sidekick-fields"
  printf 'cluster:prod1' > "$d/prod1.sidekick-fields"
  printf 'True' > "$d/k3d-platform-mgmt.sensor"
  printf 'workflowtemplate.argoproj.io/falco-response\n' > "$d/k3d-platform-mgmt.falco-response"
  printf 'platform True\nmgmt-fleet True\n' > "$d/k3d-platform-mgmt.stores"
  printf 'default True\n' > "$d/dev1.stores"
  cp "$d/dev1.stores" "$d/prod1.stores"
  # app secret (#250): development cell namespace on dev1, envFrom Secret with GREETING_SECRET, ExternalSecret Ready
  printf 'dp-default-demo-development-1234\n' > "$d/dev1.cellns"
  printf 'hello-world-env-secrets-1234\n' > "$d/dev1.app-envfrom"
  printf 'aGVsbG8=' > "$d/dev1.app-secret"
  printf 'SecretStore/openbao-tenant 15s True' > "$d/dev1.app-es"
  printf '200' > "$d/http.development-default.dev1.apps.localhost"
  printf '200' > "$d/http.staging-default.dev1.apps.localhost"
  printf '200' > "$d/http.production-default.prod1.apps.localhost"
  printf '200' > "$d/http.openchoreo.localhost"
}

# run <name> [env assignments...]: run demo-check.sh against $FIX; sets RC, OUT, CALLS.
run() {
  local name=$1
  shift
  HLOG="$TMP/out/$name"; mkdir -p "$HLOG"; : > "$HLOG/calls"
  if env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" SYSTEMROOT="${SYSTEMROOT:-}" TMPDIR="$TMP" HLOG="$HLOG" FIX="$FIX" \
      KUBECONFIG_MODE=direct DEMO_HTTP_MODE=direct "$@" "$BASH" "$R/hack/demo-check.sh" > "$HLOG/out" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT=$(cat "$HLOG/out")
  CALLS=$(cat "$HLOG/calls")
}

# result_of <title>: RESULT column of the row with that CHECK title (columns are fixed width).
result_of() { printf '%s\n' "$OUT" | awk -v t="$1" '{ c = substr($0, 6, 46); sub(/ +$/, "", c) } c == t { r = substr($0, 53, 12); sub(/ +$/, "", r); print r }'; }
detail_of() { printf '%s\n' "$OUT" | awk -v t="$1" '{ c = substr($0, 6, 46); sub(/ +$/, "", c) } c == t { print substr($0, 66) }'; }

common_asserts() {
  local name=$1 bad
  assert_eq "$(grep -c "$SENTINEL" "$HLOG/out" || true)" 0 "$name: kubeconfig content never printed"
  bad=$(printf '%s\n' "$CALLS" | grep '^kubectl ' | grep -E ' (create|delete|patch|edit|label|annotate|scale|replace|rollout|exec|cordon|drain|taint) ' || true)
  assert_eq "$bad" "" "$name: no mutating kubectl verb"
  bad=$(printf '%s\n' "$CALLS" | grep '^kubectl .* apply ' | grep -v -- ' --dry-run=server ' || true)
  assert_eq "$bad" "" "$name: every apply is --dry-run=server"
  assert_eq "$(printf '%s\n' "$CALLS" | grep -c 'koorikla ' || true)" 0 "$name: context koorikla never used"
}

# ---- green stack ----------------------------------------------------------------------------------------------------
FIX="$TMP/fix/green"; green "$FIX"
run green
common_asserts green
assert_eq "$RC" 0 "green: exit 0"
assert_match "$OUT" "^Demo pre-flight \(docs/demo.md\): context k3d-platform-mgmt, workload clusters: dev1 prod1" "green: header"
assert_match "$OUT" $'\nSTEP CHECK {42}RESULT {7}DETAIL\n' "green: table header with fixed columns"
assert_eq "$(result_of 'Argo CD apps Synced/Healthy')" PASS "green: argo apps"
assert_eq "$(detail_of 'Argo CD apps Synced/Healthy')" "6/6 Synced/Healthy" "green: argo apps detail"
assert_eq "$(result_of 'CAPI clusters Provisioned')" PASS "green: clusters"
assert_eq "$(detail_of 'OpenChoreo data planes connected')" "connected: dev1(1 agent), prod1(1 agent)" "green: data planes"
assert_match "$(detail_of 'cluster files render for other providers')" "^renders: aws-example/dev-euc1\(aws\), aws-example/prod-euc1\(aws\)$" "green: render other providers (local skipped)"
assert_eq "$(result_of 'Backstage console responds')" PASS "green: console"
assert_eq "$(detail_of 'component types for self-service')" "2: service, worker" "green: component types"
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" PASS "green: cosign"
assert_match "$(detail_of 'latest image signed (cosign, pinned identity)')" "^ghcr.io/koorikla/hello-world:abc1234@sha256:889643d395ab\.\.\. signed by app-container.yaml@[0-9a-f]{7} \(koorikla/hello-world, refs/heads/main, push\)$" "green: cosign detail (digest shortened)"
WREF=$(yq '.imageVerification.github.workflowRef' "$ROOT/addons/kyverno-policies/values.yaml")
cos=$(printf '%s\n' "$CALLS" | grep '^cosign verify ' || true)
assert_match "$cos" "--certificate-identity https://github.com/koorikla/platform/.github/workflows/app-container.yaml@$WREF " "green: cosign uses the pinned workflow identity"
assert_match "$cos" "--certificate-oidc-issuer https://token.actions.githubusercontent.com " "green: cosign pins the issuer"
assert_match "$cos" "--certificate-github-workflow-repository koorikla/hello-world --certificate-github-workflow-ref refs/heads/main --certificate-github-workflow-trigger push " "green: cosign pins repository, ref, trigger"
assert_match "$cos" "$SIGNED\$" "green: cosign verifies the Workload's image"
assert_eq "$(result_of 'Kyverno policies Ready (dev1)')" PASS "green: kyverno dev1"
assert_eq "$(detail_of 'Kyverno policies Ready (prod1)')" "2/2 Ready" "green: kyverno prod1 detail"
assert_eq "$(result_of 'signed image admitted (production, dry-run)')" PASS "green: signed admitted"
assert_eq "$(result_of 'unsigned image denied (production, dry-run)')" PASS "green: unsigned denied"
assert_eq "$(detail_of 'unsigned image denied (production, dry-run)')" "denied in prod1/dp-default-demo-production-1234: image (ghcr.io/koorikla/) is not signed by gh-koorikla-hello-world-heads-main" "green: deny detail names the policy message"
assert_match "$(printf '%s\n' "$CALLS" | grep ' apply ' | head -n1)" "^kubectl --kubeconfig .*/prod1.kubeconfig --request-timeout=20s apply --dry-run=server -f -$" "green: dry-run runs on the production cluster"
assert_eq "$(detail_of 'in-cluster build succeeded')" "latest build build-1 (go): succeeded" "green: build run"
assert_eq "$(printf '%s\n' "$OUT" | awk 'substr($0, 6, 13) == "hello-world 2" { print substr($0, 6, 46) }' | sed 's/ *$//' | paste -sd, -)" \
  "hello-world 200 in development,hello-world 200 in staging,hello-world 200 in production" "green: envs in promotion order"
assert_eq "$(detail_of 'hello-world 200 in staging')" "200 http://staging-default.dev1.apps.localhost:19080/hello-world-http/ (node 172.18.0.7)" "green: staging URL via node IP"
assert_match "$CALLS" "curl -s -o /dev/null -m 10 -w %\{http_code\} --resolve production-default.prod1.apps.localhost:19080:172.18.0.6 http://production-default.prod1.apps.localhost:19080/hello-world-http/" "green: curl --resolve <host>:<port>:<node ip> like docs/openchoreo.md"
assert_eq "$(detail_of 'promotion-gate WorkflowRuns present')" "2 promotion-gate run(s) in default" "green: gate runs counted"
assert_eq "$(detail_of 'latest promotion gate passed')" "gate-new: succeeded" "green: latest gate run by creation time"
assert_eq "$(detail_of 'metrics from every workload cluster')" "series from: dev1, prod1" "green: metrics per cluster"
assert_eq "$(detail_of 'hello-world metrics in observability plane')" "hello-world pods seen in: development" "green: app metrics"
assert_eq "$(detail_of 'Falco running (mgmt)')" "falco 1/1, falco-falcosidekick 1/1" "green: falco mgmt"
assert_eq "$(result_of 'Falco running (prod1)')" PASS "green: falco prod1"
assert_eq "$(result_of 'Falco escalation path on mgmt')" PASS "green: escalation"
assert_eq "$(result_of 'cluster name in Falco events')" PASS "green: cluster name (exact list item)"
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" PASS "green: mesh certs from OpenBao"
assert_eq "$(detail_of 'OpenBao-issued mesh certificates')" "OpenBao-issued: dev1(istiod until 2026-11-18T09:00:00Z); not mesh members: prod1" "green: mesh detail"
assert_eq "$(result_of 'ClusterSecretStores Ready (mgmt)')" PASS "green: stores mgmt"
assert_eq "$(result_of 'PostgreSQL claim API')" PASS "green: XRD Established on the opted-in cluster"
assert_eq "$(detail_of 'PostgreSQL claim API')" "XRD postgresqls.platform.koorikla.io Established on: dev1" "green: XRD detail"
assert_match "$CALLS" "dev1.kubeconfig --request-timeout=20s get compositeresourcedefinitions.apiextensions.crossplane.io postgresqls.platform.koorikla.io " "green: XRD read on the workload cluster, not mgmt"
assert_eq "$(detail_of 'hello-world reads GREETING_SECRET from OpenBao')" "development: GREETING_SECRET from ExternalSecret hello-world-env-secrets-1234 (SecretStore/openbao-tenant 15s) Ready" "green: app secret"
assert_match "$OUT" $'\n31 PASS, 0 FAIL, 0 PENDING$' "green: summary"

# Mesh members and Crossplane clusters vary: failures name the cluster.
cp -R "$FIX" "$TMP/fix/addons"; FIX="$TMP/fix/addons"
printf 'root Synced Healthy\nopenbao-mgmt Synced Healthy\nmesh-dev1 Synced Healthy\nmesh-prod1 Synced Healthy\ncrossplane-dev1 Synced Healthy\ncrossplane-prod1 Synced Healthy\n' > "$FIX/k3d-platform-mgmt.apps"
printf 'dev1\nprod1\n' > "$FIX/k3d-platform-mgmt.mesh-members"
printf 'True https://openbao.openchoreo.localhost:8200' > "$FIX/dev1.mesh-issuer"
printf 'True openbao-mesh 2026-11-18T10:00:00Z' > "$FIX/dev1.mesh-cert"
printf 'True https://openbao.openchoreo.localhost:8200' > "$FIX/prod1.mesh-issuer"
printf 'False openbao-mesh' > "$FIX/prod1.mesh-cert"
printf 'False' > "$FIX/prod1.xrds"
run addons
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" FAIL "addons: a not-Ready mesh certificate fails"
assert_eq "$(detail_of 'OpenBao-issued mesh certificates')" "not issued by OpenBao: prod1(Certificate istiod Ready=False issuer=openbao-mesh); ok: dev1(istiod until 2026-11-18T10:00:00Z)" "addons: names the cluster"
assert_match "$CALLS" "prod1.kubeconfig --request-timeout=20s get issuers.cert-manager.io -n istio-system openbao-mesh " "addons: reads the member's OpenBao Issuer"
assert_eq "$(result_of 'PostgreSQL claim API')" FAIL "addons: XRD not Established on an opted-in cluster fails"
assert_eq "$(detail_of 'PostgreSQL claim API')" "XRD postgresqls.platform.koorikla.io not Established on: prod1(Established=False); ok: dev1" "addons: names the cluster"
# All members issued by OpenBao; a cluster without mesh.group is not a mesh member (listed, not failed).
printf 'True openbao-mesh 2026-11-18T11:00:00Z' > "$FIX/prod1.mesh-cert"
printf 'prod1\n' > "$FIX/k3d-platform-mgmt.mesh-members"
printf 'root Synced Healthy\nopenbao-mgmt Synced Healthy\nmesh-prod1 Synced Healthy\n' > "$FIX/k3d-platform-mgmt.apps"
run addons-ok
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" PASS "addons-ok: member certs from OpenBao"
assert_eq "$(detail_of 'OpenBao-issued mesh certificates')" "OpenBao-issued: prod1(istiod until 2026-11-18T11:00:00Z); not mesh members: dev1" "addons-ok: detail"
assert_eq "$(result_of 'PostgreSQL claim API')" FAIL "addons-ok: no cluster opts in to crossplane -> FAIL (no PENDING since #91 closed)"
assert_match "$(detail_of 'PostgreSQL claim API')" "^no workload cluster opts in to addon crossplane" "addons-ok: says how to opt in"
# Negative: istiod signed by another issuer (e.g. Istio's self-signed CA) is not OpenBao-issued.
printf 'True istio-selfsigned 2026-11-18T11:00:00Z' > "$FIX/prod1.mesh-cert"
run addons-other-issuer
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" FAIL "negative: istiod from another issuer fails"
# Negative: the Issuer is not a Vault (OpenBao) issuer.
printf 'True openbao-mesh 2026-11-18T11:00:00Z' > "$FIX/prod1.mesh-cert"
printf 'True' > "$FIX/prod1.mesh-issuer"
run addons-not-vault
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" FAIL "negative: Issuer without a vault server fails"
assert_eq "$RC" 1 "addons: a FAIL exits 1"

# ---- in-cluster build: the Workload image is under <registry.host>/<appsProject>/ -> platform key ----------------------
cp -R "$TMP/fix/green" "$TMP/fix/platform"; FIX="$TMP/fix/platform"
HARBOR_IMG=harbor.openchoreo.localhost:9443/apps/demo/hello-world:fd6bd2c@sha256:95cf0fe890fe4ed7b7d2ab9acc977b7891cf8c0c671dcaa75a952725eafb3f4b
ROBOT_SENTINEL=SentinelRobotSecret0815
printf 'hello-world %s\n' "$HARBOR_IMG" > "$FIX/k3d-platform-mgmt.workloads"
printf -- '-----BEGIN PUBLIC KEY-----\nX\n-----END PUBLIC KEY-----\n' | base64 | tr -d '\n' > "$FIX/k3d-platform-mgmt.cosign-pub"
printf -- '-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n' | base64 | tr -d '\n' > "$FIX/k3d-platform-mgmt.registry-ca"
printf '%s' "$ROBOT_SENTINEL" | base64 | tr -d '\n' > "$FIX/k3d-platform-mgmt.harbor-robot"
run platform
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" PASS "platform: in-cluster build verified"
assert_eq "$(detail_of 'latest image signed (cosign, pinned identity)')" "harbor.openchoreo.localhost:9443/apps/demo/hello-world:fd6bd2c@sha256:95cf0fe890fe... signed by the platform key (in-cluster build)" "platform: detail"
cos=$(printf '%s\n' "$CALLS" | grep '^cosign verify ' || true)
assert_match "$cos" "--key [^ ]+/cosign.pub --insecure-ignore-tlog=true --registry-cacert [^ ]+/ca.crt $HARBOR_IMG\$" "platform: cosign with the platform key, registry CA, no tlog"
assert_eq "$(printf '%s\n' "$cos" | grep -c -- '--certificate-identity' || true)" 0 "platform: no keyless identity for a platform-key image"
assert_eq "$(printf '%s\n%s\n' "$OUT" "$CALLS" | grep -c "$ROBOT_SENTINEL" || true)" 0 "platform: the robot secret never reaches output or a command line"
printf '1' > "$FIX/cosign.rc"
run platform-unsigned
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" FAIL "platform: unverifiable in-cluster image fails"
assert_match "$(detail_of 'latest image signed (cosign, pinned identity)')" "NOT verified: Error: no matching signatures" "platform: error shown"
rm "$FIX/cosign.rc" "$FIX/k3d-platform-mgmt.cosign-pub"
run platform-no-key
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" FAIL "platform: missing cosign.pub fails"
assert_eq "$(detail_of 'latest image signed (cosign, pinned identity)')" "cannot read cosign.pub (platform-secrets/cosign-platform)" "platform: says what is missing"

# ---- broken stack ---------------------------------------------------------------------------------------------------
cp -R "$TMP/fix/green" "$TMP/fix/red"; FIX="$TMP/fix/red"
{
  printf 'root Synced Healthy\nharbor-mgmt OutOfSync Degraded\nfalco-dev1 Synced\n'
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'a-very-long-application-name-number-%s OutOfSync Missing\n' "$i"; done
} > "$FIX/k3d-platform-mgmt.apps"
printf 'dev1 Provisioned True\nprod1 Provisioning\n' > "$FIX/k3d-platform-mgmt.clusters"
printf 'dev1 true 1\nprod1 false 0\n' > "$FIX/k3d-platform-mgmt.dataplanes"
printf 'pod/demo-check created (server dry run)\n' > "$FIX/prod1.apply-unsigned"; rm "$FIX/prod1.apply-unsigned.rc"
printf '404' > "$FIX/http.production-default.prod1.apps.localhost"
rm "$FIX/prod1.resilience-pdb"   # production Deployment without its PodDisruptionBudget
rm "$FIX/http.staging-default.dev1.apps.localhost"
printf 'ImageValidatingPolicy openchoreo-verify-images-enforce false\nValidatingPolicy disallow-host-path true\n' > "$FIX/dev1.policies"
printf 'DaemonSet falco 1 0\nDeployment falco-falcosidekick 1\n' > "$FIX/dev1.falco"
printf 'cluster:prod1x' > "$FIX/prod1.sidekick-fields"
printf '2026-11-16T19:04:37Z gate-new promotion-gate /True\n' > "$FIX/k3d-platform-mgmt.workflowruns"
printf '1' > "$FIX/cosign.rc"
printf 'platform True\nmgmt-fleet False\n' > "$FIX/k3d-platform-mgmt.stores"
# app secret synced through another store (e.g. the data plane's ClusterSecretStore) is not the tenant path
printf 'ClusterSecretStore/default 15s True' > "$FIX/dev1.app-es"
run red
common_asserts red
assert_eq "$RC" 1 "red: exit 1 on FAIL"
assert_eq "$(result_of 'Argo CD apps Synced/Healthy')" FAIL "red: argo apps"
d=$(detail_of 'Argo CD apps Synced/Healthy')
assert_match "$d" "^1/13 Synced/Healthy; not: harbor-mgmt\(OutOfSync/Degraded\), falco-dev1\(Synced/\), a-very-long" "red: unhealthy apps listed"
assert_eq "${#d}" 200 "red: detail truncated to 200 characters"
assert_match "$d" '\.\.\.$' "red: truncation marked"
assert_eq "$(detail_of 'CAPI clusters Provisioned')" "not ready: prod1(Provisioning/available=?); ok: dev1" "red: clusters"
assert_eq "$(detail_of 'OpenChoreo data planes connected')" "agent not connected: prod1" "red: data plane"
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" FAIL "red: cosign failure"
assert_match "$(detail_of 'latest image signed (cosign, pinned identity)')" "NOT verified: Error: no matching signatures" "red: cosign error shown"
assert_eq "$(detail_of 'Kyverno policies Ready (dev1)')" "1/2 Ready; not: openchoreo-verify-images-enforce" "red: policy not ready"
assert_eq "$(result_of 'unsigned image denied (production, dry-run)')" FAIL "red: admitted unsigned image fails"
assert_match "$(detail_of 'unsigned image denied (production, dry-run)')" "^UNSIGNED IMAGE ADMITTED in prod1/dp-default-demo-production-1234" "red: admitted detail"
assert_eq "$(result_of 'hello-world 200 in staging')" FAIL "red: unreachable staging"
assert_match "$(detail_of 'hello-world 200 in staging')" "^000 http://staging" "red: 000 when unreachable"
assert_eq "$(result_of 'hello-world 200 in production')" "PENDING #54" "red: production known-pending (#54)"
assert_eq "$(result_of 'hello-world PDB/spread/priority in production')" FAIL "red: production without PDB fails"
assert_eq "$(result_of 'latest promotion gate passed')" "PENDING #54" "red: failed gate known-pending (#54)"
assert_eq "$(detail_of 'latest promotion gate passed')" "gate-new: failed" "red: failed gate detail"
assert_eq "$(result_of 'in-cluster build succeeded')" FAIL "red: no build run -> FAIL (no PENDING since #17 closed)"
assert_eq "$(detail_of 'Falco running (dev1)')" "not ready: falco 0/1, falco-falcosidekick 0/1" "red: falco not ready"
assert_eq "$(result_of 'cluster name in Falco events')" FAIL "red: cluster name must match exactly (cluster:prod1x is not prod1)"
assert_eq "$(detail_of 'ClusterSecretStores Ready (mgmt)')" "not Ready: mgmt-fleet" "red: store not ready"
assert_match "$(detail_of 'hello-world reads GREETING_SECRET from OpenBao')" "ExternalSecret is 'ClusterSecretStore/default 15s True'" "red: app secret on another store fails"
assert_match "$OUT" $'\n14 PASS, 15 FAIL, 2 PENDING$' "red: summary"

run red-strict DEMO_STRICT=1
assert_eq "$(result_of 'hello-world 200 in production')" FAIL "strict: known-pending becomes FAIL"
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" FAIL "strict: absent OpenBao addon FAILs (#19 closed)"
assert_match "$OUT" $'\n14 PASS, 17 FAIL, 0 PENDING$' "strict: summary"

# ---- fresh stack (#200) ---------------------------------------------------------------------------------------------
# A clean bootstrap: development serves (auto-build rebuilt the Workload's commit); staging/production pin release names
# of the previous stack -> PENDING with the reason, not FAIL. Any other non-200 still FAILs.
cp -R "$TMP/fix/green" "$TMP/fix/fresh"; FIX="$TMP/fix/fresh"
printf '404' > "$FIX/http.staging-default.dev1.apps.localhost"
printf '404' > "$FIX/http.production-default.prod1.apps.localhost"
rm "$FIX/prod1.resilience-deploy" "$FIX/prod1.resilience-pdb"   # nothing promoted to production yet
printf 'hello-world development hello-world-6df447bf6 Ready\nhello-world staging hello-world-77ff9dc697 ComponentReleaseNotFound\nother production other-1 ComponentReleaseNotFound\nhello-world production hello-world-77ff9dc697 ComponentReleaseNotFound\n' \
  > "$FIX/k3d-platform-mgmt.bindings"
run fresh
assert_eq "$RC" 0 "fresh: unpromoted staging/production do not fail the pre-flight"
assert_eq "$(result_of 'hello-world 200 in staging')" PENDING "fresh: staging not promoted in this stack -> PENDING"
assert_eq "$(detail_of 'hello-world 200 in staging')" '404: not promoted in this stack yet - staging pins hello-world-77ff9dc697, not a ComponentRelease of this stack (promote: docs/demo.md "After a clean bootstrap")' "fresh: says why and what to do"
assert_eq "$(result_of 'hello-world 200 in production')" PENDING "fresh: production likewise"
assert_eq "$(result_of 'hello-world 200 in development')" PASS "fresh: development serves"
assert_eq "$(result_of 'hello-world PDB/spread/priority in production')" PENDING "fresh: resilience waits for the production promotion"
assert_eq "$(result_of 'hello-world reads GREETING_SECRET from OpenBao')" PASS "fresh: development app secret still checked"
printf 'hello-world staging hello-world-77ff9dc697 Ready\n' > "$FIX/k3d-platform-mgmt.bindings"
run fresh-ready
assert_eq "$(result_of 'hello-world 200 in staging')" FAIL "fresh: a binding with its release that does not serve still FAILs"
rm "$FIX/k3d-platform-mgmt.bindings"
run fresh-none
assert_eq "$(result_of 'hello-world 200 in staging')" FAIL "fresh: no binding -> FAIL"

# ---- API server down ------------------------------------------------------------------------------------------------
FIX="$TMP/fix/down"; mkdir -p "$FIX"
for k in apps cluster-names clusters dataplanes componenttypes envs workflowruns stores; do
  printf 'The connection to the server was refused\n' > "$FIX/k3d-platform-mgmt.$k"; printf '1' > "$FIX/k3d-platform-mgmt.$k.rc"
done
run down
assert_eq "$RC" 1 "down: exit 1"
assert_eq "$(result_of 'Argo CD apps Synced/Healthy')" FAIL "down: an empty or failed listing never passes"
assert_match "$OUT" "workload clusters: none" "down: no workload clusters"

# ---- context koorikla -----------------------------------------------------------------------------------------------
FIX="$TMP/fix/green"
run koorikla KUBE_CTX=koorikla
assert_eq "$RC" 2 "koorikla: refused (exit 2)"
assert_match "$OUT" "refusing context 'koorikla'" "koorikla: says why"
assert_eq "$CALLS" "" "koorikla: no command ran"

finish
