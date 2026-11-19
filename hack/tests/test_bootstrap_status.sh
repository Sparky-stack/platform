#!/usr/bin/env bash
# bootstrap/bootstrap.sh never prints the Argo CD admin password: `status` (also the end of `up`) and `ui` print the
# command that reads it. A fake kubectl answers argocd-initial-admin-secret with a sentinel; it must not appear in the
# output, decoded or encoded. Output of these commands lands in terminals, CI logs and agent transcripts.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bootstrap_harness

SENTINEL=SentinelAdminPw4711
SENTINEL_B64=$(printf '%s' "$SENTINEL" | base64)
cat > "$BIN/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "kubectl \$*" >> "\$HLOG/calls"
for a in "\$@"; do [[ "\$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }; done
case " \$* " in
  *" argocd-initial-admin-secret "*) printf '%s' "$SENTINEL_B64"; exit 0 ;;
  *" port-forward "*) echo "Forwarding from 127.0.0.1:8081 -> 8080"; exit 0 ;;
  *" get "*) echo "NAME   STATUS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/"*

run() {
  local name=$1
  run_isolated "$name" "$R/bootstrap/bs.sh" KUBE_CTX=fake INST=local NO_BROWSER=1 HARNESS_CALL="$2"
  assert_eq "$RC" 0 "$name: rc"
  assert_eq "$(grep -cE "$SENTINEL|$SENTINEL_B64" "$HLOG/out" || true)" 0 "$name: admin password not printed (plain or base64)"
  assert_match "$OUT" "get secret argocd-initial-admin-secret -o jsonpath='\{\.data\.password\}' \| base64 --decode" \
    "$name: prints the command that reads the password"
  assert_match "$OUT" "--context fake" "$name: the printed command names the installation's context"
  assert_eq "$(grep -c 'argocd-initial-admin-secret' "$HLOG/calls" || true)" 0 "$name: the secret is not even read"
}

run status cmd_status
run ui cmd_ui

# Static: the secret name appears in bootstrap.sh only inside the printed hint, never in an executed kubectl/b64dec.
hits=$(grep -n 'argocd-initial-admin-secret' "$ROOT/bootstrap/bootstrap.sh" | grep -v "printf '%s\\\\n' \"Argo CD admin password" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'The secret is gone' || true)
assert_eq "$hits" "" "bootstrap.sh reads argocd-initial-admin-secret nowhere"

finish
