#!/usr/bin/env bash
# Multi-arch audit: list every container image the installation runs and check that each one publishes
# linux/amd64 AND linux/arm64 (Apple Silicon, Graviton/Ampere hosts, Windows on Arm run arm64 Docker engines).
#
# Usage: hack/image-audit.sh [--list] [--live] [--report FILE]          (task images:audit -- --live)
#   --list    only print the image inventory (no registry calls)
#   --live    also add images running in the k3d mgmt cluster (read-only `kubectl get pods`) and local containers
#   --report  also write the result table as markdown to FILE
# Sources: every addon rendered like hack/test.sh layers it (mgmt + each cluster file of INST, default local),
# k3d node/helper images, the CAPD node + load balancer images, CAPI provider controllers (release components) and
# the k3s system images (k3s-images.txt) of each Kubernetes version in use. Registry access via crane (mise).
set -euo pipefail

# --- deliberate multi-arch exceptions -------------------------------------------------------------------------------
# AGENTS.md: new images must publish linux/amd64 AND linux/arm64. These are the only accepted exceptions, each visible
# in review, documented (docs/build-plane.md "Images and architectures") and expiring. One entry per image:
#   <repository:tag prefix>|<expires YYYY-MM-DD>|<why, and when to remove it>
# An entry covers an image only while it matches the prefix (a version bump drops it: the bumped image must be
# multi-arch or get a reviewed entry of its own) and the date has not passed (then the audit fails as EXPIRED).
# Harbor 2.15 publishes linux/amd64 only; 2.16 adds arm64 as separate -arm64 tags. Remove this block at the Harbor
# 2.16 bump (switch to the arm64-capable images or a manifest list) - accepted in PR #2 (workflow plane, Harbor).
ARCH_EXCEPTIONS=(
  "docker.io/goharbor/harbor-core:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/harbor-db:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/harbor-jobservice:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/harbor-portal:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/harbor-registryctl:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/registry-photon:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/trivy-adapter-photon:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
  "docker.io/goharbor/valkey-photon:v2.15.|2027-03-31|Harbor 2.15 amd64-only; remove at Harbor 2.16 (-arm64 tags)"
)

# arch_exception <image> -> "ok:<why>" | "expired:<date>" | "" (no entry). TODAY (YYYY-MM-DD) overrides the date.
arch_exception() {
  local img=$1 e prefix rest exp why today
  today=${TODAY:-$(date -u +%Y-%m-%d)}
  for e in "${ARCH_EXCEPTIONS[@]}"; do
    prefix=${e%%|*}; rest=${e#*|}; exp=${rest%%|*}; why=${rest#*|}
    [[ "$img" == "$prefix"* ]] || continue
    if [[ "$today" > "$exp" ]]; then echo "expired:$exp"; else echo "ok:$why (until $exp)"; fi
    return 0
  done
}

# eval_param <template>: resolve every "{{ .Values.a.b }}" in the template against the installation file (catalog
# installationParameters, e.g. 'https://{{ .Values.registry.host }}'), like hack/test.sh.
eval_param() {
  local t=$1 path val
  while :; do
    path=$(printf '%s' "$t" | sed -nE 's/.*\{\{ *\.Values\.([A-Za-z0-9_.]+) *\}\}.*/\1/p')
    [[ -n "$path" ]] || break
    val=$(yq ".$path" "$INST_FILE")
    t=$(printf '%s' "$t" | sed -E "s|\\{\\{ *\\.Values\\.${path} *\\}\\}|${val}|")   # a dot in path matches itself
  done
  printf '%s\n' "$t"
}

# Sourced (hack/tests/test_image_audit.sh): only the functions above.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

INST="${INST:-local}"
LIST_ONLY=0 LIVE=0 REPORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --live) LIVE=1 ;;
    --report) REPORT="$2"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

for bin in helm yq; do command -v "$bin" >/dev/null || { echo "missing tool: $bin (mise install)" >&2; exit 1; }; done
(( LIST_ONLY )) || command -v crane >/dev/null || { echo "missing tool: crane (mise install)" >&2; exit 1; }

INST_DIR="installations/$INST"
INST_FILE="$INST_DIR/installation.yaml"
[[ -f "$INST_FILE" ]] || { echo "no installation file $INST_FILE" >&2; exit 1; }
CATALOG=charts/platform/values.yaml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
INV="$TMP/inventory.tsv"   # <image>\t<source>
: > "$INV"

add() { printf '%s\t%s\n' "$1" "$2" >> "$INV"; }

# Images from rendered manifests: every `image:` string, plus `repository`/`tag` pairs some CRs use.
extract_images() {
  yq -N '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' 2>/dev/null \
    | tr -d '\r' | grep -E '^[a-z0-9]' || true
}

# server_part <url> <url|host|port>: piece of an Argo cluster secret's server URL (catalog clusterServerParameters).
server_part() {
  local url=$1 rest
  rest=${url#*://}; rest=${rest%%/*}
  case "$2" in
    url) printf '%s\n' "$url" ;;
    host) printf '%s\n' "${rest%:*}" ;;
    port) if [[ "$rest" == *:* ]]; then printf '%s\n' "${rest##*:}"; else echo 443; fi ;;
  esac
}
SAMPLE_SERVER=https://192.0.2.10:6443        # as hack/test.sh: stands in for a workload cluster's API endpoint
MGMT_SERVER=https://kubernetes.default.svc

# render <addon> <role> <name> <provider> <environment> <region> <cni> <server> [<labels-file>]
render() {
  local addon=$1 role=$2 name=$3 prov=$4 env=$5 region=$6 cni=$7 server=$8 labels=${9:-} dir="addons/$1" ns vf p ip it part
  local key def v img mesh
  local -a vargs=()
  ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" "$CATALOG")
  mesh=none   # values/mesh-member.yaml on clusters with a mesh group label (as appset-addons.yaml)
  if [[ -n "$labels" && -s "$labels" && -n "$(yq -r '.["mesh.platform.koorikla.io/group"] // ""' "$labels")" ]]; then mesh=member; fi
  for vf in "$dir/values.yaml" "$dir/values/role-$role.yaml" "$dir/values/provider-$prov.yaml" \
    "$dir/values/cni-$cni.yaml" "$dir/values/mesh-$mesh.yaml" "$INST_DIR/addons/$addon/values.yaml" "$INST_DIR/addons/$addon/env-$env.yaml" \
    "$INST_DIR/addons/$addon/cluster-$name.yaml"; do
    if [[ -f "$vf" ]]; then vargs+=(--values "$vf"); fi
  done
  vargs+=(--values "$INST_FILE" --set-string "cluster.name=$name,cluster.role=$role,cluster.provider=$prov,cluster.environment=$env,cluster.cni=$cni,cluster.region=$region")
  while IFS=$'\t' read -r p part; do
    [[ -n "$p" ]] || continue
    if [[ "$part" == port ]]; then vargs+=(--set "$p=$(server_part "$server" port)")
    else vargs+=(--set-string "$p=$(server_part "$server" "$part")"); fi
  done < <(yq -r ".addons[\"$addon\"].clusterServerParameters // {} | to_entries[] | [.key, .value] | @tsv" "$CATALOG" | tr -d '\r')
  while IFS= read -r p; do
    if [[ -n "$p" ]]; then vargs+=(--set-string "$p=$name"); fi
  done < <(yq ".addons[\"$addon\"].clusterNameParameters[]?" "$CATALOG" | tr -d '\r')
  while IFS=$'\t' read -r ip it; do
    if [[ -n "$ip" ]]; then vargs+=(--set "$ip=$(eval_param "$it")"); fi
  done < <(yq -r ".addons[\"$addon\"].installationParameters // {} | to_entries[] | [.key, .value] | @tsv" "$CATALOG" | tr -d '\r')
  # catalog clusterLabelParameters: the cluster's label value, else the default (as appset-addons.yaml)
  while IFS=$'\t' read -r p key def; do
    [[ -n "$p" ]] || continue
    v=""
    if [[ -n "$labels" && -s "$labels" ]]; then v=$(yq -r ".[\"$key\"] // \"\"" "$labels"); fi
    vargs+=(--set-string "$p=${v:-$def}")
  done < <(yq -r ".addons[\"$addon\"].clusterLabelParameters // {} | to_entries[] | [.key, .value.label, (.value.default // \"\")] | @tsv" "$CATALOG" | tr -d '\r')
  if ! helm template "$addon" "$dir" --namespace "$ns" "${vargs[@]}" > "$TMP/render.yaml" 2> "$TMP/render.err"; then
    echo "WARN: helm template $addon ($name) failed: $(head -c 300 "$TMP/render.err")" >&2
    return 0
  fi
  extract_images < "$TMP/render.yaml" | while IFS= read -r img; do add "$img" "addon $addon ($name)"; done
  # Proxy image istiod uses for the Deployments it generates (east-west gateway, waypoints): not in any manifest,
  # resolved from the injector values (global.hub/proxy.image/tag/variant, e.g. docker.io/istio/proxyv2:1.32.0-distroless).
  local inj
  inj=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "istio-sidecar-injector") | .data.values // ""' "$TMP/render.yaml" 2>/dev/null || true)
  if [[ -n "$inj" ]]; then
    # shellcheck disable=SC2016  # $g/$v are yq variables
    img=$(printf '%s' "$inj" | yq -p=json -r '.global as $g | ($g.variant // "") as $v | $g.hub + "/" + $g.proxy.image + ":" + $g.tag + (if $v == "" then "" else "-" + $v end)')
    add "$img" "addon $addon ($name): istiod-generated gateways/waypoints"
  fi
}

# enabled <addon> <toggle-from-cluster-file>: catalog default + per-cluster override, as the ApplicationSets do.
enabled() {
  local def toggle=$2
  def=$(yq ".addons[\"$1\"].default // true" "$CATALOG")
  [[ "$toggle" != "false" ]] && { [[ "$def" != "false" ]] || [[ "$toggle" == "true" ]]; }
}

echo "==> Building chart dependencies" >&2
./hack/deps.sh >&2

echo "==> Rendering addons for installation $INST" >&2
for dir in addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  addon=$(basename "$dir")
  roles=$(yq ".addons[\"$addon\"].roles[]?" "$CATALOG" | tr -d '\r')
  [[ -n "$roles" ]] || roles=$'mgmt\nworkload'
  provs=$(yq ".addons[\"$addon\"].providers[]?" "$CATALOG" | tr -d '\r')
  if printf '%s\n' "$roles" | grep -qx mgmt; then
    m_prov=$(yq '.mgmt.provider // "docker"' "$INST_FILE")
    if enabled "$addon" "$(yq ".mgmt.addons[\"$addon\"]" "$INST_FILE")" \
      && { [[ -z "$provs" ]] || printf '%s\n' "$provs" | grep -qx "$m_prov"; }; then
      render "$addon" mgmt "$(yq '.mgmt.name // "mgmt"' "$INST_FILE")" "$m_prov" \
        "$(yq '.mgmt.environment // "mgmt"' "$INST_FILE")" "$(yq '.mgmt.region // "local"' "$INST_FILE")" \
        "$(yq '.mgmt.cni // "flannel"' "$INST_FILE")" "$MGMT_SERVER"
    fi
  fi
  if printf '%s\n' "$roles" | grep -qx workload; then
    for cf in "$INST_DIR"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      c_prov=$(yq '.provider // "docker"' "$cf")
      c_name=$(yq '.name' "$cf")
      # Addon labels as charts/cluster renders them (some derive from facts, e.g. cilium from cni), else the file.
      if [[ ! -f "$TMP/cluster-$c_name.yaml" ]]; then
        helm template "cluster-$c_name" charts/cluster --namespace fleet --values "$INST_FILE" --values "$cf" \
          > "$TMP/cluster-$c_name.yaml" 2>/dev/null || : > "$TMP/cluster-$c_name.yaml"
      fi
      [[ -f "$TMP/labels-$c_name.yaml" ]] || yq 'select(.kind == "Cluster") | .metadata.labels' "$TMP/cluster-$c_name.yaml" \
        > "$TMP/labels-$c_name.yaml" 2>/dev/null || : > "$TMP/labels-$c_name.yaml"
      toggle=$(yq "select(.kind == \"Cluster\") | .metadata.labels[\"addons.platform.koorikla.io/$addon\"]" \
        "$TMP/cluster-$c_name.yaml" 2>/dev/null || true)
      [[ -n "$toggle" && "$toggle" != "null" ]] || toggle=$(yq ".addons[\"$addon\"]" "$cf")
      if enabled "$addon" "$toggle" && { [[ -z "$provs" ]] || printf '%s\n' "$provs" | grep -qx "$c_prov"; }; then
        render "$addon" workload "$c_name" "$c_prov" "$(yq '.environment // "development"' "$cf")" \
          "$(yq '.region // "local"' "$cf")" "$(yq '.cni // "cilium"' "$cf")" "$SAMPLE_SERVER" "$TMP/labels-$c_name.yaml"
      fi
    done
  fi
done

echo "==> Rendering enabled examples (examples/*), layered per matching cluster like appset-examples.yaml" >&2
# shellcheck disable=SC2016  # $i is a yq variable
yq eval-all -o=json '. as $i ireduce ({}; . * $i) | .examples // {}' "$CATALOG" "$INST_FILE" > "$TMP/examples.json"
for dir in examples/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  ex=$(basename "$dir")
  [[ "$(yq -p=json ".[\"$ex\"].enabled // false" "$TMP/examples.json")" == "true" ]] || continue
  helm template "$ex" "$dir" 2>/dev/null | extract_images | while IFS= read -r img; do add "$img" "example $ex"; done
  for cf in "$INST_DIR"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    c_name=$(yq '.name' "$cf")
    labels="$TMP/labels-$c_name.yaml"
    [[ -s "$labels" ]] || continue
    match=1   # selector matchLabels (matchExpressions are not evaluated here: render anyway)
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" ]] || continue
      [[ "$(yq -r ".[\"$k\"] // \"\"" "$labels")" == "$v" ]] || match=0
    done < <(yq -p=json -r ".[\"$ex\"].selector.matchLabels // {} | to_entries[] | [.key, .value] | @tsv" "$TMP/examples.json" | tr -d '\r')
    (( match )) || continue
    vargs=(--values "$dir/values.yaml")
    for vf in "$INST_DIR/examples/$ex/values.yaml" "$INST_DIR/examples/$ex/cluster-$c_name.yaml"; do
      if [[ -f "$vf" ]]; then vargs+=(--values "$vf"); fi
    done
    helm template "$ex" "$dir" "${vargs[@]}" --set-string "cluster.name=$c_name" 2>/dev/null | extract_images \
      | while IFS= read -r img; do add "$img" "example $ex ($c_name)"; done
  done
done

echo "==> Cluster runtime images (k3d, CAPD, CAPI providers, k3s)" >&2
k3s_versions=""
if [[ "$INST" == local ]]; then
  k3d_img=$(yq '.image' bootstrap/k3d-mgmt.yaml)
  add "$k3d_img" "k3d mgmt node (bootstrap/k3d-mgmt.yaml)"
  k3s_versions=$(printf '%s' "$k3d_img" | sed -E 's/.*:(v[0-9.]+)-(k3s[0-9]+)$/\1+\2/')
  k3d_ver=$(awk '$1 == "k3d" && $2 == "=" { gsub(/"/, "", $3); print $3 }' mise.toml)
  add "ghcr.io/k3d-io/k3d-proxy:$k3d_ver" "k3d serverlb (k3d $k3d_ver)"
  add "ghcr.io/k3d-io/k3d-tools:$k3d_ver" "k3d tools (k3d $k3d_ver)"
fi
if [[ "$(yq '.capi.providers.docker' "$INST_FILE")" != "false" ]]; then
  add "$(yq '.docker.kindImage' addons/clusterclasses/values.yaml)" "CAPD node (addons/clusterclasses kindImage)"
  # CAPD built-in load balancer default; seen live with CAPI v1.13.8 (docker ps). Re-check on CAPI bumps.
  add "kindest/haproxy:v20230606-42a2262b" "CAPD load balancer (CAPD default)"
fi
for cf in "$INST_DIR"/clusters/*.yaml; do
  [[ -f "$cf" ]] || continue
  v=$(yq '.kubernetesVersion // ""' "$cf")
  if [[ -n "$v" ]]; then k3s_versions=$(printf "%s\n%s" "$k3s_versions" "$v"); fi
done

pv() { yq "$1 // \"$2\"" addons/capi-providers/values.yaml 2>/dev/null || echo "$2"; }
CAPI_VER=$(pv '.core.version' v1.13.8)
K3S_PROV_VER=$(pv '.k3s.version' v0.5.0)
fetch() { curl -fsSL --retry 2 "$1" 2>/dev/null || echo "WARN: could not fetch $1" >&2; }
{
  fetch "https://github.com/kubernetes-sigs/cluster-api/releases/download/$CAPI_VER/core-components.yaml"
  echo "---"
  fetch "https://github.com/k3s-io/cluster-api-k3s/releases/download/$K3S_PROV_VER/bootstrap-components.yaml"
  echo "---"
  fetch "https://github.com/k3s-io/cluster-api-k3s/releases/download/$K3S_PROV_VER/control-plane-components.yaml"
} > "$TMP/providers.yaml"
extract_images < "$TMP/providers.yaml" | while IFS= read -r img; do add "$img" "CAPI provider controller"; done
if [[ "$(yq '.capi.providers.docker' "$INST_FILE")" != "false" ]]; then
  fetch "https://github.com/kubernetes-sigs/cluster-api/releases/download/$CAPI_VER/infrastructure-components-development.yaml" \
    | extract_images | while IFS= read -r img; do add "$img" "CAPD controller"; done
fi
for v in $(printf '%s\n' "$k3s_versions" | sort -u); do
  [[ -n "$v" ]] || continue
  fetch "https://github.com/k3s-io/k3s/releases/download/${v/+/%2B}/k3s-images.txt" | tr -d '\r' \
    | grep -v traefik | while IFS= read -r img; do
      if [[ -n "$img" ]]; then add "$img" "k3s $v system image"; fi
    done
done

if (( LIVE )); then
  echo "==> Live images (k3d-platform-mgmt pods, local containers)" >&2
  kubectl --context "${KUBE_CTX:-k3d-platform-mgmt}" get pods -A -o \
    jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null | tr -d '\r' | while IFS= read -r img; do
      if [[ -n "$img" ]]; then add "$img" "live: mgmt pod"; fi
    done
  docker ps --format '{{.Image}}' 2>/dev/null | tr -d '\r' | grep -vE '^[0-9a-f]{12}$' | while IFS= read -r img; do
    add "$img" "live: docker container"
  done
fi

# One line per image: <image>\t<source; source; ...>
sort -u "$INV" | awk -F'\t' '{ s[$1] = ($1 in s) ? s[$1] "; " $2 : $2 } END { for (i in s) print i "\t" s[i] }' \
  | sort > "$TMP/images.tsv"
total=$(wc -l < "$TMP/images.tsv" | tr -d ' ')

if (( LIST_ONLY )); then
  cat "$TMP/images.tsv"
  echo "$total images" >&2
  exit 0
fi

# arch_of <image> -> "amd64,arm64,..." (linux platforms of an index) or "single:<arch>" or "error:<msg>"
arch_of() {
  local img=$1 man err
  if ! man=$(crane manifest "$img" 2> "$TMP/crane.err"); then
    err=$(tr '\n' ' ' < "$TMP/crane.err" | cut -c1-120)
    echo "error:$err"
    return 0
  fi
  if printf '%s' "$man" | yq -p json -e '.manifests' >/dev/null 2>&1; then
    printf '%s' "$man" | yq -p json -r '[.manifests[] | select(.platform.os == "linux") | .platform.architecture + (.platform.variant // "" | select(. != "") | "/" + .)] | unique | join(",")'
  else
    echo "single:$(crane config "$img" 2>/dev/null | yq -p json -r '.architecture // "?"')"
  fi
}

echo "==> Checking $total images for linux/amd64 + linux/arm64" >&2
bad=0 excepted=0
{
  echo "| image | linux platforms | result | used by |"
  echo "|---|---|---|---|"
} > "$TMP/report.md"
while IFS=$'\t' read -r img src; do
  plats=$(arch_of "$img")
  case "$plats" in
    error:*) result="ERROR" ;;
    single:*) result="SINGLE-ARCH" ;;
    *) if [[ ",$plats," == *",amd64,"* && ",$plats," == *",arm64"* ]]; then result="ok"; else result="MISSING-ARCH"; fi ;;
  esac
  if [[ "$result" == SINGLE-ARCH || "$result" == MISSING-ARCH ]]; then
    exc=$(arch_exception "$img")
    case "$exc" in
      ok:*) result="EXCEPTION"; plats="$plats - ${exc#ok:}"; excepted=$((excepted + 1)) ;;
      expired:*) result="EXPIRED-EXCEPTION"; plats="$plats - exception expired ${exc#expired:}" ;;
    esac
  fi
  [[ "$result" == ok || "$result" == EXCEPTION ]] || bad=$((bad + 1))
  printf '%-12s %-75s %s\n' "$result" "$img" "$plats"
  # shellcheck disable=SC2016  # literal markdown backticks
  printf '| `%s` | %s | %s | %s |\n' "$img" "$plats" "$result" "$src" >> "$TMP/report.md"
done < "$TMP/images.tsv"
if [[ -n "$REPORT" ]]; then cp "$TMP/report.md" "$REPORT"; fi
echo "$total images, $bad not multi-arch (amd64+arm64) or not resolvable, $excepted deliberate exceptions (ARCH_EXCEPTIONS)" >&2
(( bad == 0 ))
