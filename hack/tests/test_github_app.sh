#!/usr/bin/env bash
# Contract: hack/github-app.py, the manifest flow for the platform write GitHub App (docs/forking.md credentials (c),
# docs/project-templates.md "Repository creation").
#   - the manifest asks for exactly the (c) permissions (no extra rights), no events, an inactive webhook, and is
#     public (installable on the org of the new repos and on the platform repo's owner);
#   - the redirect URL follows --public-url; plain http is refused unless it is loopback (the one-time code that
#     exchanges for the private key must not cross a network in clear text);
#   - the callback refuses a wrong `state` without calling GitHub (no CSRF code injection), and the page is served at
#     / and under the /ghapp tunnel path.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

cd "$ROOT"
G=hack/github-app.py

m=$(python3 "$G" manifest --org Example-org)
assert_eq "$(jq -c '.default_permissions' <<<"$m")" \
  '{"administration":"write","contents":"write","metadata":"read","pull_requests":"write","workflows":"write"}' \
  "manifest permissions are exactly credentials (c)"
assert_eq "$(jq -c '.default_events' <<<"$m")" '[]' "manifest subscribes to no events"
assert_eq "$(jq -r '.hook_attributes.active' <<<"$m")" "false" "webhook inactive"
assert_eq "$(jq -r '.public' <<<"$m")" "true" "App installable on a second account"
assert_eq "$(jq -r '.name' <<<"$m")" "Example-org-scaffolder" "App name derives from the org"
assert_eq "$(jq -r '.redirect_url' <<<"$m")" "http://127.0.0.1:8765/callback" "default redirect is loopback"
assert_eq "$(python3 "$G" manifest --org o --public-url https://host.example:8443/ghapp/ | jq -r .redirect_url)" \
  "https://host.example:8443/ghapp/callback" "redirect follows --public-url"

# Negative: clear-text redirect off loopback is refused.
capture python3 "$G" manifest --org o --public-url http://host.example
assert_eq "$([[ $RC -ne 0 ]] && echo refused)" refused "http public URL off loopback refused"

# Callback: wrong state -> 400 before any GitHub call; page served at / and /ghapp/.
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/8765") 2>/dev/null; }
if command -v curl >/dev/null && port_free; then
  GITHUB_APP_KEYS_DIR="$TMP/keys" python3 "$G" create --org Example-org >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do curl -fs -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.1; done
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8765/callback?code=x&state=wrong')" "400" \
    "callback rejects a wrong state"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8765/ghapp/callback?code=x')" "400" \
    "callback rejects a missing state"
  assert_eq "$(curl -s http://127.0.0.1:8765/ghapp/ | grep -c 'settings/apps/new?state=')" "1" \
    "form posts to the org's new-App page with a state"
  assert_eq "$(find "$TMP/keys" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" "no key file written on rejected callbacks"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
else
  echo "  skip: callback checks (curl missing or port 8765 busy)"
fi

finish
