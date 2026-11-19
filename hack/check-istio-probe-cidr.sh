#!/usr/bin/env bash
# Verify addons/mesh/values.yaml ambient.probeSourceCIDRs against upstream istio/istio source
# (cni/pkg/nodeagent/options.go) at the Istio version pinned in addons/mesh/Chart.yaml (#287).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)

chart="$ROOT/addons/mesh/Chart.yaml"
values="$ROOT/addons/mesh/values.yaml"
src_path="cni/pkg/nodeagent/options.go"

tag=$(yq '.dependencies[] | select(.name == "cni") | .version' "$chart")
app_ver=$(yq '.appVersion' "$chart")
if [[ -z "$tag" || "$tag" == "null" ]]; then
  echo "FAIL: could not read cni dependency version from addons/mesh/Chart.yaml" >&2
  exit 1
fi
if [[ "$app_ver" != "$tag" ]]; then
  echo "FAIL: addons/mesh/Chart.yaml appVersion ($app_ver) != cni dependency version ($tag)" >&2
  exit 1
fi

if command -v gh >/dev/null 2>&1 && src=$(gh api "repos/istio/istio/contents/${src_path}?ref=${tag}" --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null) && [[ -n "$src" ]]; then
  :
elif src=$(curl -fsSL "https://raw.githubusercontent.com/istio/istio/${tag}/${src_path}" 2>/dev/null) && [[ -n "$src" ]]; then
  :
else
  echo "FAIL: could not fetch istio/istio ${src_path} at ref ${tag}" >&2
  exit 1
fi

v4=$(printf '%s\n' "$src" | sed -n 's/^[[:space:]]*DefaultHostProbeSNATIP[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')
v6=$(printf '%s\n' "$src" | sed -n 's/^[[:space:]]*DefaultHostProbeSNATIPV6[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$v4" || -z "$v6" ]]; then
  echo "FAIL: DefaultHostProbeSNATIP/DefaultHostProbeSNATIPV6 not found in istio/istio@${tag}:${src_path}" >&2
  exit 1
fi

want=$(printf '%s/32\n%s/128\n' "$v4" "$v6")
got=$(yq '.ambient.probeSourceCIDRs[]' "$values")
if [[ "$got" != "$want" ]]; then
  echo "FAIL: addons/mesh/values.yaml ambient.probeSourceCIDRs does not match istio/istio@${tag}:${src_path}" >&2
  echo "  expected: ${want//$'\n'/, }" >&2
  echo "  actual:   ${got//$'\n'/, }" >&2
  exit 1
fi

echo "OK: addons/mesh/values.yaml ambient.probeSourceCIDRs matches istio/istio@${tag}:${src_path} (${v4}/32, ${v6}/128)"
