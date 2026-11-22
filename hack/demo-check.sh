#!/usr/bin/env bash
# Read-only pre-flight of the full platform demo (docs/demo.md): one or more checks per demo step against the live
# local stack, printed as a PASS / FAIL / PENDING table. Exit 1 when any check FAILs.
# Usage: hack/demo-check.sh                                                   (task demo:check)
#
# Read-only by construction: `kubectl get`, `kubectl get --raw` (API service proxy), `kubectl apply --dry-run=server`
# (admission runs, nothing is stored), curl GETs and `cosign verify`. Workload-cluster kubeconfigs are written by
# hack/kubeconfig.sh into a private temp dir and removed on exit; no secret value is printed.
#
# PENDING: nothing to check yet - a feature not merged (check returns 2, detail "#<issue> ..."), a production freeze
# window, or no promotion since a clean bootstrap. See docs/demo.md.
#
# Environment (defaults in brackets):
#   KUBE_CTX            mgmt kubectl context [k3d-platform-mgmt]
#   DEMO_NAMESPACE      OpenChoreo org namespace [default]
#   DEMO_COMPONENT      demo component [hello-world], DEMO_ENDPOINT its HTTP endpoint name [http]
#   DEMO_UNSIGNED_IMAGE image the signature policy must deny [a digest in ghcr.io/koorikla/hello-world CI never
#                       signed: the manifest of one build's attestations]
#   DEMO_HTTP_MODE      direct | docker: how app URLs on CAPD node IPs are reached [direct on Linux, docker elsewhere:
#                       only a native Linux host routes to container IPs (docs/dev-environment.md)]
#   DEMO_NOW            ISO 8601 time sync windows are evaluated at [now] (tests)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=lib/portable.sh
source hack/lib/portable.sh

CTX="${KUBE_CTX:-k3d-platform-mgmt}"
NS="${DEMO_NAMESPACE:-default}"
COMP="${DEMO_COMPONENT:-hello-world}"
ENDPOINT="${DEMO_ENDPOINT:-http}"
SECRET_ENV="${DEMO_SECRET_ENV:-GREETING_SECRET}"   # env var the demo Workload takes from a SecretReference
UNSIGNED_IMAGE="${DEMO_UNSIGNED_IMAGE:-ghcr.io/koorikla/hello-world@sha256:5760e176af0ec30cb8b06c80e99b3ab1746243c6c2d54997847ff850e8e38ad7}"
# = docs/dev-environment.md (client inside the CAPD network); multi-arch, pinned by digest.
CURL_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
OBS_NS=openchoreo-observability-plane
PROM_PROXY="/api/v1/namespaces/$OBS_NS/services/prometheus-operated:9090/proxy/api/v1/query"
KYVERNO_VALUES=addons/kyverno-policies/values.yaml
INSTALLATION=installations/local/installation.yaml

if [[ "$CTX" == koorikla ]]; then
  echo "refusing context 'koorikla' (homelab, AGENTS.md): set KUBE_CTX to the local mgmt context" >&2
  exit 2
fi
for bin in kubectl curl yq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required tool: $bin (mise install)" >&2; exit 2; }
done

KCDIR=$(mktemp -d)
trap 'rm -rf "$KCDIR"' EXIT

# ---- output ---------------------------------------------------------------------------------------------------------
N_PASS=0; N_FAIL=0; N_PENDING=0

row() { printf '%-4s %-46s %-12s %s\n' "$1" "$2" "$3" "$4"; }

# one_line <text>: newlines/tabs/CR folded to single spaces, at most 200 characters.
one_line() {
  local s
  s=$(printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/   */ /g; s/  */ /g; s/^ //; s/ $//')
  (( ${#s} > 200 )) && s="${s:0:197}..."
  printf '%s' "$s"
}

# check <step> <id> <title> <function> [args...]: the function prints a detail line and returns 0 (PASS), 1 (FAIL) or
# 2 (PENDING; detail starts with "#<issue> "). <id> only names the check in this file. Rows print as checks finish;
# the summary follows the table.
check() {
  local step=$1 title=$3 detail rc status
  shift 3
  detail=$("$@" 2>&1); rc=$?
  detail=$(one_line "$detail")
  case "$rc" in
    0) status=PASS ;;
    2) status=PENDING
       if [[ "$detail" =~ ^#([0-9]+)[[:space:]]*(.*)$ ]]; then
         status="PENDING #${BASH_REMATCH[1]}"; detail=${BASH_REMATCH[2]}
       fi ;;
    *) status=FAIL ;;
  esac
  case "$status" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    *) N_PENDING=$((N_PENDING + 1)) ;;
  esac
  row "$step" "$title" "$status" "$detail"
}

# ---- cluster access -------------------------------------------------------------------------------------------------
km() { kubectl --context "$CTX" --request-timeout=20s "$@"; }

# kw <cluster> <kubectl args...>: kubectl against a CAPD workload cluster (kubeconfig from hack/kubeconfig.sh).
kw() {
  local c=$1 f="$KCDIR/$1.kubeconfig"
  shift
  [[ -s "$f" ]] || { echo "no kubeconfig for cluster $c (hack/kubeconfig.sh failed)"; return 1; }
  kubectl --kubeconfig "$(native_path "$f")" --request-timeout=20s "$@"
}

# kc <cluster|mgmt> <kubectl args...>
kc() {
  local c=$1
  shift
  if [[ "$c" == mgmt ]]; then km "$@"; else kw "$c" "$@"; fi
}

fetch_kubeconfigs() {
  local c
  for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    bash hack/kubeconfig.sh "$c" "$KCDIR/$c.kubeconfig" >/dev/null 2>&1 || rm -f "$KCDIR/$c.kubeconfig"
  done
}

# http_code <url> [curl args...]: HTTP status (000 when unreachable), from this host.
http_code() {
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null) || true
  printf '%s' "${code:-000}"
}

# node_http_code <host> <port> <ip> <path>: like the docs' `curl --resolve <host>:<port>:<node ip>`, from this host
# (Linux) or from a container on docker network `kind` (Docker Desktop, Colima, OrbStack: container IPs unroutable).
node_http_code() {
  local host=$1 port=$2 ip=$3 path=$4 mode code
  mode="${DEMO_HTTP_MODE:-}"
  [[ -n "$mode" ]] || { if [[ "$(os_name)" == linux ]] && ! is_wsl; then mode=direct; else mode=docker; fi; }
  if [[ "$mode" == docker ]]; then
    code=$(MSYS_NO_PATHCONV=1 docker run --rm --network kind "$CURL_IMAGE" -s -o /dev/null -m 10 -w '%{http_code}' \
      --resolve "$host:$port:$ip" "http://$host:$port$path" 2>/dev/null) || true
    printf '%s' "${code:-000}"
  else
    http_code --resolve "$host:$port:$ip" "http://$host:$port$path"
  fi
}

# prom_query <promql>: Prometheus of the observability plane through the API server's service proxy (JSON).
prom_query() {
  local q
  q=$(printf '%s' "$1" | sed 's/%/%25/g; s/ /%20/g; s/"/%22/g; s/{/%7B/g; s/}/%7D/g; s/=/%3D/g; s/!/%21/g; s/(/%28/g; s/)/%29/g; s/,/%2C/g')
  km get --raw "$PROM_PROXY?query=$q"
}

# prom_label_values <label> <json>: values of <label> in a Prometheus vector result (no jq needed).
prom_label_values() {
  printf '%s' "$2" | grep -o "\"$1\":\"[^\"]*\"" | sed "s/^\"$1\":\"//; s/\"\$//" | sort -u
}

# ---- parsers (stdin -> detail, rc) ----------------------------------------------------------------------------------
# lines "<name> <sync> <health>"
summarize_apps() {
  awk 'NF { n++; if ($2 == "Synced" && $3 == "Healthy") ok++; else bad = bad (bad ? ", " : "") $1 "(" $2 "/" $3 ")" }
    END { if (!n) { print "no Applications listed (API server down or Argo CD missing)"; exit 1 }
          printf "%d/%d Synced/Healthy", ok, n; if (bad) { printf "; not: %s\n", bad; exit 1 } print "" }'
}

# lines "<name> <phase> <Available status>"
summarize_clusters() {
  awk 'NF { n++; if ($2 == "Provisioned" && $3 == "True") ok = ok (ok ? ", " : "") $1; else bad = bad (bad ? ", " : "") $1 "(" $2 "/available=" ($3 == "" ? "?" : $3) ")" }
    END { if (!n) { print "no CAPI clusters in namespace fleet"; exit 1 }
          if (bad) { print "not ready: " bad (ok ? "; ok: " ok : ""); exit 1 } print ok " Provisioned/Available" }'
}

# lines "<name> <connected> <connectedAgents>"
summarize_dataplanes() {
  awk 'NF { n++; if ($2 == "true") ok = ok (ok ? ", " : "") $1 "(" $3 " agent)"; else bad = bad (bad ? ", " : "") $1 }
    END { if (!n) { print "no ClusterDataPlanes"; exit 1 }
          if (bad) { print "agent not connected: " bad; exit 1 } print "connected: " ok }'
}

# lines "<kind> <name> <ready>" (ready: true/false/empty)
summarize_policies() {
  awk 'NF { n++; if ($3 == "true") ok++; else bad = bad (bad ? ", " : "") $2 }
    END { if (!n) { print "no Kyverno policies"; exit 1 }
          if (bad) { printf "%d/%d Ready; not: %s\n", ok, n, bad; exit 1 } printf "%d/%d Ready\n", ok, n }'
}

# lines "<kind> <name> <want> <have>" (DaemonSet desired/ready, Deployment replicas/ready; empty -> 0)
summarize_workloads() {
  awk 'NF { n++; w = $3 + 0; h = $4 + 0; if (w > 0 && w == h) ok = ok (ok ? ", " : "") $2 " " h "/" w; else bad = bad (bad ? ", " : "") $2 " " h "/" w }
    END { if (!n) { print "no workloads found"; exit 1 }
          if (bad) { print "not ready: " bad; exit 1 } print ok }'
}

# lines "<created> <name> <succeeded> <failed>" (condition statuses) -> latest run's outcome
latest_run() {
  sort | awk 'NF { last = $0 } END { if (last == "") exit 1; print last }'
}

# lines "<name> <ready>" (ClusterSecretStores)
summarize_stores() {
  awk 'NF { n++; if ($2 == "True") ok = ok (ok ? ", " : "") $1; else bad = bad (bad ? ", " : "") $1 }
    END { if (!n) { print "no ClusterSecretStores"; exit 1 }
          if (bad) { print "not Ready: " bad; exit 1 } print "Ready: " ok }'
}

# ---- lookups --------------------------------------------------------------------------------------------------------
# env_names: environments of the org namespace, non-production first (= promotion order of the demo).
env_names() {
  km get environments.openchoreo.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.isProduction}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk 'NF == 2 { print ($1 == "true" ? 1 : 0), $2 } NF == 1 { print 0, $1 }' | sort | awk '{ print $2 }'
}

production_env() {
  km get environments.openchoreo.dev -n "$NS" \
    -o jsonpath='{range .items[?(@.spec.isProduction==true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1
}

env_dataplane() {
  km get environments.openchoreo.dev -n "$NS" "$1" -o jsonpath='{.spec.dataPlaneRef.name}' 2>/dev/null
}

# node_ip <cluster>: InternalIP of the cluster's first CAPI Machine (= the CAPD node container IP).
node_ip() {
  km get machines.cluster.x-k8s.io -n fleet -l "cluster.x-k8s.io/cluster-name=$1" \
    -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' \
    2>/dev/null | head -n1
}

# latest_image: the image the demo component's Workload deploys (what CI built last).
latest_image() {
  km get workloads.openchoreo.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.spec.owner.componentName}{" "}{.spec.container.image}{"\n"}{end}' 2>/dev/null \
    | awk -v c="$COMP" '$1 == c && $2 != "" { print $2; exit }'
}

# cell_namespace <cluster> <env>: the OpenChoreo cell (dp-*) namespace of the env on that cluster.
cell_namespace() {
  kw "$1" get namespaces \
    -l "openchoreo.dev/managed-by=renderedrelease-controller,openchoreo.dev/environment=$2,openchoreo.dev/namespace=$NS" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1
}

# dry_run_pod <cluster> <namespace> <image>: server-side dry-run of a minimal pod (admission only, nothing stored).
dry_run_pod() {
  printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"demo-check-%s","namespace":"%s"},"spec":{"containers":[{"name":"app","image":"%s"}]}}\n' \
    "$(date +%s)" "$2" "$3" | kw "$1" apply --dry-run=server -f - 2>&1
}

short_image() { printf '%s' "$1" | sed -E 's/@sha256:([0-9a-f]{12})[0-9a-f]+/@sha256:\1.../'; }

# join_comma: non-empty stdin lines as "a, b, c".
join_comma() { grep . | paste -sd, - | sed 's/,/, /g'; }

# first_error <cosign output>: its first line mentioning an error, else its last line.
first_error() { printf '%s\n' "$1" | grep -m1 -i 'error' || printf '%s' "$1" | tail -n1; }

# release_bindings: "<component> <env> <release> <Ready reason>" for every ReleaseBinding of the org namespace.
release_bindings() {
  km get releasebindings.openchoreo.dev -n "$NS" -o jsonpath='{range .items[*]}{.spec.owner.componentName}{" "}{.spec.environment}{" "}{.spec.releaseName}{" "}{.status.conditions[?(@.type=="Ready")].reason}{"\n"}{end}' 2>/dev/null
}

# ---- step 1: clean bootstrap ----------------------------------------------------------------------------------------
# An app OutOfSync only because an active deny sync window holds it (production freeze, docs/promotion.md#5-freeze-window-optional)
# is PENDING, not FAIL. Argo CD does not report that, so hack/lib/syncwindow.py evaluates the windows.
# frozen_apps: lines "<app>\t<window description>\t<end>", cached in $KCDIR (checks run in subshells); returns 1 with
# the reason on stdout when the windows cannot be evaluated.
frozen_apps() {
  local apps="$KCDIR/applications.json" projects="$KCDIR/appprojects.json" cache="$KCDIR/frozen"
  [[ -f "$cache" ]] && { cat "$cache"; return 0; }
  if ! { km get applications.argoproj.io -n argocd -o json > "$apps" 2>/dev/null \
    && km get appprojects.argoproj.io -n argocd -o json > "$projects" 2>/dev/null \
    && py hack/lib/syncwindow.py "$(native_path "$apps")" "$(native_path "$projects")" ${DEMO_NOW:+"$DEMO_NOW"} \
      > "$cache.tmp" 2> "$KCDIR/syncwindow.err"; }; then
    echo "sync windows not evaluated: $(tail -n 1 "$KCDIR/syncwindow.err" 2>/dev/null)"; return 1
  fi
  mv "$cache.tmp" "$cache"; cat "$cache"
}

# frozen_env <env>: the freeze reason when the demo component has no ReleaseBinding for <env> and an active deny window
# holds its Argo CD Application (<project>-<component>-<env>): nothing to check there until the window ends.
frozen_env() {
  local bindings why
  bindings=$(release_bindings) || return 1
  printf '%s\n' "$bindings" | awk -v c="$COMP" -v e="$1" '$1 == c && $2 == e { f = 1 } END { exit !f }' && return 1
  why=$(frozen_apps 2>/dev/null | awk -F '\t' -v s="-$COMP-$1" 'substr($1, length($1) - length(s) + 1) == s {
    printf "%s frozen by sync window \"%s\" until %s", $1, $2, $3; exit }') || return 1
  [[ -n "$why" ]] && echo "$why"
}

c_argo_apps() {
  local out detail frozen names why rest
  out=$(km get applications.argoproj.io -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}') \
    || { echo "cannot list Argo CD Applications (context $CTX)"; return 1; }
  detail=$(printf '%s\n' "$out" | summarize_apps) && { echo "$detail"; return 0; }
  frozen=$(frozen_apps) || { echo "$detail ($frozen)"; return 1; }
  [[ -n "$frozen" ]] || { echo "$detail"; return 1; }
  names=" $(printf '%s\n' "$frozen" | cut -f1 | tr '\n' ' ')"
  why=$(printf '%s\n' "$frozen" | awk -F '\t' '{ printf "%s%s frozen by sync window \"%s\" until %s", (NR > 1 ? "; " : ""), $1, $2, $3 }')
  # Pass/fail on the apps no active window holds; any other OutOfSync/unhealthy app still FAILs.
  rest=$(printf '%s\n' "$out" | awk -v f="$names" 'NF && !index(f, " " $1 " ")')
  if [[ -z "$rest" ]] || printf '%s\n' "$rest" | summarize_apps >/dev/null; then
    echo "${detail%%;*}; $why"; return 2
  fi
  echo "$detail; $why"; return 1
}

# ---- step 2: add a cluster by adding a file -------------------------------------------------------------------------
c_clusters() {
  local out
  out=$(km get clusters.cluster.x-k8s.io -n fleet \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}') \
    || { echo "cannot list CAPI clusters"; return 1; }
  printf '%s\n' "$out" | summarize_clusters
}

c_dataplanes() {
  local out
  out=$(km get clusterdataplanes.openchoreo.dev \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.agentConnection.connected}{" "}{.status.agentConnection.connectedAgents}{"\n"}{end}') \
    || { echo "cannot list ClusterDataPlanes"; return 1; }
  printf '%s\n' "$out" | summarize_dataplanes
}

# The same cluster file contract rendered for the other providers' installations (offline: helm template only).
c_render_providers() {
  local inst_dir inst cf name out ok="" bad=""
  command -v helm >/dev/null 2>&1 || { echo "helm not found (mise install)"; return 1; }
  for inst_dir in installations/*; do
    inst=$(basename "$inst_dir")
    [[ -f "$inst_dir/installation.yaml" && "$inst" != local ]] || continue
    for cf in "$inst_dir"/clusters/*.yaml; do
      [[ -f "$cf" ]] || continue
      name=$(yq '.name' "$cf")
      if out=$(helm template "cluster-$name" charts/cluster --namespace fleet --values "$inst_dir/installation.yaml" \
          --values "$cf" 2>&1) && printf '%s\n' "$out" | grep -q '^kind: Cluster$'; then
        ok="$ok${ok:+, }$inst/$name($(yq '.provider' "$cf"))"
      else
        bad="$bad${bad:+, }$inst/$name"
      fi
    done
  done
  [[ -n "$ok$bad" ]] || { echo "no non-local installation cluster files"; return 1; }
  [[ -z "$bad" ]] || { echo "render failed: $bad"; return 1; }
  echo "renders: $ok"
}

# ---- step 3: developer self-service ---------------------------------------------------------------------------------
c_console() {
  local url=http://openchoreo.localhost:8080/ code
  code=$(http_code "$url")
  echo "$code $url"
  [[ "$code" == 200 ]]
}

c_component_types() {
  local out n
  out=$(km get clustercomponenttypes.openchoreo.dev -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') \
    || { echo "cannot list ClusterComponentTypes"; return 1; }
  n=$(printf '%s\n' "$out" | grep -c . || true)
  [[ "$n" -gt 0 ]] || { echo "no ClusterComponentTypes"; return 1; }
  echo "$n: $(printf '%s\n' "$out" | join_comma)"
}

# ---- step 4: build & supply chain -----------------------------------------------------------------------------------
# platform_prefix: <registry.host>/<registry.appsProject>/ of the installation (empty without a registry host).
platform_prefix() {
  local host project
  host=$(yq '.registry.host // ""' "$INSTALLATION" 2>/dev/null)
  project=$(yq '.registry.appsProject // "apps"' "$INSTALLATION" 2>/dev/null)
  [[ -n "$host" ]] && printf '%s/%s/' "$host" "$project"
}

# cosign_platform <image>: verify an in-cluster build with the platform key (cosign.pub of store key cosign-platform,
# public), the registry CA (public) and the pull-only robot `nodes` (private apps project; written into a docker config
# in the private temp dir, never printed). No public tlog by default (buildWorkflows.signing.transparencyLog).
cosign_platform() {
  local image=$1 host=${1%%/*} d="$KCDIR/cosign" pw err
  mkdir -p "$d/docker"
  km get secret -n platform-secrets cosign-platform -o jsonpath='{.data.cosign\.pub}' | b64dec > "$d/cosign.pub" \
    && [[ -s "$d/cosign.pub" ]] || { echo "cannot read cosign.pub (platform-secrets/cosign-platform)"; return 1; }
  km get secret -n harbor harbor-ca-bundle -o jsonpath='{.data.ca\.crt}' | b64dec > "$d/ca.crt" \
    && [[ -s "$d/ca.crt" ]] || { echo "cannot read the registry CA (harbor/harbor-ca-bundle)"; return 1; }
  pw=$(km get secret -n platform-secrets harbor -o jsonpath='{.data.nodes-secret}' | b64dec) \
    && [[ -n "$pw" ]] || { echo "cannot read the registry robot (platform-secrets/harbor nodes-secret)"; return 1; }
  # shellcheck disable=SC2016  # robot$nodes is Harbor's literal robot name
  ( umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$host" "$(printf 'robot$nodes:%s' "$pw" | base64 | tr -d '\n')" \
      > "$d/docker/config.json" )
  if ! err=$(DOCKER_CONFIG="$d/docker" cosign verify --timeout 60s --key "$d/cosign.pub" --insecure-ignore-tlog=true \
      --registry-cacert "$d/ca.crt" "$image" 2>&1 >/dev/null); then
    echo "$(short_image "$image") NOT verified: $(first_error "$err")"
    return 1
  fi
  echo "$(short_image "$image") signed by the platform key (in-cluster build)"
}

c_cosign() {
  local image repo issuer workflow ref trig wref err prefix
  command -v cosign >/dev/null 2>&1 || { echo "cosign not found (mise install)"; return 1; }
  image=$(latest_image)
  [[ -n "$image" ]] || { echo "no Workload image for component $COMP in namespace $NS"; return 1; }
  [[ "$image" == *@sha256:* ]] || { echo "$image is not pinned by digest"; return 1; }
  prefix=$(platform_prefix)
  if [[ -n "$prefix" && "$image" == "$prefix"* ]]; then cosign_platform "$image"; return; fi
  repo=${image#ghcr.io/}; repo=${repo%%@*}; repo=${repo%%:*}
  issuer=$(yq '.imageVerification.github.issuer' "$KYVERNO_VALUES")
  workflow=$(yq '.imageVerification.github.workflow' "$KYVERNO_VALUES")
  wref=$(yq '.imageVerification.github.workflowRef' "$KYVERNO_VALUES")
  ref=$(yq '.imageVerification.github.trustedSources[0].ref' "$KYVERNO_VALUES")
  trig=$(yq '.imageVerification.github.trustedSources[0].trigger' "$KYVERNO_VALUES")
  if ! err=$(cosign verify --timeout 60s \
      --certificate-oidc-issuer "$issuer" --certificate-identity "$workflow@$wref" \
      --certificate-github-workflow-repository "$repo" --certificate-github-workflow-ref "$ref" \
      --certificate-github-workflow-trigger "$trig" "$image" 2>&1 >/dev/null); then
    echo "$(short_image "$image") NOT verified: $(first_error "$err")"
    return 1
  fi
  echo "$(short_image "$image") signed by ${workflow##*/}@${wref:0:7} ($repo, $ref, $trig)"
}

c_kyverno() {
  local out
  out=$(kw "$1" get imagevalidatingpolicies.policies.kyverno.io,validatingpolicies.policies.kyverno.io \
    -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.status.conditionStatus.ready}{"\n"}{end}') \
    || { echo "cannot list Kyverno policies on $1"; return 1; }
  printf '%s\n' "$out" | summarize_policies
}

# prod_target: "<cluster> <cell namespace>" of the production environment (where images must be signed: Deny).
prod_target() {
  local env dp ns
  env=$(production_env)
  [[ -n "$env" ]] || { echo "no production Environment in namespace $NS"; return 1; }
  dp=$(env_dataplane "$env")
  ns=$(cell_namespace "$dp" "$env")
  [[ -n "$ns" ]] || { echo "no cell namespace for environment $env on $dp"; return 1; }
  echo "$dp $ns"
}

c_admit_signed() {
  local t dp ns image out
  t=$(prod_target) || { echo "$t"; return 1; }
  dp=${t%% *}; ns=${t#* }
  image=$(latest_image)
  [[ -n "$image" ]] || { echo "no Workload image for component $COMP"; return 1; }
  out=$(dry_run_pod "$dp" "$ns" "$image")
  if [[ "$out" == *"created (server dry run)"* ]]; then
    echo "$(short_image "$image") admitted in $dp/$ns (dry-run)"
  else
    echo "$(short_image "$image") rejected in $dp/$ns: $out"
    return 1
  fi
}

c_deny_unsigned() {
  local t dp ns out
  t=$(prod_target) || { echo "$t"; return 1; }
  dp=${t%% *}; ns=${t#* }
  out=$(dry_run_pod "$dp" "$ns" "$UNSIGNED_IMAGE")
  if [[ "$out" == *"denied the request"* ]]; then
    echo "denied in $dp/$ns: $(printf '%s' "$out" | sed -n 's/^.*Policy [^ ]* failed: //p' | cut -d';' -f1)"
  elif [[ "$out" == *"created (server dry run)"* ]]; then
    echo "UNSIGNED IMAGE ADMITTED in $dp/$ns: $(short_image "$UNSIGNED_IMAGE")"
    return 1
  else
    echo "dry-run error in $dp/$ns: $out"
    return 1
  fi
}

# workflow_runs: "<created> <name> <workflow> <succeeded> <failed>" for every WorkflowRun of the org namespace.
workflow_runs() {
  km get workflowruns.openchoreo.dev -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{" "}{.metadata.name}{" "}{.spec.workflow.name}{" "}{.status.conditions[?(@.type=="WorkflowSucceeded")].status}{"/"}{.status.conditions[?(@.type=="WorkflowFailed")].status}{"\n"}{end}'
}

# outcome <succeeded>/<failed> -> succeeded | failed | running
outcome() {
  case "$1" in
    True/*) echo succeeded ;;
    */True) echo failed ;;
    *) echo running ;;
  esac
}

c_build_in_cluster() {
  local out last result
  out=$(workflow_runs) || { echo "cannot list WorkflowRuns"; return 1; }
  last=$(printf '%s\n' "$out" | awk 'NF >= 3 && $3 != "promotion-gate"' | latest_run) \
    || { echo "no build WorkflowRun in namespace $NS (workflow plane: ClusterWorkflowPlane default)"; return 1; }
  # shellcheck disable=SC2086  # split the run line into its fields
  set -- $last
  result=$(outcome "${4:-/}")
  echo "latest build $2 ($3): $result"
  [[ "$result" == succeeded ]]
}

# ---- step 5: deploy & promote ---------------------------------------------------------------------------------------
c_http() {
  local env=$1 dp gw host port ip code path rel
  dp=$(env_dataplane "$env")
  [[ -n "$dp" ]] || { echo "environment $env has no dataPlaneRef"; return 1; }
  gw=$(km get clusterdataplanes.openchoreo.dev "$dp" \
    -o jsonpath='{.spec.gateway.ingress.external.http.host}{" "}{.spec.gateway.ingress.external.http.port}' 2>/dev/null)
  host=${gw% *}; port=${gw#* }
  [[ -n "$host" && -n "$port" && "$host" != "$port" ]] || { echo "ClusterDataPlane $dp has no external HTTP gateway"; return 1; }
  ip=$(node_ip "$dp")
  [[ -n "$ip" ]] || { echo "no node IP for cluster $dp"; return 1; }
  path="/$COMP-$ENDPOINT/"
  code=$(node_http_code "$env-$NS.$host" "$port" "$ip" "$path")
  [[ "$code" == 200 ]] && { echo "$code http://$env-$NS.$host:$port$path (node $ip)"; return 0; }
  rel=$(unpromoted_release "$env")
  if [[ -n "$rel" ]]; then
    echo "$code: not promoted in this stack yet - $env pins $rel, not a ComponentRelease of this stack (promote: docs/demo.md \"After a clean bootstrap\")"
    return 2
  fi
  rel=$(frozen_env "$env") && { echo "$code: $rel"; return 2; }
  echo "$code http://$env-$NS.$host:$port$path (node $ip)"
  return 1
}

# c_resilience: production pods carry the resilience defaults of the Deployment component types (#251): PDB
# maxUnavailable 1, spread over nodes and zones, PriorityClass app-production.
c_resilience() {
  local env dp ns dep pdb rel
  env=$(production_env); dp=$(env_dataplane "$env")
  [[ -n "$env" && -n "$dp" ]] || { echo "no production environment with a data plane"; return 1; }
  ns=$(cell_namespace "$dp" "$env")
  dep=$(kw "$dp" get deployments -n "${ns:-none}" -l "openchoreo.dev/component=$COMP" \
    -o jsonpath='{.items[0].metadata.name} {.items[0].spec.template.spec.priorityClassName} {.items[0].spec.template.spec.topologySpreadConstraints[*].topologyKey}' 2>/dev/null)
  if [[ -z "${dep// /}" ]]; then
    rel=$(unpromoted_release "$env")
    [[ -n "$rel" ]] && { echo "not promoted in this stack yet ($env pins $rel)"; return 2; }
    rel=$(frozen_env "$env") && { echo "not deployed yet: $rel"; return 2; }
    echo "no $COMP Deployment in $env (cell ${ns:-missing})"; return 1
  fi
  pdb=$(kw "$dp" get poddisruptionbudgets -n "$ns" -l "openchoreo.dev/component=$COMP" \
    -o jsonpath='{.items[0].spec.maxUnavailable}/{.items[0].spec.unhealthyPodEvictionPolicy}' 2>/dev/null)
  echo "$dep pdb=$pdb"
  [[ "$pdb" == "1/AlwaysAllow" && "$dep" == *" app-production "* && "$dep" == *kubernetes.io/hostname* \
    && "$dep" == *topology.kubernetes.io/zone* ]]
}

# unpromoted_release <env>: the release the component's binding for <env> pins when this stack has no such
# ComponentRelease (a clean bootstrap keeps git's release names; docs/demo.md "After a clean bootstrap"), else empty.
unpromoted_release() {
  local out
  out=$(release_bindings) || return 0
  printf '%s\n' "$out" | awk -v c="$COMP" -v e="$1" '$1 == c && $2 == e && $4 == "ComponentReleaseNotFound" { print $3; exit }'
}

# gate_not_run_yet: true (and says why) when no gate run is expected (the gate runs on promotion): nothing promoted
# since this clean bootstrap, or the freeze holds production's Application.
gate_not_run_yet() {
  local prod rel
  prod=$(production_env)
  rel=$(unpromoted_release "$prod")
  if [[ -z "$rel" ]]; then
    rel=$(frozen_env "$prod") || return 1
    echo "no promotion-gate run yet: $rel"; return 0
  fi
  echo "no promotion-gate run yet: not promoted in this stack ($prod pins $rel)"
}

c_gate_runs() {
  local out n
  km get clusterworkflows.openchoreo.dev promotion-gate -o name >/dev/null 2>&1 \
    || { echo "ClusterWorkflow promotion-gate missing"; return 1; }
  out=$(workflow_runs) || { echo "cannot list WorkflowRuns"; return 1; }
  n=$(printf '%s\n' "$out" | awk '$3 == "promotion-gate"' | grep -c . || true)
  [[ "$n" -gt 0 ]] || { gate_not_run_yet && return 2
    echo "no promotion-gate WorkflowRun in $NS (runs expire 1h after completion; promote to start one)"; return 1; }
  echo "$n promotion-gate run(s) in $NS"
}

c_gate_latest() {
  local out last result
  out=$(workflow_runs) || { echo "cannot list WorkflowRuns"; return 1; }
  last=$(printf '%s\n' "$out" | awk '$3 == "promotion-gate"' | latest_run) || { gate_not_run_yet && return 2
    echo "no promotion-gate run"; return 1; }
  # shellcheck disable=SC2086  # split the run line into its fields
  set -- $last
  result=$(outcome "${4:-/}")
  echo "$2: $result"
  [[ "$result" == succeeded ]]
}

# ---- step 6: observe ------------------------------------------------------------------------------------------------
c_metrics_clusters() {
  local json have c missing=""
  json=$(prom_query 'count by (k8s_cluster_name) ({k8s_cluster_name!=""})') \
    || { echo "Prometheus of the observability plane not reachable (service proxy)"; return 1; }
  have=$(prom_label_values k8s_cluster_name "$json")
  for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    printf '%s\n' "$have" | grep -qx "$c" || missing="$missing${missing:+, }$c"
  done
  [[ -z "$missing" ]] || { echo "no series from: $missing"; return 1; }
  echo "series from: $(printf '%s\n' "$have" | join_comma)"
}

c_metrics_app() {
  local json envs
  json=$(prom_query "count by (label_openchoreo_dev_environment) (kube_pod_labels{label_openchoreo_dev_component=\"$COMP\"})") \
    || { echo "Prometheus of the observability plane not reachable (service proxy)"; return 1; }
  envs=$(prom_label_values label_openchoreo_dev_environment "$json" | join_comma)
  [[ -n "$envs" ]] || { echo "no $COMP pod metrics in the observability plane"; return 1; }
  echo "$COMP pods seen in: $envs"
}

# ---- step 7: runtime security ---------------------------------------------------------------------------------------
c_falco() {
  local out
  out=$(kc "$1" get daemonsets,deployments -n falco \
    -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.status.desiredNumberScheduled}{.spec.replicas}{" "}{.status.numberReady}{.status.readyReplicas}{"\n"}{end}') \
    || { echo "cannot list namespace falco on $1"; return 1; }
  printf '%s\n' "$out" | summarize_workloads
}

c_falco_escalation() {
  local deployed
  deployed=$(km get sensors.argoproj.io -n argo-events falco-escalation \
    -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status}' 2>/dev/null) \
    || { echo "Sensor argo-events/falco-escalation missing"; return 1; }
  [[ "$deployed" == True ]] || { echo "Sensor falco-escalation not Deployed"; return 1; }
  km get workflowtemplates.argoproj.io -n argo-events falco-response -o name >/dev/null 2>&1 \
    || { echo "WorkflowTemplate argo-events/falco-response missing"; return 1; }
  echo "Sensor falco-escalation Deployed, WorkflowTemplate falco-response present"
}

c_falco_cluster_name() {
  local c fields ok="" bad=""
  for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    fields=$(kw "$c" get deployment -n falco falco-falcosidekick \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CUSTOMFIELDS")].value}' 2>/dev/null)
    if [[ ",$fields," == *",cluster:$c,"* ]]; then ok="$ok${ok:+, }$c"; else bad="$bad${bad:+, }$c"; fi
  done
  [[ -z "$bad" ]] || { echo "falcosidekick customfields lack cluster:<name> on: $bad"; return 1; }
  echo "cluster:<name> in events of: $ok"
}

# ---- step 8: zero trust ---------------------------------------------------------------------------------------------
# Mesh members (CAPI Clusters labelled mesh.platform.koorikla.io/group): Issuer istio-system/openbao-mesh (Vault issuer
# for OpenBao on mgmt) is Ready and issued istiod's serving Certificate (addons/mesh templates/csr-issuer.yaml).
c_mesh_certs() {
  local apps members c iss crt ok="" bad="" skip=""
  apps=$(km get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  printf '%s\n' "$apps" | grep -q '^openbao-' || { echo "OpenBao addon not installed on mgmt"; return 1; }
  members=$(km get clusters.cluster.x-k8s.io -n fleet -l mesh.platform.koorikla.io/group \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    printf '%s\n' "$members" | grep -qx "$c" || { skip="$skip${skip:+, }$c"; continue; }
    iss=$(kw "$c" get issuers.cert-manager.io -n istio-system openbao-mesh \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.spec.vault.server}' 2>/dev/null)
    crt=$(kw "$c" get certificates.cert-manager.io -n istio-system istiod \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{" "}{.spec.issuerRef.name}{" "}{.status.notAfter}' 2>/dev/null)
    # shellcheck disable=SC2086  # split into Ready, server
    set -- $iss
    if [[ "${1:-}" != True || -z "${2:-}" ]]; then
      bad="$bad${bad:+, }$c(Issuer openbao-mesh Ready=${1:-missing})"; continue
    fi
    # shellcheck disable=SC2086  # split into Ready, issuer, notAfter
    set -- $crt
    if [[ "${1:-}" != True || "${2:-}" != openbao-mesh ]]; then
      bad="$bad${bad:+, }$c(Certificate istiod Ready=${1:-missing} issuer=${2:-?})"; continue
    fi
    ok="$ok${ok:+, }$c(istiod until ${3:-?})"
  done
  [[ -z "$bad" ]] || { echo "not issued by OpenBao: $bad${ok:+; ok: $ok}"; return 1; }
  [[ -n "$ok" ]] || { echo "no mesh member (fleet file mesh.group) among: ${CLUSTERS[*]:-none}"; return 1; }
  echo "OpenBao-issued: $ok${skip:+; not mesh members: $skip}"
}

c_secret_stores() {
  local out
  out=$(kc "$1" get clustersecretstores.external-secrets.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}') \
    || { echo "cannot list ClusterSecretStores on $1"; return 1; }
  printf '%s\n' "$out" | summarize_stores
}

# c_app_secret: in the first environment, the component's Deployment takes $SECRET_ENV from a Secret that an
# ExternalSecret on SecretStore openbao-tenant keeps synced (docs/openchoreo.md "Secrets"). Only the value's length is read.
c_app_secret() {
  local env dp ns name es len
  env=$(env_names | head -n1)
  dp=$(env_dataplane "$env")
  ns=$(cell_namespace "$dp" "$env")
  [[ -n "$ns" ]] || { echo "no cell namespace for environment '${env:-none}' on '${dp:-none}'"; return 1; }
  for name in $(kw "$dp" -n "$ns" get deployments -l "openchoreo.dev/component=$COMP" \
      -o jsonpath='{range .items[*].spec.template.spec.containers[*].envFrom[*]}{.secretRef.name}{"\n"}{end}'); do
    len=$(kw "$dp" -n "$ns" get secret "$name" -o jsonpath="{.data.$SECRET_ENV}" 2>/dev/null | wc -c)
    (( len > 0 )) || continue
    es=$(kw "$dp" -n "$ns" get externalsecrets.external-secrets.io "$name" -o jsonpath='{.spec.secretStoreRef.kind}/{.spec.secretStoreRef.name} {.spec.refreshInterval} {.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$es" =~ ^SecretStore/openbao-tenant\ [0-9]+[smh]\ True$ ]] \
      || { echo "$ns/$name: ExternalSecret is '${es:-missing}' (want SecretStore/openbao-tenant <refresh> True)"; return 1; }
    echo "$env: $SECRET_ENV from ExternalSecret $name (${es% True}) Ready"
    return 0
  done
  echo "$env ($ns): no Secret of $COMP's Deployment carries $SECRET_ENV (SecretReference not deployed or not synced)"
  return 1
}

# ---- step 9: app with a database ------------------------------------------------------------------------------------
# On every workload cluster opted in to addon crossplane (docs/data-services.md) the PostgreSQL XRD is Established.
# No opted-in cluster fails: step 9 has nothing to show.
c_postgres() {
  local apps c est ok="" bad=""
  apps=$(km get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
    printf '%s\n' "$apps" | grep -qx "crossplane-$c" || continue
    est=$(kw "$c" get compositeresourcedefinitions.apiextensions.crossplane.io postgresqls.platform.koorikla.io \
      -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true)
    if [[ "$est" == True ]]; then ok="$ok${ok:+, }$c"; else bad="$bad${bad:+, }$c(Established=${est:-missing})"; fi
  done
  [[ -z "$bad" ]] || { echo "XRD postgresqls.platform.koorikla.io not Established on: $bad${ok:+; ok: $ok}"; return 1; }
  [[ -n "$ok" ]] || { echo "no workload cluster opts in to addon crossplane (fleet file addons.crossplane + cloudnative-pg)"; return 1; }
  echo "XRD postgresqls.platform.koorikla.io Established on: $ok"
}

# c_db_claim: the component's postgresql Resource is bound and Ready in the first environment and its Deployment reads
# the XR's <xr>-app Secret (docs/data-services.md "PostgreSQL from OpenChoreo"). PENDING while it declares no Resource.
c_db_claim() {
  local ref res="" env dp ns rrb secret xr ready refs
  for ref in $(km get workloads.openchoreo.dev -n "$NS" \
      -o jsonpath='{range .items[*]}{.spec.owner.componentName}{" "}{.spec.dependencies.resources[*].ref}{"\n"}{end}' \
      2>/dev/null | awk -v c="$COMP" '$1 == c { $1 = ""; print }'); do
    [[ "$(km get resources.openchoreo.dev -n "$NS" "$ref" -o jsonpath='{.spec.type.kind}/{.spec.type.name}' 2>/dev/null)" \
      == ClusterResourceType/postgresql ]] && { res=$ref; break; }
  done
  [[ -n "$res" ]] || { echo "$COMP declares no postgresql Resource (app repo deploy/openchoreo, docs/data-services.md)"; return 2; }
  env=$(env_names | head -n1)
  rrb=$(km get resourcereleasebindings.openchoreo.dev -n "$NS" -o jsonpath='{range .items[*]}{.spec.owner.resourceName}{" "}{.spec.environment}{" "}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.outputs[?(@.name=="username")].secretKeyRef.name}{"\n"}{end}' \
    2>/dev/null | awk -v r="$res" -v e="$env" '$1 == r && $2 == e { print $3, $4, $5; exit }')
  [[ -n "$rrb" ]] || { echo "Resource $res has no ResourceReleaseBinding for environment '${env:-none}'"; return 1; }
  read -r rrb ready secret <<<"$rrb"
  [[ "$ready" == True && "$secret" == *-app ]] \
    || { echo "ResourceReleaseBinding $rrb: Ready=${ready:-unknown}, username secret '${secret:-none}'"; return 1; }
  xr=${secret%-app}
  dp=$(env_dataplane "$env")
  ns=$(cell_namespace "$dp" "$env")
  [[ -n "$ns" ]] || { echo "no cell namespace for environment '$env' on '${dp:-none}'"; return 1; }
  ready=$(kw "$dp" -n "$ns" get postgresqls.platform.koorikla.io "$xr" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [[ "$ready" == True ]] || { echo "$dp/$ns: PostgreSQL $xr Ready=${ready:-missing}"; return 1; }
  refs=$(kw "$dp" -n "$ns" get deployments -l "openchoreo.dev/component=$COMP" \
    -o jsonpath='{range .items[*].spec.template.spec.containers[*].env[*]}{.valueFrom.secretKeyRef.name}{"\n"}{end}' 2>/dev/null)
  printf '%s\n' "$refs" | grep -qx "$secret" \
    || { echo "$dp/$ns: $COMP's Deployment takes no env from Secret $secret"; return 1; }
  echo "$env: PostgreSQL $xr Ready on $dp, $COMP reads Secret $secret (binding $rrb)"
}

# ---- main -----------------------------------------------------------------------------------------------------------
CLUSTERS=()
cluster_names() {
  km get clusters.cluster.x-k8s.io -n fleet -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}
read_lines CLUSTERS cluster_names
fetch_kubeconfigs

echo "Demo pre-flight (docs/demo.md): context $CTX, workload clusters: ${CLUSTERS[*]:-none}, org namespace $NS"
echo
row STEP CHECK RESULT DETAIL
row ---- ---------------------------------------------- ------------ ------

check 1 argo-apps "Argo CD apps Synced/Healthy" c_argo_apps

check 2 clusters "CAPI clusters Provisioned" c_clusters
check 2 dataplanes "OpenChoreo data planes connected" c_dataplanes
check 2 render-providers "cluster files render for other providers" c_render_providers

check 3 console "Backstage console responds" c_console
check 3 component-types "component types for self-service" c_component_types

check 4 cosign "latest image signed (cosign, pinned identity)" c_cosign
for c in ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
  check 4 "kyverno-$c" "Kyverno policies Ready ($c)" c_kyverno "$c"
done
check 4 admit-signed "signed image admitted (production, dry-run)" c_admit_signed
check 4 deny-unsigned "unsigned image denied (production, dry-run)" c_deny_unsigned
check 4 build-in-cluster "in-cluster build succeeded" c_build_in_cluster

while IFS= read -r env; do
  [[ -n "$env" ]] || continue
  check 5 "http-$env" "$COMP 200 in $env" c_http "$env"
done < <(env_names)
check 5 gate-runs "promotion-gate WorkflowRuns present" c_gate_runs
check 5 gate-latest "latest promotion gate passed" c_gate_latest
check 5 resilience-production "$COMP PDB/spread/priority in production" c_resilience

check 6 metrics-clusters "metrics from every workload cluster" c_metrics_clusters
check 6 metrics-app "$COMP metrics in observability plane" c_metrics_app

for c in mgmt ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
  check 7 "falco-$c" "Falco running ($c)" c_falco "$c"
done
check 7 falco-escalation "Falco escalation path on mgmt" c_falco_escalation
check 7 falco-cluster-name "cluster name in Falco events" c_falco_cluster_name

check 8 mesh-certs "OpenBao-issued mesh certificates" c_mesh_certs
for c in mgmt ${CLUSTERS[@]+"${CLUSTERS[@]}"}; do
  check 8 "secret-stores-$c" "ClusterSecretStores Ready ($c)" c_secret_stores "$c"
done
check 8 app-secret "$COMP reads $SECRET_ENV from OpenBao" c_app_secret

check 9 postgres "PostgreSQL claim API" c_postgres
check 9 db-claim "$COMP database claim Ready" c_db_claim

echo
echo "$N_PASS PASS, $N_FAIL FAIL, $N_PENDING PENDING"
(( N_FAIL == 0 ))
