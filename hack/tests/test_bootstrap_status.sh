#!/usr/bin/env bash
# bootstrap/bootstrap.sh never prints a password: `status` (also the end of `up`) lists each UI the installation runs
# (Argo CD, plus the OpenChoreo console, Thunder and Harbor when their HTTPRoute exists) with its URL or port-forward
# and the command that reads its login password; `ui` prints the Argo CD one. A fake kubectl answers every Secret read
# with a sentinel: it must not appear in the output, decoded or encoded, and no Secret may even be read. Output of these
# commands lands in terminals, CI logs and agent transcripts.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bootstrap_harness

SENTINEL=SentinelAdminPw4711
SENTINEL_B64=$(printf '%s' "$SENTINEL" | base64)
# FAKE_ROUTES=none: no HTTPRoutes (the addons are not installed). Otherwise the live shapes: Backstage and Thunder on
# the control-plane Gateway (listener http 8080), Harbor on its own Gateway (sectionName https, 9443).
cat > "$BIN/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "kubectl \$*" >> "\$HLOG/calls"
for a in "\$@"; do [[ "\$a" == koorikla ]] && { echo "REFUSED koorikla" >&2; exit 99; }; done
case " \$* " in
  *" secret "*) printf '%s' "$SENTINEL_B64"; exit 0 ;;
  *" httproute "*)
    [[ "\${FAKE_ROUTES:-}" == none ]] && { echo "Error from server (NotFound)" >&2; exit 1; }
    case " \$* " in
      *" backstage "*) printf '%s' 'openchoreo.localhost|gateway-default|openchoreo-control-plane|' ;;
      *" thunder-httproute "*) printf '%s' 'thunder.openchoreo.localhost|gateway-default|openchoreo-control-plane|' ;;
      *" harbor-route "*) printf '%s' 'harbor.openchoreo.localhost|harbor||https' ;;
    esac
    exit 0 ;;
  *" gateway gateway-default "*) printf '%s\n' "http HTTP 8080" "tls-passthrough TLS 8443"; exit 0 ;;
  *" gateway harbor "*) printf '%s\n' "https HTTPS 9443"; exit 0 ;;
  *" port-forward "*) echo "Forwarding from 127.0.0.1:8081 -> 8080"; exit 0 ;;
  *" get "*) echo "NAME   STATUS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/"*

# pw_cmd <ns> <secret> <key>: regex of the printed command that reads one Secret key.
pw_cmd() { printf '%s' "kubectl --context fake -n $1 get secret $2 -o jsonpath='\\{\\.data\\.$3\\}' \\| base64 --decode; echo"; }

run() {
  local name=$1
  run_isolated "$name" "$R/bootstrap/bs.sh" KUBE_CTX=fake INST=local NO_BROWSER=1 HARNESS_CALL="$2" ${3:+"$3"}
  assert_eq "$RC" 0 "$name: rc"
  assert_eq "$(grep -cE "$SENTINEL|$SENTINEL_B64" "$HLOG/out" || true)" 0 "$name: no password printed (plain or base64)"
  assert_eq "$(grep -c ' secret ' "$HLOG/calls" || true)" 0 "$name: no Secret is even read"
  assert_match "$OUT" "$(pw_cmd argocd argocd-initial-admin-secret password)" "$name: Argo CD password command"
}

run status cmd_status
assert_match "$OUT" "http://localhost:8081 via 'task ui' \(= kubectl --context fake port-forward -n argocd svc/argocd-server 8081:80\)" \
  "status: Argo CD port-forward"
assert_match "$OUT" "OpenChoreo console  http://openchoreo\.localhost:8080 " "status: console URL = route host + listener port"
assert_match "$OUT" "user admin@openchoreo\.dev, password: $(pw_cmd thunder thunder-bootstrap admin-user-password)" \
  "status: console user and password command"
assert_match "$OUT" "Thunder console     http://thunder\.openchoreo\.localhost:8080/console" "status: Thunder URL"
assert_match "$OUT" "$(pw_cmd thunder thunder-bootstrap thunder-admin-password)" "status: Thunder password command"
assert_match "$OUT" "Harbor              https://harbor\.openchoreo\.localhost:9443 " "status: Harbor URL (sectionName https)"
assert_match "$OUT" "$(pw_cmd harbor harbor-platform HARBOR_ADMIN_PASSWORD)" "status: Harbor password command"

run status-no-addons cmd_status FAKE_ROUTES=none
assert_eq "$(grep -cE 'OpenChoreo console|Thunder console|Harbor ' "$HLOG/out" || true)" 0 \
  "status: UIs whose route does not exist are not listed"

run ui cmd_ui

# Static: the password Secrets appear in bootstrap.sh only as secret_cmd arguments (which build text), never in an
# executed kubectl.
hits=$(grep -nE 'argocd-initial-admin-secret|thunder-bootstrap|harbor-platform' "$ROOT/bootstrap/bootstrap.sh" \
  | grep -v 'secret_cmd ' | grep -v '^[0-9]*:[[:space:]]*#' || true)
assert_eq "$hits" "" "bootstrap.sh reads the UI password Secrets nowhere"

finish
