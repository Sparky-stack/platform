#!/usr/bin/env bash
# Falco escalation identity (#47): every cluster sends with its own token, and addon argo-events accepts exactly that
# token on exactly that cluster's endpoint. The three ESO templates involved are rendered as Argo CD would (charts/platform
# -> addon ApplicationSets / fleet charts), then executed by Helm's own template engine (Go text/template + sprig, the
# engine ESO v2 uses) with a sample store key, and compared:
#   receiver  addon argo-events  Secret falco-webhook key <cluster>       + EventSource endpoint /falco/<cluster>
#   sender    addon falco (mgmt)  Secret falcosidekick-escalation         (store platform)
#   sender    charts/cluster      CRS payload falcosidekick-escalation    (each workload cluster; provider byo: the
#                                 pushed Secret <cluster>-falco-escalation)
# Also: the store's token is never copied to workload clusters (workloadSeed) and never read by a workload's falco.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

echo "== test_falco_tokens =="
URL="http://events.example.test:8080/falco/"   # trailing slash on purpose: senders trim it
TOKEN="sample-store-token"

mkdir -p "$TMP/eval/templates"
printf 'apiVersion: v2\nname: eval\nversion: 0.0.0\n' > "$TMP/eval/Chart.yaml"
# eso_eval <ESO template> -> its value for the sample store key (url, token), via Helm's template engine
eso_eval() {
  local d="$TMP/eval" t
  t=${1//.token/.Values.token}; t=${t//.url/.Values.url}
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: { name: v }\ndata:\n  v: |-\n    %s\n' "$t" > "$d/templates/v.yaml"
  helm template e "$d" --set-string "token=$TOKEN,url=$URL" | yq -r '.data.v'
}
b64d() { py -c 'import base64,sys; print(base64.b64decode(sys.argv[1]).decode())' "$1"; }

for inst_dir in installations/*; do
  [[ -f "$inst_dir/installation.yaml" ]] || continue
  inst=$(basename "$inst_dir")
  prender="$TMP/platform-$inst.yaml"
  render_platform "$inst" "$prender"
  m_name=$(yq -r '.mgmt.name // "mgmt"' "$inst_dir/installation.yaml")
  m_prov=$(yq -r '.mgmt.provider // "docker"' "$inst_dir/installation.yaml")

  # receiver
  ae="$TMP/ae-$inst.yaml"
  render_layered_addon "$inst" argo-events "$ae" "$prender" mgmt "$m_name" "$m_prov" mgmt local flannel https://kubernetes.default.svc
  es=$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "falco-webhook")' "$ae")
  assert_eq "$(yq -r '.spec.data[0].remoteRef.key + "/" + .spec.data[0].remoteRef.property' <<<"$es")" falco-webhook/token "$inst: receiver reads the store token"
  fleet=$(addon_fleet_names "$inst_dir"); fleet=${fleet#\{}; fleet=${fleet%\}}
  tokens=""

  for c in ${fleet//,/ }; do
    want=$(eso_eval "$(C="$c" yq -r '.spec.target.template.data[strenv(C)]' <<<"$es")")
    assert_match "$want" '^[0-9a-f]{64}$' "$inst/$c: receiver token is a sha256 hex"
    assert_eq "$(C="$c" yq -r 'select(.kind == "EventSource" and .metadata.name == "platform") | .spec.webhook["falco-" + strenv(C)] | .endpoint + " " + .authSecret.name + "/" + .authSecret.key' "$ae")" \
      "/falco/$c falco-webhook/$c" "$inst/$c: endpoint /falco/$c accepts only key $c"

    if [[ "$c" == "$m_name" ]]; then
      render_layered_addon "$inst" falco "$TMP/falco-$inst-mgmt.yaml" "$prender" mgmt "$m_name" "$m_prov" mgmt local flannel https://kubernetes.default.svc
      fo=$(yq 'select(.kind == "ExternalSecret" and .metadata.name == "falcosidekick-escalation")' "$TMP/falco-$inst-mgmt.yaml")
      header=$(eso_eval "$(yq -r '.spec.target.template.data.WEBHOOK_CUSTOMHEADERS' <<<"$fo")")
      address=$(eso_eval "$(yq -r '.spec.target.template.data.WEBHOOK_ADDRESS' <<<"$fo")")
    else
      render_cluster "$inst" "$c" "$TMP/cluster-$inst-$c.yaml"
      byo=$(C="$c" yq 'select(.kind == "ExternalSecret" and .metadata.name == strenv(C) + "-falco-escalation" and (.spec.target.template.data | has("WEBHOOK_ADDRESS")))' "$TMP/cluster-$inst-$c.yaml")
      if [[ -n "$byo" ]]; then
        # provider byo: the Secret itself, pushed as is (charts/cluster byo.pushSecret)
        header=$(eso_eval "$(yq -r '.spec.target.template.data.WEBHOOK_CUSTOMHEADERS' <<<"$byo")")
        address=$(eso_eval "$(yq -r '.spec.target.template.data.WEBHOOK_ADDRESS' <<<"$byo")")
      else
        crs=$(yq -r 'select(.kind == "ExternalSecret" and (.spec.target.template.data | has("falco-escalation.yaml"))) | .spec.target.template.data["falco-escalation.yaml"]' "$TMP/cluster-$inst-$c.yaml")
        # the payload is an ESO template, not YAML yet: take the value text after the key
        header=$(b64d "$(eso_eval "$(sed -n 's/^ *WEBHOOK_CUSTOMHEADERS: //p' <<<"$crs")")")
        address=$(b64d "$(eso_eval "$(sed -n 's/^ *WEBHOOK_ADDRESS: //p' <<<"$crs")")")
      fi
    fi
    assert_eq "$header" "Authorization:Bearer $want" "$inst/$c: sender's bearer token == the receiver's key $c"
    assert_eq "$address" "${URL%/}/$c" "$inst/$c: sender posts to its own endpoint"
    tokens="$tokens$want"$'\n'
  done
  assert_eq "$(printf '%s' "$tokens" | sort -u | grep -c .)" "$(printf '%s' "$tokens" | grep -c .)" "$inst: one distinct token per cluster"

  # the store token stays on mgmt
  seeds=$(yq -r '(.secrets.workloadSeed.keys // []) | join(",")' "$inst_dir/installation.yaml")
  assert_eq "$(printf '%s' ",$seeds," | grep -c ',falco-webhook,' || true)" 0 "$inst: falco-webhook is not seeded to workload clusters"
  for cf in "$inst_dir"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c=$(yq -r '.name' "$cf")
    render_layered_addon "$inst" falco "$TMP/falco-$inst-$c.yaml" "$prender" workload "$c" "$(yq -r '.provider // "docker"' "$cf")" env local cilium https://192.0.2.10:6443
    reads=$(yq -r 'select(.kind == "ExternalSecret") | .spec.data[].remoteRef.key' "$TMP/falco-$inst-$c.yaml" | grep -c '^falco-webhook$' || true)
    assert_eq "$reads" 0 "$inst/$c: the workload's falco never reads store key falco-webhook"
  done
done
finish
