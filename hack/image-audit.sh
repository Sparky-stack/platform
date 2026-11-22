#!/usr/bin/env bash
# Multi-arch audit: list every container image the installation runs and check that each one publishes
# linux/amd64 AND linux/arm64 (Apple Silicon, Graviton/Ampere hosts, Windows on Arm run arm64 Docker engines).
#
# Usage: hack/image-audit.sh [--list] [--rendered] [--opt-in] [--live] [--report FILE]   (task images:audit -- --live)
#   --list    only print the image inventory (no registry calls)
#   --rendered only the images this repo renders or pins (addons, CAPD kindImage, k3d mgmt node): no runtime images
#             from upstream release manifests, k3d or CAPD defaults, no network (hack/tests/test_image_pins.sh)
#   --opt-in  also render opt-in addons (catalog default false) not switched on in INST, e.g. before enabling one
#   --live    also add images running in the k3d mgmt cluster (read-only `kubectl get pods`) and local containers
#   --report  also write the result table as markdown to FILE
# Sources: every addon rendered like hack/test.sh layers it (mgmt + each cluster file of INST, default local),
# k3d node/helper images, the CAPD node + load balancer images, CAPI provider controllers (release components; CAPG:
# the pinned imageUrl the operator substitutes) and
# the k3s system images (k3s-images.txt) of each Kubernetes version in use. Registry access via crane (mise).
set -euo pipefail

# --- deliberate multi-arch exceptions -------------------------------------------------------------------------------
# The only accepted single-arch images (docs/build-plane.md "Images and architectures"), one entry per image:
#   <repository:tag prefix>|<expires YYYY-MM-DD>|<why, and when to remove it>
# A version bump stops matching the prefix and a passed date fails the audit as EXPIRED: both force a new review.
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

# Images from rendered manifests (stdin):
#   - every string under a key ending in `image` (`image:`, and e.g. the Argo Events controller config's natsImage);
#   - the same keys inside YAML embedded in ConfigMap data (the Argo Events EventBus JetStream versions live there),
#     each embedded document parsed on its own (a script that merely contains "image:" cannot abort the extraction);
#   - images operators receive by name through env vars and ConfigMap keys containing IMAGE (e.g. ARGO_EVENTS_IMAGE,
#     Strimzi STRIMZI_KAFKA_IMAGES "<version>=<image>" lines, CNPG POSTGRES_IMAGE_NAME, the Barman Cloud plugin's
#     SIDECAR_IMAGE): those pods are created by the operator, not rendered;
#   - Crossplane package references (spec.package of Function / Provider / Configuration): OCI images Crossplane pulls
#     and runs as pods.
extract_images() {
  local f b keys='.. | select(tag == "!!map") | to_entries[] | select((.key | tag) == "!!str")
    | select(.key | test("(?i)image$")) | .value | select(tag == "!!str")'
  f=$(mktemp)
  cat > "$f"
  {
    yq -N "$keys" "$f" 2>/dev/null || true
    if grep -q 'ConfigMap' "$f"; then
      yq -N 'select(.kind == "ConfigMap") | .data[]? | select(tag == "!!str") | select(test("(?i)image: *[a-z0-9]"))
        | @base64' "$f" 2>/dev/null | tr -d '\r' | while IFS= read -r b; do
        if [[ -n "$b" ]]; then yq -n -N "\"$b\" | @base64d | from_yaml | $keys" 2>/dev/null || true; fi
      done
    fi
  } | tr -d '\r' | grep -E '^[a-z0-9]' || true
  if grep -q 'IMAGE' "$f"; then
    yq -N '(.. | select(tag == "!!map" and has("name") and has("value"))
        | select((.name | tag) == "!!str" and (.name | test("IMAGE")) and (.value | tag) == "!!str") | .value),
      (select(.kind == "ConfigMap") | .data // {} | to_entries[] | select(.key | test("IMAGE")) | .value)' "$f" 2>/dev/null \
      | tr -d '\r' | sed -E 's/^[[:space:]]*([0-9][0-9.]*=)?//' | grep -E '^[a-z0-9.-]+(:[0-9]+)?/[^[:space:]$]+(:[A-Za-z0-9._-]+|@sha256:[0-9a-f]{64})$' || true
  fi
  if grep -q 'pkg.crossplane.io/' "$f"; then
    yq -N 'select(.apiVersion == "pkg.crossplane.io/*" and (.kind == "Function" or .kind == "Provider" or .kind == "Configuration"))
        | .spec.package | select(tag == "!!str")' "$f" 2>/dev/null | tr -d '\r' | grep -E '^[a-z0-9]' || true
  fi
  rm -f "$f"
}

# istio_proxy_image <rendered manifest>: the proxy image istiod injects into the gateways/waypoints it generates, from
# the istio-sidecar-injector values: global.proxy.image if it contains "/", else hub/image:tag[-variant]. Prints
# nothing without an injector. Composed in bash, not yq if/then/else: that needs yq >= 4.54.
istio_proxy_image() {
  local rf=$1 inj fields hub image tag variant
  grep -q 'istio-sidecar-injector' "$rf" || return 0
  inj=$(yq -N 'select(.kind == "ConfigMap" and .metadata.name == "istio-sidecar-injector") | .data.values // ""' "$rf" 2>/dev/null || true)
  [[ -n "$inj" ]] || return 0
  if ! fields=$(printf '%s' "$inj" | yq -p=json -r \
    '[.global.hub // "", .global.proxy.image // "", .global.tag // "", .global.variant // ""] | join("|")' 2>&1); then
    echo "ERROR: $rf: istio-sidecar-injector values: $fields" >&2
    return 1
  fi
  IFS='|' read -r hub image tag variant <<<"${fields//$'\r'/}"
  [[ -n "$image" ]] || { echo "ERROR: $rf: istio-sidecar-injector values have no global.proxy.image" >&2; return 1; }
  if [[ "$image" == */* ]]; then printf '%s\n' "$image"; else printf '%s/%s:%s%s\n' "$hub" "$image" "$tag" "${variant:+-$variant}"; fi
}

# enabled <addon> <toggle-from-cluster-file>: catalog default + per-cluster override, as the ApplicationSets do; with
# OPT_IN=1 an opt-in addon counts as on unless the cluster sets it to "false". Reads the catalog file CATALOG.
enabled() {
  local def toggle=$2
  def=$(yq ".addons[\"$1\"].default" "$CATALOG")   # no // : yq treats false as empty (opt-in addons would count as on)
  [[ "$toggle" != "false" ]] && { [[ "$def" != "false" ]] || [[ "$toggle" == "true" ]] || (( ${OPT_IN:-0} )); }
}

# Sourced (hack/tests/test_image_audit.sh): only the functions above.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

cd "$(dirname "$0")/.."
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=lib/addons.sh
source hack/lib/addons.sh

INST="${INST:-local}"
LIST_ONLY=0 LIVE=0 OPT_IN=0 RENDERED=0 REPORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --live) LIVE=1 ;;
    --opt-in) OPT_IN=1 ;;
    --rendered) RENDERED=1 ;;
    --report) REPORT="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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

# runs_on <provider> <providers list>: an empty list (catalog `providers`) means every provider.
runs_on() { [[ -z "$2" ]] || printf '%s\n' "$2" | grep -qx "$1"; }

SAMPLE_SERVER=https://192.0.2.10:6443        # as hack/test.sh: stands in for a workload cluster's API endpoint
MGMT_SERVER=https://kubernetes.default.svc

# render <addon> <role> <name> <provider> <environment> <region> <cni> <server> [<labels file>]: layered like the ApplicationSet
# (hack/lib/addons.sh), installation parameters / value files from the charts/platform render of this installation.
render() {
  local addon=$1 role=$2 name=$3 target=$3 dir="addons/$1" rf="$TMP/render.yaml" ns
  [[ "$role" == mgmt ]] && target=mgmt
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/addon-$addon-$INST-$target.yaml" ]]; then
    rf="$RENDERED_DIR/addon-$addon-$INST-$target.yaml"
  else
    local -a vargs=()
    ns=$(yq ".addons[\"$addon\"].namespace // \"$addon\"" "$CATALOG")
    read_lines vargs addon_helm_args "$addon" "$INST_DIR" "$PLATFORM_RENDER" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:-}"
    if ! helm template "$(addon_release_name "$PLATFORM_RENDER" "$addon")" "$dir" --namespace "$ns" "${vargs[@]}" \
      > "$rf" 2> "$TMP/render.err"; then
      echo "WARN: helm template $addon ($name) failed: $(head -c 300 "$TMP/render.err")" >&2
      return 0
    fi
  fi
  extract_images < "$rf" | while IFS= read -r img; do add "$img" "addon $addon ($name)"; done
  local img
  img=$(istio_proxy_image "$rf") || exit 1
  if [[ -n "$img" ]]; then add "$img" "addon $addon ($name): istiod-generated gateways/waypoints"; fi
}

if [[ -z "${RENDERED_DIR:-}" || ! -d "${RENDERED_DIR:-}" ]]; then
  echo "==> Building chart dependencies" >&2
  ./hack/deps.sh >&2
fi

echo "==> Rendering addons for installation $INST" >&2
if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/platform-$INST.yaml" ]]; then
  PLATFORM_RENDER="$RENDERED_DIR/platform-$INST.yaml"
else
  PLATFORM_RENDER="$TMP/platform.yaml"   # the ApplicationSets: installation parameters and value files as Argo CD gets them
  helm template platform charts/platform --namespace argocd --values "$INST_FILE" > "$PLATFORM_RENDER"
fi
dns_prov=$(yq '.dns.provider // "none"' "$INST_FILE")
capd_enabled=$(yq '.capi.providers.docker != false' "$INST_FILE")
m_prov=$(yq '.mgmt.provider // "docker"' "$INST_FILE")
m_name=$(yq '.mgmt.name // "mgmt"' "$INST_FILE")
m_env=$(yq '.mgmt.environment // "mgmt"' "$INST_FILE")
m_reg=$(yq '.mgmt.region // "local"' "$INST_FILE")
m_cni=$(yq '.mgmt.cni // "flannel"' "$INST_FILE")
for cf in "$INST_DIR"/clusters/*.yaml; do
  [[ -f "$cf" ]] || continue
  c_name=$(yq '.name' "$cf")
  if [[ -n "${RENDERED_DIR:-}" && -s "$RENDERED_DIR/cluster-$INST-$c_name.yaml" ]]; then
    cp "$RENDERED_DIR/cluster-$INST-$c_name.yaml" "$TMP/cluster-$c_name.yaml"
  else
    helm template "cluster-$c_name" charts/cluster --namespace fleet --values "$INST_FILE" --values "$cf" \
      > "$TMP/cluster-$c_name.yaml" 2>/dev/null || : > "$TMP/cluster-$c_name.yaml"
  fi
  addon_cluster_labels "$TMP/cluster-$c_name.yaml" "$TMP/labels-$c_name.yaml"
done
for dir in addons/*; do
  [[ -f "$dir/Chart.yaml" ]] || continue
  addon=$(basename "$dir")
  # external-dns runs nothing without a DNS provider (and refuses to render): not part of this installation's images.
  if [[ "$addon" == external-dns && "$dns_prov" == none ]]; then
    echo "  skip external-dns: installation dns.provider is none" >&2
    continue
  fi
  roles=$(yq ".addons[\"$addon\"].roles[]?" "$CATALOG" | tr -d '\r')
  [[ -n "$roles" ]] || roles=$'mgmt\nworkload'
  provs=$(yq ".addons[\"$addon\"].providers[]?" "$CATALOG" | tr -d '\r')
  if printf '%s\n' "$roles" | grep -qx mgmt; then
    if enabled "$addon" "$(yq ".mgmt.addons[\"$addon\"]" "$INST_FILE")" && runs_on "$m_prov" "$provs"; then
      render "$addon" mgmt "$m_name" "$m_prov" "$m_env" "$m_reg" "$m_cni" "$MGMT_SERVER"
    fi
  fi
  if printf '%s\n' "$roles" | grep -qx workload; then
    for cf in "$INST_DIR"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      c_prov=$(yq '.provider // "docker"' "$cf")
      c_name=$(yq '.name' "$cf")
      toggle=$(yq ".[\"addons.platform.koorikla.io/$addon\"]" "$TMP/labels-$c_name.yaml" 2>/dev/null || true)
      [[ -n "$toggle" && "$toggle" != "null" ]] || toggle=$(yq ".addons[\"$addon\"]" "$cf")
      if enabled "$addon" "$toggle" && runs_on "$c_prov" "$provs"; then
        render "$addon" workload "$c_name" "$c_prov" "$(yq '.environment // "development"' "$cf")" \
          "$(yq '.region // "local"' "$cf")" "$(yq '.cni // "cilium"' "$cf")" "$SAMPLE_SERVER" "$TMP/labels-$c_name.yaml"
      fi
    done
  fi
done

echo "==> Cluster images (k3d mgmt node, CAPD node)" >&2
k3s_versions=""
if [[ "$INST" == local ]]; then
  k3d_img=$(yq '.image' bootstrap/k3d-mgmt.yaml)
  add "$k3d_img" "k3d mgmt node (bootstrap/k3d-mgmt.yaml)"
  k3s_versions=$(printf '%s' "${k3d_img%@*}" | sed -E 's/.*:(v[0-9.]+)-(k3s[0-9]+)$/\1+\2/')
fi
if [[ "$capd_enabled" == true ]]; then
  add "$(yq '.docker.kindImage' charts/cluster/values.yaml)" "CAPD node (charts/cluster docker.kindImage)"
fi
if [[ "$(yq '.capi.providers.gcp' "$INST_FILE")" == "true" ]]; then
  # The operator swaps CAPG's release image for this pin (InfrastructureProvider deployment.containers[].imageUrl).
  add "$(yq '.gcp.image' charts/cluster/values.yaml)" "CAPG controller (charts/cluster gcp.image)"
fi

if (( ! RENDERED )); then
  echo "==> Cluster runtime images (k3d helpers, CAPD load balancer, CAPI providers, k3s)" >&2
  if [[ "$INST" == local ]]; then
    k3d_ver=$(awk '$1 == "k3d" && $2 == "=" { gsub(/"/, "", $3); print $3 }' mise.toml)
    add "ghcr.io/k3d-io/k3d-proxy:$k3d_ver" "k3d serverlb (k3d $k3d_ver)"
    add "ghcr.io/k3d-io/k3d-tools:$k3d_ver" "k3d tools (k3d $k3d_ver)"
  fi
  if [[ "$capd_enabled" == true ]]; then
    # CAPD built-in load balancer default; seen live with CAPI v1.13.8 (docker ps). Re-check on CAPI bumps.
    add "kindest/haproxy:v20230606-42a2262b" "CAPD load balancer (CAPD default)"
  fi
  for cf in "$INST_DIR"/clusters/*.yaml; do
    [[ -f "$cf" ]] || continue
    v=$(yq '.kubernetesVersion // ""' "$cf")
    if [[ -n "$v" ]]; then k3s_versions=$(printf "%s\n%s" "$k3s_versions" "$v"); fi
  done

  pv() { yq "$1 // \"$2\"" charts/cluster/values.yaml 2>/dev/null || echo "$2"; }
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
  if [[ "$capd_enabled" == true ]]; then
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
fi

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
