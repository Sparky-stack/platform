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
helm template platform charts/platform --namespace argocd --values installations/hetzner-example/installation.yaml > "$R"

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
assert_match "$(printf '%s\n' "${args[@]}")" $'--set\nopenchoreo-data-plane.clusterAgent.planeID=dev-fsn1' "clusterNameParameters resolved"

# Values are not @tsv-escaped (a backslash arrives once).
printf 'installation: { name: t, repoURL: https://example.test/r.git, githubOrg: https://example.test }\nregistry: { type: harbor, host: "a\\\\b.example.test" }\n' > "$TMP/inst.yaml"
helm template platform charts/platform --namespace argocd --values "$TMP/inst.yaml" > "$TMP/p.yaml"
assert_eq "$(addon_installation_params "$TMP/p.yaml" harbor)" $'harbor.externalURL\thttps://a\\b.example.test' "installation parameter keeps a single backslash"

finish
