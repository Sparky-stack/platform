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
  *" apply "*)
    body=\$(cat)
    case "\$a" in *" --dry-run=server "*) ;; *) echo "stub: apply without --dry-run=server" >&2; exit 98 ;; esac
    if [[ "\$body" == *"$UNSIGNED"* ]]; then k=apply-unsigned; else k=apply-signed; fi ;;
  *" get --raw "*k8s_cluster_name*) k=prom-clusters ;;
  *" get --raw "*kube_pod_labels*) k=prom-app ;;
  *" get applications.argoproj.io "*) k=apps ;;
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
  *" get clusterworkflows.openchoreo.dev "*) k=clusterworkflow ;;
  *" get imagevalidatingpolicies"*) k=policies ;;
  *" get daemonsets,deployments "*) k=falco ;;
  *" get deployment -n falco falco-falcosidekick "*) k=sidekick-fields ;;
  *" get sensors.argoproj.io "*) k=sensor ;;
  *" get workflowtemplates.argoproj.io "*) k=falco-response ;;
  *" get certificates.cert-manager.io "*) k=mesh-certs ;;
  *" get clustersecretstores.external-secrets.io "*) k=stores ;;
  *" get compositeresourcedefinitions"*) k=xrds ;;
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
  printf 'root Synced Healthy\nharbor-mgmt Synced Healthy\nfalco-dev1 Synced Healthy\n' > "$d/k3d-platform-mgmt.apps"
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
assert_eq "$(detail_of 'Argo CD apps Synced/Healthy')" "3/3 Synced/Healthy" "green: argo apps detail"
assert_eq "$(result_of 'CAPI clusters Provisioned')" PASS "green: clusters"
assert_eq "$(detail_of 'OpenChoreo data planes connected')" "connected: dev1(1 agent), prod1(1 agent)" "green: data planes"
assert_match "$(detail_of 'cluster files render for other providers')" "^renders: aws-example/dev-euc1\(aws\), aws-example/prod-euc1\(aws\)$" "green: render other providers (local skipped)"
assert_eq "$(result_of 'Backstage console responds')" PASS "green: console"
assert_eq "$(detail_of 'component types for self-service')" "2: service, worker" "green: component types"
assert_eq "$(result_of 'latest image signed (cosign, pinned identity)')" PASS "green: cosign"
assert_match "$(detail_of 'latest image signed (cosign, pinned identity)')" "^ghcr.io/koorikla/hello-world:abc1234@sha256:889643d395ab\.\.\. signed by container.yaml@[0-9a-f]{7} \(koorikla/hello-world, refs/heads/main, push\)$" "green: cosign detail (digest shortened)"
WREF=$(yq '.imageVerification.github.workflowRef' "$ROOT/addons/kyverno-policies/values.yaml")
cos=$(printf '%s\n' "$CALLS" | grep '^cosign verify ' || true)
assert_match "$cos" "--certificate-identity https://github.com/koorikla/ci/.github/workflows/container.yaml@$WREF " "green: cosign uses the pinned workflow identity"
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
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" "PENDING #19" "green: OpenBao addon absent -> PENDING #19"
assert_eq "$(detail_of 'OpenBao-issued mesh certificates')" "OpenBao / istio-csr addon not installed" "green: pending detail without the issue prefix"
assert_eq "$(result_of 'ClusterSecretStores Ready (mgmt)')" PASS "green: stores mgmt"
assert_eq "$(result_of 'PostgreSQL claim API')" "PENDING #91" "green: no XRD -> PENDING #91"
assert_match "$OUT" $'\n27 PASS, 0 FAIL, 2 PENDING$' "green: summary"

# OpenBao addon and PostgreSQL XRD present: the checks run instead of PENDING.
cp -R "$FIX" "$TMP/fix/addons"; FIX="$TMP/fix/addons"
printf 'root Synced Healthy\nopenbao-mgmt Synced Healthy\nistio-csr-dev1 Synced Healthy\n' > "$FIX/k3d-platform-mgmt.apps"
printf 'istiod True\n' > "$FIX/dev1.mesh-certs"
printf 'istiod False\n' > "$FIX/prod1.mesh-certs"
printf 'postgresqls.platform.koorikla.io True\nkafkas.platform.koorikla.io True\n' > "$FIX/k3d-platform-mgmt.xrds"
run addons
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" FAIL "addons: a not-Ready mesh certificate fails"
assert_eq "$(detail_of 'OpenBao-issued mesh certificates')" "mesh certificates not Ready on: prod1" "addons: names the cluster"
assert_eq "$(result_of 'PostgreSQL claim API')" PASS "addons: XRD Established"
assert_eq "$(detail_of 'PostgreSQL claim API')" "XRD Established: postgresqls.platform.koorikla.io" "addons: only postgres XRDs"
assert_eq "$RC" 1 "addons: a FAIL exits 1"

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
rm "$FIX/http.staging-default.dev1.apps.localhost"
printf 'ImageValidatingPolicy openchoreo-verify-images-enforce false\nValidatingPolicy disallow-host-path true\n' > "$FIX/dev1.policies"
printf 'DaemonSet falco 1 0\nDeployment falco-falcosidekick 1\n' > "$FIX/dev1.falco"
printf 'cluster:prod1x' > "$FIX/prod1.sidekick-fields"
printf '2026-11-16T19:04:37Z gate-new promotion-gate /True\n' > "$FIX/k3d-platform-mgmt.workflowruns"
printf '1' > "$FIX/cosign.rc"
printf 'platform True\nmgmt-fleet False\n' > "$FIX/k3d-platform-mgmt.stores"
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
assert_eq "$(result_of 'latest promotion gate passed')" "PENDING #54" "red: failed gate known-pending (#54)"
assert_eq "$(detail_of 'latest promotion gate passed')" "gate-new: failed" "red: failed gate detail"
assert_eq "$(result_of 'in-cluster build succeeded')" "PENDING #17" "red: no build run -> known-pending (#17)"
assert_eq "$(detail_of 'Falco running (dev1)')" "not ready: falco 0/1, falco-falcosidekick 0/1" "red: falco not ready"
assert_eq "$(result_of 'cluster name in Falco events')" "PENDING #47" "red: cluster name known-pending (#47), no prefix match"
assert_eq "$(detail_of 'ClusterSecretStores Ready (mgmt)')" "not Ready: mgmt-fleet" "red: store not ready"
assert_match "$OUT" $'\n14 PASS, 9 FAIL, 6 PENDING$' "red: summary"

run red-strict DEMO_STRICT=1
assert_eq "$(result_of 'hello-world 200 in production')" FAIL "strict: known-pending becomes FAIL"
assert_eq "$(result_of 'OpenBao-issued mesh certificates')" "PENDING #19" "strict: absent feature stays PENDING"
assert_match "$OUT" $'\n14 PASS, 13 FAIL, 2 PENDING$' "strict: summary"

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
