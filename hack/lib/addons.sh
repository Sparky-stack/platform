# hack/lib/addons.sh - render an addon the way its ApplicationSet does (charts/platform/templates/appset-addons.yaml).
# Shared by hack/test.sh, hack/image-audit.sh and hack/tests/*, so every offline render layers values identically.
# Source after hack/lib/portable.sh, from the repo root. Bash 3.2; functions only.
# shellcheck shell=bash

ADDONS_CATALOG=${ADDONS_CATALOG:-charts/platform/values.yaml}
ADDONS_SAMPLE_SERVER=https://192.0.2.10:6443   # stands in for a workload cluster's CAPI API endpoint (TEST-NET-1)

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

# addon_cluster_labels <cluster render> <out file>: the cluster's labels as a YAML map, from the Argo CD cluster
# secret's template (== the CAPI Cluster's labels; the only copy for provider byo). Empty file when there are none.
addon_cluster_labels() {
  yq 'select(.kind == "ExternalSecret" and .metadata.namespace == "argocd") | .spec.target.template.metadata.labels | del(.["argocd.argoproj.io/secret-type"])' \
    "$1" > "$2" 2>/dev/null || : > "$2"
}

# addon_label <label> [<labels file>] -> the label's value ("" when the file or label is missing).
addon_label() {
  if [[ -n "${2:-}" && -s "$2" ]]; then K="$1" yq -r '.[strenv(K)] // ""' "$2" | tr -d '\r'; fi
}

# addon_label_tpl <string> [<labels file>] -> <string> with the cluster-label goTemplates Argo CD evaluates per cluster
# resolved against the labels file. The three forms charts/platform renders: {{ index .metadata.labels "K" }},
# catalog clusterLabelParameters ({{ $v := index .metadata.labels "K" }}{{ if $v }}{{ $v }}{{ else }}D{{ end }}) and
# label-selected value files ({{ if index .metadata.labels "K" }}A{{ else }}B{{ end }}).
addon_label_tpl() {
  local s=$1 labels=${2:-} v
  local re1='[{][{] [$]v := index [.]metadata[.]labels "([^"]+)" [}][}][{][{] if [$]v [}][}][{][{] [$]v [}][}][{][{] else [}][}]([^{]*)[{][{] end [}][}]'
  local re2='[{][{] if index [.]metadata[.]labels "([^"]+)" [}][}]([^{]*)[{][{] else [}][}]([^{]*)[{][{] end [}][}]'
  local re3='[{][{] index [.]metadata[.]labels "([^"]+)" [}][}]'
  while [[ $s =~ $re1 ]]; do
    v=$(addon_label "${BASH_REMATCH[1]}" "$labels"); s=${s/"${BASH_REMATCH[0]}"/${v:-${BASH_REMATCH[2]}}}
  done
  while [[ $s =~ $re2 ]]; do
    v=$(addon_label "${BASH_REMATCH[1]}" "$labels")
    if [[ -n "$v" ]]; then s=${s/"${BASH_REMATCH[0]}"/${BASH_REMATCH[2]}}; else s=${s/"${BASH_REMATCH[0]}"/${BASH_REMATCH[3]}}; fi
  done
  while [[ $s =~ $re3 ]]; do
    v=$(addon_label "${BASH_REMATCH[1]}" "$labels"); s=${s/"${BASH_REMATCH[0]}"/$v}
  done
  printf '%s\n' "$s"
}

# addon_label_valuefiles <platform render> <addon> [<labels file>] -> value files chosen by a cluster label other than
# role/provider/cni (e.g. values/mesh-<member|none>.yaml from the mesh group label), resolved for this cluster.
addon_label_valuefiles() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && addon_label_tpl "$f" "${3:-}"
  done < <(addon_appset "$1" "$2" | yq -r '.spec.template.spec.source.helm.valueFiles[] | select(test("^values/") and test("[{][{]") and (test("^values/(role|provider|cni)-") | not))' | tr -d '\r')
}

# addon_from_valuefiles <platform render> <addon> -> catalog valuesFromAddons as rendered (../../<other addon>/values.yaml,
# relative to the addon's chart): the leading valueFiles entries outside the chart.
addon_from_valuefiles() {
  addon_appset "$1" "$2" | yq -r '.spec.template.spec.source.helm.valueFiles[] | select(test("^[.][.]/[.][.]/addons/"))' | tr -d '\r'
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

# sample_param_args <addon>: helm args for a render outside any cluster (lint, standalone render): the catalog
# clusterServerParameters (<helm param>: url|host|port) for ADDONS_SAMPLE_SERVER, and clusterLabelParameters
# (<helm param>: {label, default}) at their defaults, as charts/platform/templates/appset-addons.yaml passes them.
sample_param_args() {
  local p part def
  while IFS=$'\t' read -r p part; do
    [[ -n "$p" ]] || continue
    if [[ "$part" == port ]]; then
      printf '%s\n' --set "${p}=$(addon_server_part "$ADDONS_SAMPLE_SERVER" port)"
    else
      printf '%s\n' --set-string "${p}=$(addon_server_part "$ADDONS_SAMPLE_SERVER" "$part")"
    fi
  done < <(yq -r ".addons[\"$1\"].clusterServerParameters // {} | to_entries[] | [.key, .value] | @tsv" "$ADDONS_CATALOG")
  while IFS=$'\t' read -r p _ def; do
    if [[ -n "$p" ]]; then printf '%s\n' --set-string "${p}=${def}"; fi
  done < <(yq -r ".addons[\"$1\"].clusterLabelParameters // {} | to_entries[] | [.key, .value.label, (.value.default // \"\")] | @tsv" "$ADDONS_CATALOG" | tr -d '\r')
}

# addon_fleet_names <inst dir> -> "{<name>,...}": every platform cluster of the installation (mgmt + clusters/*.yaml),
# sorted bytewise like sprig sortAlpha: what a catalog fleetParameters entry receives from the Argo CD cluster secrets.
addon_fleet_names() {
  local inst_dir=$1 cf names
  names=$(yq -r '.mgmt.name // "mgmt"' "$inst_dir/installation.yaml" | tr -d '\r')
  for cf in "$inst_dir"/clusters/*.yaml; do
    if [[ -f "$cf" ]]; then names="$names"$'\n'"$(yq -r '.name' "$cf" | tr -d '\r')"; fi
  done
  printf '{%s}\n' "$(printf '%s\n' "$names" | LC_ALL=C sort -u | paste -sd, -)"
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
#   [<labels file>] -> `helm template` arguments, one per line, taken from the addon's rendered ApplicationSet, in its
#   precedence: valueFiles (valuesFromAddons, chart, role, provider, cni, label-selected, installationValueFiles,
#   installation overlays) < valuesObject, then cluster.* < parameters (per-cluster goTemplates resolved for this
#   cluster; forceString -> --set-string). The valuesObject file is written next to <platform render>.
addon_helm_args() {
  local addon=$1 inst_dir=$2 render=$3 role=$4 name=$5 prov=$6 env=$7 region=$8 cni=$9 server=${10} labels=${11:-}
  local dir vf p v fs part fleet vo="$3.values-$1.yaml"
  dir=$(yq -r ".addons[\"$addon\"].path // \"addons/$addon\"" "$ADDONS_CATALOG" | tr -d '\r')
  local name_expr='{{ index .metadata.labels "platform.koorikla.io/name" }}'
  local -a files=()
  while IFS= read -r vf; do
    if [[ -n "$vf" ]]; then files+=("$dir/$vf"); fi
  done < <(addon_from_valuefiles "$render" "$addon")
  files+=("$dir/values.yaml" "$dir/values/role-$role.yaml" "$dir/values/provider-$prov.yaml" "$dir/values/cni-$cni.yaml")
  while IFS= read -r vf; do
    if [[ -n "$vf" ]]; then files+=("$dir/$vf"); fi
  done < <(addon_label_valuefiles "$render" "$addon" "$labels"; addon_installation_valuefiles "$render" "$addon")
  files+=("$inst_dir/addons/$addon/values.yaml" "$inst_dir/addons/$addon/env-$env.yaml" "$inst_dir/addons/$addon/cluster-$name.yaml")
  for vf in "${files[@]}"; do
    if [[ -f "$vf" ]]; then printf '%s\n' --values "$vf"; fi   # ignoreMissingValueFiles: true
  done
  addon_values_object "$render" "$addon" "$vo"
  printf '%s\n' --values "$vo" \
    --set-string "cluster.name=$name,cluster.role=$role,cluster.provider=$prov,cluster.environment=$env,cluster.cni=$cni,cluster.region=$region"
  # \x1f (unit separator), not tab: tab is IFS whitespace, so an empty value would collapse into the next field.
  while IFS=$'\x1f' read -r p v fs; do
    [[ -n "$p" ]] || continue
    part=$(P="$p" yq -r ".addons[\"$addon\"].clusterServerParameters[strenv(P)] // \"\"" "$ADDONS_CATALOG" | tr -d '\r')
    if [[ -n "$part" ]]; then v=$(addon_server_part "$server" "$part"); fi
    fleet=$(P="$p" yq -r ".addons[\"$addon\"].fleetParameters // [] | .[] | select(. == strenv(P))" "$ADDONS_CATALOG" | tr -d '\r')
    if [[ -n "$fleet" ]]; then v=$(addon_fleet_names "$inst_dir"); fi
    v=${v//"$name_expr"/$name}
    case "$v" in *"{{"*) v=$(addon_label_tpl "$v" "$labels") ;; esac
    case "$v" in *"{{"*) echo "addon_helm_args: $addon parameter $p has an unresolved goTemplate: $v" >&2; return 1 ;; esac
    if [[ "$fs" == true ]]; then printf '%s\n' --set-string "$p=$v"; else printf '%s\n' --set "$p=$v"; fi   # Argo: typed --set unless forceString
  done < <(addon_appset "$render" "$addon" | SEP=$'\x1f' yq -r '.spec.template.spec.source.helm.parameters[]? | .name + strenv(SEP) + .value + strenv(SEP) + ((.forceString // false) | tostring)' | tr -d '\r')
}
