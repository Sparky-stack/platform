#!/usr/bin/env bash
# external-dns end to end through the catalog: for each installation, render charts/platform, then the addon on mgmt and
# every cluster exactly as its ApplicationSet would (hack/lib/addons.sh) with the opt-in toggle forced on. Checks the DNS
# provider follows installation.yaml dns.provider (not the infra provider), zones and TXT owner arrive as parameters,
# credentials come from the right store, and misconfigurations fail the render instead of running.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

echo "== test_external_dns =="
NS=$(yq '.addons["external-dns"].namespace' "$ADDONS_CATALOG")
SAMPLE_SERVER=https://192.0.2.10:6443

# render <inst dir> <platform render> <role> <name> <provider> <out> -> 0/1 (stderr kept in <out>.err)
render() {
  local inst_dir=$1 prender=$2 role=$3 name=$4 prov=$5 out=$6
  local -a args=()
  read_lines args addon_helm_args external-dns "$inst_dir" "$prender" "$role" "$name" "$prov" env region flannel "$SAMPLE_SERVER"
  helm template external-dns addons/external-dns --namespace "$NS" "${args[@]}" > "$out" 2> "$out.err"
}
args_of() { yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[]' "$1" | tr -d '"'; }
# Captured first: `args_of | grep -q` under pipefail fails at random when grep exits early and tr gets SIGPIPE.
has_arg() { local a; a=$(args_of "$1"); if grep -qx -- "$2" <<<"$a"; then echo yes; else echo no; fi; }

expect_running() {   # expect_running <inst> <dns provider> <helm provider> <expected store on mgmt>
  local inst=$1 dnsp=$2 hp=$3 inst_dir="installations/$1" prender="$TMP/platform-$1.yaml" cf name prov role out zone
  render_platform "$inst" "$prender"
  assert_eq "$(yq '.dns.provider' "$inst_dir/installation.yaml")" "$dnsp" "$inst: dns.provider"
  zone=$(yq '.dns.domainFilters[0]' "$inst_dir/installation.yaml")
  for cf in mgmt "$inst_dir"/clusters/*.yaml; do
    if [[ "$cf" == mgmt ]]; then
      role=mgmt name=$(yq '.mgmt.name' "$inst_dir/installation.yaml") prov=$(yq '.mgmt.provider' "$inst_dir/installation.yaml")
    else
      role=workload name=$(yq '.name' "$cf") prov=$(yq '.provider' "$cf")
    fi
    out="$TMP/edns-$inst-$name.yaml"
    if ! render "$inst_dir" "$prender" "$role" "$name" "$prov" "$out"; then
      assert_eq "render failed: $(head -c 300 "$out.err")" "renders" "$inst/$name: external-dns renders when opted in"
      continue
    fi
    assert_eq "$(has_arg "$out" "--provider=$hp")" yes "$inst/$name ($prov infra): --provider=$hp from dns.provider=$dnsp"
    assert_eq "$(has_arg "$out" "--domain-filter=$zone")" yes "$inst/$name: zone from installation.yaml"
    assert_eq "$(args_of "$out" | grep -c -- '^--domain-filter=')" "$(yq '.dns.domainFilters | length' "$inst_dir/installation.yaml")" "$inst/$name: only the installation's zones"
    assert_eq "$(has_arg "$out" "--txt-owner-id=$inst-$name")" yes "$inst/$name: TXT owner is <installation>-<cluster>"
    if [[ "$role" == mgmt ]]; then
      assert_eq "$(has_arg "$out" "--gateway-label-filter=platform.koorikla.io/public-dns=true")" yes "$inst/$name: mgmt publishes only Gateways labelled public"
    else
      assert_eq "$(has_arg "$out" "--gateway-name=gateway-default")$(has_arg "$out" "--gateway-namespace=openchoreo-data-plane")" yesyes "$inst/$name: workload publishes only the data plane Gateway"
    fi
    assert_eq "$(has_arg "$out" "--policy=upsert-only")" yes "$inst/$name: upsert-only by default"
    assert_eq "$(args_of "$out" | grep -c -- '^--source=gateway-')" 3 "$inst/$name: three Gateway API sources"
    assert_eq "$(args_of "$out" | grep -c -E -- '^--source=(ingress|service)$')" 0 "$inst/$name: no Ingress/Service source"
    assert_match "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$out")" '@sha256:[0-9a-f]{64}$' "$inst/$name: image pinned by digest"
    if [[ "$hp" == cloudflare ]]; then
      local want=dns; [[ "$role" == mgmt ]] && want=platform   # never the tenant store default
      assert_eq "$(yq -N 'select(.kind == "ExternalSecret") | .spec.secretStoreRef.name' "$out")" "$want" "$inst/$name: Cloudflare token from store $want"
      assert_eq "$(has_arg "$out" "--aws-zone-type=public")" no "$inst/$name: no AWS flags on Cloudflare"
    else
      assert_eq "$(yq -N 'select(.kind == "ExternalSecret") | .metadata.name' "$out")" "" "$inst/$name: Route 53 via workload identity, no ExternalSecret"
      assert_eq "$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env' "$out")" "null" "$inst/$name: no static AWS keys in env"
    fi
  done
}

expect_running aws-example route53 aws
expect_running hetzner-example cloudflare cloudflare

# Opted in where the installation has no DNS provider (local): the render fails loudly.
render_platform local "$TMP/platform-local.yaml"
if render installations/local "$TMP/platform-local.yaml" workload dev1 docker "$TMP/edns-local.yaml"; then
  assert_eq rendered fails "local/dev1: opting in without dns.provider fails"
else
  assert_match "$(cat "$TMP/edns-local.yaml.err")" 'dns.provider is none' "local/dev1: opting in without dns.provider fails"
fi

# An installation overlay that switches provider or restates zones contradicts installation.yaml: fails.
mkdir -p "$TMP/inst/clusters" "$TMP/inst/addons/external-dns"
cp installations/hetzner-example/installation.yaml "$TMP/inst/"
printf 'external-dns:\n  provider:\n    name: aws\n' > "$TMP/inst/addons/external-dns/values.yaml"
if render "$TMP/inst" "$TMP/platform-hetzner-example.yaml" mgmt mgmt hetzner "$TMP/edns-bad.yaml"; then
  assert_eq rendered fails "overlay switching the provider fails"
else
  assert_match "$(cat "$TMP/edns-bad.yaml.err")" 'requires external-dns.provider.name=cloudflare' "overlay switching the provider fails"
fi
printf 'external-dns:\n  domainFilters: [evil.example.org]\n' > "$TMP/inst/addons/external-dns/values.yaml"
render "$TMP/inst" "$TMP/platform-hetzner-example.yaml" mgmt mgmt hetzner "$TMP/edns-zone.yaml" || true
assert_eq "$(has_arg "$TMP/edns-zone.yaml" "--domain-filter=evil.example.org")" no "overlay zones never beat installation.yaml (parameters win)"

# Overlays cannot widen zones or take over ownership through extraArgs, nor drop the Gateway scope.
for kv in "domain-filter: evil.example.org" "regex-domain-filter: '.*'" "zone-id-filter: Z123" "txt-owner-id: prod-fsn1" "txt-prefix: x-"; do
  printf 'external-dns:\n  extraArgs:\n    %s\n' "$kv" > "$TMP/inst/addons/external-dns/values.yaml"
  if render "$TMP/inst" "$TMP/platform-hetzner-example.yaml" workload dev-fsn1 hetzner "$TMP/edns-arg.yaml"; then
    assert_eq rendered fails "overlay extraArgs ${kv%%:*} is refused"
  else
    assert_match "$(cat "$TMP/edns-arg.yaml.err")" "extraArgs ${kv%%:*} is not allowed" "overlay extraArgs ${kv%%:*} is refused"
  fi
done
printf 'external-dns:\n  extraArgs:\n    gateway-name: null\n    gateway-namespace: null\n' > "$TMP/inst/addons/external-dns/values.yaml"
if render "$TMP/inst" "$TMP/platform-hetzner-example.yaml" workload dev-fsn1 hetzner "$TMP/edns-gw.yaml"; then
  assert_eq rendered fails "overlay dropping the Gateway scope is refused"
else
  assert_match "$(cat "$TMP/edns-gw.yaml.err")" 'must scope the Gateways' "overlay dropping the Gateway scope is refused"
fi

# Standalone (no installation): nothing runs.
render_standalone_addon external-dns "$TMP/edns-standalone.yaml"
assert_eq "$(yq -N 'select(.kind == "Deployment") | .metadata.name' "$TMP/edns-standalone.yaml")" "" "standalone: no Deployment while dns.provider is none"

finish
