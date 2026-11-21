#!/usr/bin/env bash
# Immutable fields vs Argo CD server-side diff (#281). Argo CD diffs server-side (controller.diff.server.side): every
# compare runs a server-side-apply DRY RUN of each object. A git change to an immutable field fails that dry run, the
# whole Application goes ComparisonError/Unknown and no sync ever starts - so a per-resource
# `argocd.argoproj.io/sync-options: Force=true,Replace=true` alone never runs (#279 -> #281). Argo CD 3.6 has no
# per-resource compare option (controller/state.go shouldUseServerSideDiff reads the Application only). Contract, for
# every addon render (hack/test.sh RENDERED_DIR, else standalone renders made here):
#   1. a PriorityClass/StorageClass (whole spec immutable, nothing references its uid) carries sync-options
#      Force=true,Replace=true (kubectl replace --force = delete + create on change);
#   2. ... and its addon sets compareOptions ServerSideDiff=false (charts/platform values.yaml), so the client-side diff
#      reports OutOfSync and that sync option actually runs;
#   3. an addon with ServerSideDiff=false renders ONLY those kinds (server-side diff stays on everywhere else);
#   4. a Job is an Argo CD/Helm hook (deleted and recreated per sync, never diffed) or is allowlisted below because its
#      name carries a checksum of its spec (rename on change: a new name is a create, never an in-place update);
#   5. no PersistentVolumeClaim carries Replace=true or Force=true (replace deletes the volume's data).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

REPLACE_KINDS='PriorityClass|StorageClass'
# addon<TAB>Job name regex<TAB>reason (rule 4)
JOB_ALLOW=$'cilium\t^hubble-generate-certs-[0-9a-f]{10}$\tupstream names the Job hubble-generate-certs-<sha256(spec)[:10]>'

render_platform local "$TMP/platform.yaml"
yq -r 'select(.kind == "ApplicationSet" and (.metadata.name | test("^addon-"))) | [(.metadata.name | sub("^addon-"; "")),
  (.spec.template.metadata.annotations["argocd.argoproj.io/compare-options"] // "")] | @tsv' "$TMP/platform.yaml" > "$TMP/opts"
opts_of() { awk -F'\t' -v a="$1" '$1 == a { print $2 }' "$TMP/opts"; }

# violations <addon> <render> <compare-options> -> one line per broken rule
violations() {
  local addon=$1 f=$2 opts=",$3," kind name sync hook re reason
  local ssd=on; [[ "$opts" == *",ServerSideDiff=false,"* ]] && ssd=off
  # shellcheck disable=SC2016  # yq variables, not shell
  while IFS=$'\t' read -r kind name sync hook; do
    [[ -n "$kind" ]] || continue
    sync=",$sync,"
    if [[ "$kind" =~ ^($REPLACE_KINDS)$ ]]; then
      [[ "$sync" == *",Force=true,"* && "$sync" == *",Replace=true,"* ]] ||
        echo "$addon: $kind/$name has immutable fields: annotate argocd.argoproj.io/sync-options: Force=true,Replace=true"
      [[ $ssd == off ]] ||
        echo "$addon: renders $kind/$name but server-side diff is on: its immutable-field change fails the dry run and Force/Replace never runs (compareOptions ServerSideDiff=false, only for addons rendering $REPLACE_KINDS)"
    elif [[ $ssd == off ]]; then
      echo "$addon: ServerSideDiff=false but renders $kind/$name: only $REPLACE_KINDS may live in a client-side-diff addon"
    fi
    if [[ "$kind" == Job && "$hook" == no ]]; then
      reason=""
      while IFS=$'\t' read -r a re r; do [[ "$a" == "$addon" && "$name" =~ $re ]] && reason=$r; done <<< "$JOB_ALLOW"
      [[ -n "$reason" ]] ||
        echo "$addon: Job/$name is a normal resource: its spec.template is immutable (make it a hook with BeforeHookCreation, or name it with a checksum of its spec and allowlist it here)"
    fi
    if [[ "$kind" == PersistentVolumeClaim && ( "$sync" == *",Replace=true,"* || "$sync" == *",Force=true,"* ) ]]; then
      echo "$addon: PersistentVolumeClaim/$name must never be replaced (data loss): drop Replace/Force"
    fi
  done < <(yq -N 'select(.kind != null) | (.metadata.annotations // {}) as $a
    | ($a["argocd.argoproj.io/hook"] // "") as $ah | ($a["helm.sh/hook"] // "") as $hh
    | [.kind, .metadata.name, ($a["argocd.argoproj.io/sync-options"] // ""),
       (if (($ah != "" and $ah != "Skip") or ($ah == "" and $hh != "" and $hh != "crd-install" and ($hh | test("^test") | not)))
        then "yes" else "no" end)] | join("	")' "$f" | tr -d '\r')
}

# addon_of <render file name>: the longest addon name the file name starts with
addon_of() {
  local base best="" a
  base=$(basename "$1" .yaml); base=${base#addon-}
  for a in addons/*/; do a=$(basename "$a"); [[ "$base" == "$a"-* && ${#a} -gt ${#best} ]] && best=$a; done
  echo "$best"
}

n=0
if [[ -n "${RENDERED_DIR:-}" && -d "${RENDERED_DIR:-}" ]]; then
  for r in "$RENDERED_DIR"/addon-*.yaml; do
    [[ -f "$r" ]] || continue
    a=$(addon_of "$r"); [[ -n "$a" ]] || continue
    n=$((n + 1))
    assert_eq "$(violations "$a" "$r" "$(opts_of "$a")")" "" "$(basename "$r" .yaml): immutable fields cannot deadlock the sync"
  done
else
  for d in addons/*/; do
    a=$(basename "$d")
    render_standalone_addon "$a" "$TMP/addon-$a.yaml" 2>/dev/null || { echo "  (skip $a: no standalone render)"; continue; }
    n=$((n + 1))
    assert_eq "$(violations "$a" "$TMP/addon-$a.yaml" "$(opts_of "$a")")" "" "addons/$a (standalone): immutable fields cannot deadlock the sync"
  done
fi
echo "  checked $n addon renders"

# Self-check: the platform still renders the PriorityClasses (a moved template must not silently empty this test).
render_standalone_addon priority-classes "$TMP/pc.yaml"
assert_eq "$(yq -N 'select(.kind == "PriorityClass") | .metadata.name' "$TMP/pc.yaml" | sort | tr '\n' ' ')" \
  "app-production app-standard " "addon priority-classes renders the app PriorityClasses"

# Negatives: each way back to #281 is caught.
neg() { # neg <label> <addon> <compare-options> <yq edit of the priority-classes render> <expected violation regex>
  yq "$4" "$TMP/pc.yaml" > "$TMP/neg.yaml"
  assert_match "$(violations "$2" "$TMP/neg.yaml" "$3")" "$5" "negative: $1"
}
neg "PriorityClass in a server-side-diff addon (#281)" openchoreo-data-plane "" '.' \
  'renders PriorityClass/app-production but server-side diff is on'
neg "sync option dropped" priority-classes ServerSideDiff=false 'del(.metadata.annotations)' \
  'PriorityClass/app-standard has immutable fields'
neg "Replace without Force (kubectl replace also rejects immutable fields)" priority-classes ServerSideDiff=false \
  '.metadata.annotations["argocd.argoproj.io/sync-options"] = "Replace=true"' 'PriorityClass/app-production has immutable fields'
neg "a Deployment in the client-side-diff addon" priority-classes ServerSideDiff=false \
  '(select(.metadata.name == "app-standard") | .kind) = "Deployment"' 'only PriorityClass|StorageClass may live'
neg "a non-hook Job" priority-classes ServerSideDiff=false \
  '(select(.metadata.name == "app-standard") | .kind) = "Job"' 'Job/app-standard is a normal resource'
neg "a hash-named Job outside its addon" priority-classes ServerSideDiff=false \
  '(select(.metadata.name == "app-standard") | .kind) = "Job" | (select(.kind == "Job") | .metadata.name) = "hubble-generate-certs-0123456789"' \
  'Job/hubble-generate-certs-0123456789 is a normal resource'
neg "a replaced PVC" priority-classes ServerSideDiff=false \
  '(select(.metadata.name == "app-standard") | .kind) = "PersistentVolumeClaim"' 'PersistentVolumeClaim/app-standard must never be replaced'
yq '(.kind = "Job") | .metadata.annotations = {"argocd.argoproj.io/hook": "Sync"}' "$TMP/pc.yaml" > "$TMP/hook.yaml"
assert_eq "$(violations openbao "$TMP/hook.yaml" "")" "" "a hook Job passes"

finish
