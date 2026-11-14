# hack/lib/addons.sh - render an addon the way its ApplicationSet does (charts/platform/templates/appset-addons.yaml).
# Shared by hack/test.sh, hack/image-audit.sh and hack/tests/*, so every offline render layers values identically.
# Source after hack/lib/portable.sh, from the repo root. Bash 3.2; functions only.
# shellcheck shell=bash

ADDONS_CATALOG=${ADDONS_CATALOG:-charts/platform/values.yaml}

# addon_appset <platform render> <addon> -> the addon's ApplicationSet document (YAML) from a charts/platform render.
addon_appset() {
  yq -N "select(.kind == \"ApplicationSet\" and .metadata.name == \"addon-$2\")" "$1" | tr -d '\r'
}

# addon_installation_params <platform render> <addon> -> "<param>\t<value>" per catalog installationParameters entry,
# taken from the rendered ApplicationSet: the templates are evaluated by Helm itself, exactly as Argo CD receives them.
addon_installation_params() {
  local render=$1 addon=$2 p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    # string concatenation, not @tsv: @tsv would escape backslashes/tabs inside values
    addon_appset "$render" "$addon" | P="$p" yq -r '.spec.template.spec.source.helm.parameters[] | select(.name == strenv(P)) | .name + "\t" + .value' | tr -d '\r'
  done < <(yq -r ".addons[\"$addon\"].installationParameters // {} | keys | .[]" "$ADDONS_CATALOG" | tr -d '\r')
}

# addon_installation_valuefiles <platform render> <addon> -> catalog installationValueFiles as rendered (relative to
# addons/<addon>): the valueFiles entries under values/ with no per-cluster goTemplate left in them.
addon_installation_valuefiles() {
  addon_appset "$1" "$2" | yq -r '.spec.template.spec.source.helm.valueFiles[] | select(test("^values/") and (test("[{][{]") | not))' | tr -d '\r'
}

# addon_server_part <url> <url|host|port> -> piece of an Argo cluster secret's server URL (clusterServerParameters).
addon_server_part() {
  local url=$1 rest
  rest=${url#*://}; rest=${rest%%/*}
  case "$2" in
    url) printf '%s\n' "$url" ;;
    host) printf '%s\n' "${rest%:*}" ;;
    port) if [[ "$rest" == *:* ]]; then printf '%s\n' "${rest##*:}"; else echo 443; fi ;;
  esac
}

# addon_release_name <platform render> <addon> -> the Helm release name Argo CD uses (catalog releaseName, else addon).
addon_release_name() {
  local r
  r=$(addon_appset "$1" "$2" | yq -r '.spec.template.spec.source.helm.releaseName // ""' | tr -d '\r')
  printf '%s\n' "${r:-$2}"
}

# addon_values_object <platform render> <addon> <out file> -> writes the ApplicationSet's helm valuesObject (charts/platform
# defaults merged with installation.yaml, minus `addons`) without its per-cluster `cluster:` block (goTemplate).
addon_values_object() {
  addon_appset "$1" "$2" | yq '.spec.template.spec.source.helm.valuesObject // {} | del(.cluster)' > "$3"
}

# addon_helm_args <addon> <inst dir> <platform render> <role> <name> <provider> <environment> <region> <cni> <server>
# -> `helm template` arguments, one per line, in ApplicationSet precedence, all taken from the addon's ApplicationSet in
#    the charts/platform render (Argo parity):
#    valueFiles (chart, role, provider, cni, installationValueFiles, installation overlays) < valuesObject
#    (charts/platform values + installation.yaml, then cluster.*) < parameters (as rendered; the per-cluster goTemplate
#    expressions - cluster name label, server parts - resolved for this cluster; forceString -> --set-string).
# The release name is addon_release_name. <inst dir> locates the overlay files; the valuesObject file is written next to
# <platform render> (the caller's temp dir).
addon_helm_args() {
  local addon=$1 inst_dir=$2 render=$3 role=$4 name=$5 prov=$6 env=$7 region=$8 cni=$9 server=${10}
  local dir="addons/$addon" vf p v fs part vo="$3.values-$1.yaml"
  local name_expr='{{ index .metadata.labels "platform.koorikla.io/name" }}'
  local -a files=("$dir/values.yaml" "$dir/values/role-$role.yaml" "$dir/values/provider-$prov.yaml" "$dir/values/cni-$cni.yaml")
  while IFS= read -r vf; do
    if [[ -n "$vf" ]]; then files+=("$dir/$vf"); fi
  done < <(addon_installation_valuefiles "$render" "$addon")
  files+=("$inst_dir/addons/$addon/values.yaml" "$inst_dir/addons/$addon/env-$env.yaml" "$inst_dir/addons/$addon/cluster-$name.yaml")
  for vf in "${files[@]}"; do
    if [[ -f "$vf" ]]; then printf '%s\n' --values "$vf"; fi   # ignoreMissingValueFiles: true
  done
  addon_values_object "$render" "$addon" "$vo"
  printf '%s\n' --values "$vo" \
    --set-string "cluster.name=$name,cluster.role=$role,cluster.provider=$prov,cluster.environment=$env,cluster.cni=$cni,cluster.region=$region"
  while IFS=$'\t' read -r p v fs; do
    [[ -n "$p" ]] || continue
    part=$(P="$p" yq -r ".addons[\"$addon\"].clusterServerParameters[strenv(P)] // \"\"" "$ADDONS_CATALOG" | tr -d '\r')
    if [[ -n "$part" ]]; then v=$(addon_server_part "$server" "$part"); fi
    v=${v//"$name_expr"/$name}
    case "$v" in *"{{"*) echo "addon_helm_args: $addon parameter $p has an unresolved goTemplate: $v" >&2; return 1 ;; esac
    if [[ "$fs" == true ]]; then printf '%s\n' --set-string "$p=$v"; else printf '%s\n' --set "$p=$v"; fi   # Argo: typed --set unless forceString
  done < <(addon_appset "$render" "$addon" | yq -r '.spec.template.spec.source.helm.parameters[]? | .name + "\t" + .value + "\t" + ((.forceString // false) | tostring)' | tr -d '\r')
}
