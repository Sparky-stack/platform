#!/usr/bin/env bash
# bootstrap/bootstrap.sh `down` against fake kubectl, docker and k3d: no cluster is contacted. Argo CD is frozen
# (application + applicationset controllers at 0) BEFORE the CAPI Clusters are deleted, the Clusters go before the k3d
# mgmt, leftover CAPD containers are removed only for the installation's clusters, and only the local context is used.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_bootstrap_down =="

REAL_YQ=$(mise which yq 2>/dev/null || command -v yq)
[[ -x "$REAL_YQ" ]] || { echo "  yq not found" >&2; exit 1; }

R="$TMP/root"; BIN="$TMP/bin"
mkdir -p "$R/bootstrap" "$R/hack" "$BIN"
cp -R "$ROOT/hack/lib" "$R/hack/"
cp -R "$ROOT/installations" "$R/"
sed '/^case "\$CMD" in$/,$d' "$ROOT/bootstrap/bootstrap.sh" > "$R/bootstrap/bs.sh"
# shellcheck disable=SC2016  # literal code for the generated script
printf '%s\n' 'load_inst; eval "$HARNESS_CALL"' >> "$R/bootstrap/bs.sh"
printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$REAL_YQ" > "$BIN/yq"

# Fake kubectl: FAKE_FLEET=1 -> ns fleet exists with Clusters dev1 + prod1; FAKE_DELETE_FAIL=1 -> delete times out.
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "kubectl $*" >> "$HLOG/calls"
for a in "$@"; do [[ "$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }; done
args=" $* "
case "$args" in
  *" get ns fleet "*|*" get ns argocd "*) [[ "${FAKE_FLEET:-}" == 1 ]]; exit $? ;;
  *" get clusters.cluster.x-k8s.io "*) [[ "${FAKE_FLEET:-}" == 1 ]] && printf 'dev1\nprod1\n'; exit 0 ;;
  *" delete clusters.cluster.x-k8s.io "*) [[ "${FAKE_DELETE_FAIL:-}" == 1 ]] && exit 1; exit 0 ;;
  *" scale "*|*" wait "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
# Fake docker: `ps -aq --filter label=io.x-k8s.kind.cluster=<c>` answers ids for clusters in FAKE_LEFTOVERS.
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >> "$HLOG/calls"
if [[ "$1" == ps ]]; then
  for a in "$@"; do
    case "$a" in label=io.x-k8s.kind.cluster=*)
      c=${a#label=io.x-k8s.kind.cluster=}
      [[ " ${FAKE_LEFTOVERS:-} " == *" $c "* ]] && printf 'id-%s-0\nid-%s-1\n' "$c" "$c" ;;
    esac
  done
fi
exit 0
EOF
cat > "$BIN/k3d" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "k3d $*" >> "$HLOG/calls"
EOF
chmod +x "$BIN/"*

run() {
  local name=$1 call=$2; shift 2
  HLOG="$TMP/out/$name"; mkdir -p "$HLOG"; : > "$HLOG/calls"
  if env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" SYSTEMROOT="${SYSTEMROOT:-}" TMPDIR="$TMP" HLOG="$HLOG" \
      KUBE_CTX=fake INST="${RUN_INST:-local}" HARNESS_CALL="$call" "$@" "$BASH" "$R/bootstrap/bs.sh" > "$HLOG/out" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$HLOG/out")
  assert_eq "$(grep -c -- '--context fake' "$HLOG/calls" || true)" "$(grep -c '^kubectl' "$HLOG/calls" || true)" "$name: only the fake context"
}
# line <pattern> -> first line number in calls matching the ERE (0 if none)
line() { local n; n=$(grep -nE -- "$1" "$HLOG/calls" | head -1 | cut -d: -f1); printf '%s' "${n:-0}"; }
count() { grep -cE -- "$1" "$HLOG/calls" || true; }

SCALE_AC='-n argocd scale statefulset/argocd-application-controller --replicas=0'
SCALE_AS='-n argocd scale deployment/argocd-applicationset-controller --replicas=0'
DELETE='delete clusters.cluster.x-k8s.io -n fleet --all'

# --- clusters present: freeze, then delete Clusters, then k3d ------------------------------------------------------
run fleet cmd_down FAKE_FLEET=1
assert_eq "$RC" 0 "fleet: rc"
assert_eq "$(count "$SCALE_AC")" 1 "fleet: application-controller scaled to 0"
assert_eq "$(count "$SCALE_AS")" 1 "fleet: applicationset-controller scaled to 0"
ac=$(line "$SCALE_AC"); as=$(line "$SCALE_AS"); del=$(line "$DELETE"); k3d=$(line '^k3d cluster delete platform-mgmt')
assert_eq "$(( ac > 0 && as > 0 && del > ac && del > as ))" 1 "fleet: Argo CD frozen before the Clusters are deleted"
assert_eq "$(( $(line 'wait --for=delete pod') > as && $(line 'wait --for=delete pod') < del ))" 1 "fleet: waits for the controller pods to go before deleting"
assert_eq "$(( k3d > del ))" 1 "fleet: Clusters deleted before the k3d mgmt"
assert_match "$(grep -E -- "$DELETE" "$HLOG/calls")" '--wait=true --timeout=5m' "fleet: waits for CAPI deletion (default 5m)"
assert_eq "$(count '^docker rm')" 0 "fleet: no leftovers, nothing removed"
assert_match "$OUT" 'dev1 prod1' "fleet: names the clusters it deletes"

# --- CAPI deletion times out: warn, remove only the installation's CAPD containers --------------------------------
run timeout cmd_down FAKE_FLEET=1 FAKE_DELETE_FAIL=1 FAKE_LEFTOVERS="dev1 other-kind" DOWN_TIMEOUT=1s
assert_eq "$RC" 0 "timeout: rc (teardown continues)"
assert_match "$OUT" 'did not finish within 1s' "timeout: warns"
assert_eq "$(count '^docker rm -f id-dev1-0 id-dev1-1$')" 1 "timeout: dev1 leftovers removed"
assert_eq "$(count 'other-kind')" 0 "timeout: other kind clusters on the host untouched"
assert_eq "$(( $(line '^docker rm') < $(line '^k3d cluster delete') ))" 1 "timeout: leftovers removed before the k3d mgmt"

# --- mgmt unreachable / no fleet: no freeze, fleet files still drive the leftover sweep --------------------------
run nofleet cmd_down FAKE_LEFTOVERS=prod1
assert_eq "$RC" 0 "nofleet: rc"
assert_eq "$(count ' scale ')" 0 "nofleet: nothing to freeze"
assert_eq "$(count "$DELETE")" 0 "nofleet: no Cluster delete"
assert_eq "$(count '^docker rm -f id-prod1-0 id-prod1-1$')" 1 "nofleet: prod1 leftover (from installations/local/clusters) removed"
assert_eq "$(count '^k3d cluster delete platform-mgmt')" 1 "nofleet: k3d mgmt deleted"

# --- only the local installation ---------------------------------------------------------------------------------
RUN_INST=aws-example run cloud cmd_down FAKE_FLEET=1
assert_eq "$RC" 1 "cloud: refused"
assert_eq "$(count '.')" 0 "cloud: no command run"

finish
