#!/usr/bin/env bash
# bootstrap/bootstrap.sh never prints the Argo CD admin password: `status` (also the end of `up`) and `ui` print the
# command that reads it. A fake kubectl answers argocd-initial-admin-secret with a sentinel; it must not appear in the
# output, decoded or encoded. Output of these commands lands in terminals, CI logs and agent transcripts.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_bootstrap_status =="

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
  local name=$1 call=$2
  HLOG="$TMP/out/$name"; mkdir -p "$HLOG"; : > "$HLOG/calls"
  if env -i HOME="$HOME" PATH="$BIN:/usr/bin:/bin" SYSTEMROOT="${SYSTEMROOT:-}" TMPDIR="$TMP" HLOG="$HLOG" \
      KUBE_CTX=fake INST=local NO_BROWSER=1 HARNESS_CALL="$call" "$BASH" "$R/bootstrap/bs.sh" > "$HLOG/out" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  OUT=$(sed 's/\x1b\[[0-9;]*m//g' "$HLOG/out")
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
