#!/usr/bin/env bash
# hack/lib/addons.sh renders addons the way their ApplicationSet does (Argo parity): release name from the catalog,
# valuesObject (charts/platform defaults + installation.yaml, minus addons/cluster) instead of the raw installation
# file, and every helm parameter taken from the rendered ApplicationSet with the per-cluster goTemplate resolved.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
# shellcheck source=../lib/portable.sh
source hack/lib/portable.sh
# shellcheck source=../lib/addons.sh
source hack/lib/addons.sh

echo "== test_addon_renderer =="
R="$TMP/platform-hetzner.yaml"
render_platform hetzner-example "$R"

# Release name: the catalog's releaseName (argo-cd's Argo release is `argocd`), else the addon name.
assert_eq "$(addon_release_name "$R" argo-cd)" argocd "release name from catalog releaseName"
assert_eq "$(addon_release_name "$R" cert-manager)" cert-manager "release name defaults to the addon"

args=()
read_lines args addon_helm_args external-dns installations/hetzner-example "$R" workload dev-fsn1 hetzner development fsn1 cilium https://192.0.2.10:6443
all=$(printf '%s\n' "${args[@]}")
assert_eq "$(printf '%s\n' "$all" | grep -c '^installations/hetzner-example/installation.yaml$' || true)" 0 "raw installation.yaml is not passed"
vo="$R.values-external-dns.yaml"
assert_match "$all" "$vo" "valuesObject file passed as --values"
assert_eq "$(yq '.dns.provider' "$vo")" cloudflare "valuesObject carries installation facts"
assert_eq "$(yq 'has("addons")' "$vo")" false "valuesObject omits the catalog (addons)"
assert_eq "$(yq 'has("cluster")' "$vo")" false "valuesObject's per-cluster block comes from --set-string, not the goTemplate"
assert_eq "$(yq '.openchoreo.orgNamespace' "$vo")" default "valuesObject includes charts/platform defaults"
assert_match "$all" $'--set-string\nexternal-dns.txtOwnerId=hetzner-example-dev-fsn1' "clusterIdParameters resolved per cluster, forceString kept"
assert_match "$all" $'--set\nexternal-dns.domainFilters=\\{hetzner.example.com\\}' "installationParameters as typed --set"
# valuesObject sits after every value file and before cluster/params (ApplicationSet precedence)
last_vf=$(printf '%s\n' "$all" | grep -n -- '^--values$' | tail -1 | cut -d: -f1)
assert_eq "$(printf '%s\n' "$all" | sed -n "$((last_vf + 1))p")" "$vo" "valuesObject is the last value file"

# Server parts and cluster name for cilium / openchoreo-data-plane
args=()
read_lines args addon_helm_args cilium installations/hetzner-example "$R" workload dev-fsn1 hetzner development fsn1 cilium https://192.0.2.10:6443
all=$(printf '%s\n' "${args[@]}")
assert_match "$all" $'--set-string\ncilium.k8sServiceHost=192.0.2.10' "clusterServerParameters host (forceString)"
assert_match "$all" $'--set\ncilium.k8sServicePort=6443' "clusterServerParameters port (typed)"
args=()
read_lines args addon_helm_args openchoreo-data-plane installations/hetzner-example "$R" workload dev-fsn1 hetzner development fsn1 cilium https://192.0.2.10:6443
assert_match "$(printf '%s\n' "${args[@]}")" $'--set-string\nopenchoreo-data-plane.clusterAgent.planeID=dev-fsn1' "clusterNameParameters resolved (forceString)"

# Cluster labels (catalog clusterLabelParameters, label-selected value files): resolved from the labels file, else the
# catalog default / the else-branch; mesh members get values/mesh-member.yaml.
L="$TMP/platform-local.yaml"
render_platform local "$L"
printf '{"mesh.platform.koorikla.io/group": "local", "mesh.platform.koorikla.io/network": "dev1", "addons.platform.koorikla.io/istio-eastwest": "true"}\n' > "$TMP/labels-member.yaml"
args=()
read_lines args addon_helm_args istio-ambient installations/local "$L" workload dev1 docker development local cilium https://192.0.2.10:6443 "$TMP/labels-member.yaml"
all=$(printf '%s\n' "${args[@]}")
assert_match "$all" $'--values\naddons/istio-ambient/values/mesh-member.yaml' "mesh member: values/mesh-member.yaml"
assert_match "$all" $'--set-string\nglobal.network=dev1' "clusterLabelParameters: label value"
assert_match "$all" $'--set-string\nistiod.env.AMBIENT_ENABLE_MULTI_NETWORK=true' "clusterLabelParameters: label value over default"
args=()
read_lines args addon_helm_args istio-ambient installations/local "$L" workload dev2 docker development local cilium https://192.0.2.10:6443 /dev/null
all=$(printf '%s\n' "${args[@]}")
assert_eq "$(printf '%s\n' "$all" | grep -c 'values/mesh-member.yaml' || true)" 0 "no mesh group: no values/mesh-member.yaml (mesh-none.yaml, absent = ignored)"
assert_match "$all" $'--set-string\nglobal.network=\n' "missing label: empty"
assert_match "$all" $'--set-string\nistiod.env.AMBIENT_ENABLE_MULTI_NETWORK=false' "missing label: catalog default"
assert_eq "$(printf '%s\n' "$all" | grep -c '{{' || true)" 0 "no goTemplate left in any argument"

# clusterNameFormats (string with the cluster name inside) and fleetParameters (every cluster of the installation,
# sorted helm list), as the ApplicationSet renders them (falco: customfields; argo-events: Falco endpoints).
args=()
read_lines args addon_helm_args falco installations/hetzner-example "$R" workload dev-fsn1 hetzner development fsn1 cilium https://192.0.2.10:6443
assert_match "$(printf '%s\n' "${args[@]}")" $'--set-string\nfalco.falcosidekick.config.customfields=cluster:dev-fsn1' "clusterNameFormats resolved (forceString)"
fleet_want="{$( { yq -r '.mgmt.name // "mgmt"' installations/hetzner-example/installation.yaml; for f in installations/hetzner-example/clusters/*.yaml; do yq -r '.name' "$f"; done; } | tr -d '\r' | LC_ALL=C sort -u | paste -sd, -)}"
assert_eq "$(addon_fleet_names installations/hetzner-example)" "$fleet_want" "fleet names: mgmt + every cluster file, sorted"
args=()
read_lines args addon_helm_args argo-events installations/hetzner-example "$R" mgmt mgmt hetzner mgmt fsn1 flannel https://kubernetes.default.svc
assert_match "$(printf '%s\n' "${args[@]}")" $'--set\nfalco.clusters='"$(printf '%s' "$fleet_want" | sed 's/[{}]/\\&/g')" "fleetParameters resolved to the fleet list (typed --set)"
appset=$(addon_appset "$R" argo-events)
assert_eq "$(yq '.spec.generators[0].matrix.generators[1].clusters.flatList' <<<"$appset")" true "fleetParameters: matrix with a flat cluster list"
assert_eq "$(yq '.spec.generators[0].matrix.generators[0].clusters.selector.matchExpressions[0].values[0]' <<<"$appset")" mgmt "fleetParameters: the addon's own selector stays the first generator"
assert_eq "$(addon_appset "$R" falco | yq '.spec.generators[0].clusters.flatList // "none"')" none "no fleetParameters: plain cluster generator"

# clusterNameFormats needs exactly one %s
printf 'addons:\n  falco: { clusterNameFormats: { x: "no-placeholder" } }\n' > "$TMP/bad-fmt.yaml"
if out=$(helm template platform charts/platform --namespace argocd --values "$TMP/bad-fmt.yaml" 2>&1); then out=rendered; fi
assert_match "$out" 'clusterNameFormats.x: "no-placeholder" must contain exactly one %s' "clusterNameFormats without %s fails"

# Values are not @tsv-escaped (a backslash arrives once).
printf 'installation: { name: t, repoURL: https://example.test/r.git, githubOrg: https://example.test }\nregistry: { type: harbor, host: "a\\\\b.example.test" }\n' > "$TMP/inst.yaml"
helm template platform charts/platform --namespace argocd --values "$TMP/inst.yaml" > "$TMP/p.yaml"
assert_eq "$(addon_installation_params "$TMP/p.yaml" harbor)" $'harbor.externalURL\thttps://a\\b.example.test' "installation parameter keeps a single backslash"

finish
