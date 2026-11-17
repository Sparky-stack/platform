#!/usr/bin/env bash
# Thunder's setup Job (PreSync hook, addon thunder) imports every *.yaml/*.yml/*.json below /opt/thunderid/bootstrap as
# ONE multi-document stream: ThunderID 1.0.1 internal/system/bootstrap/orchestrator.go loadBundle walks the directory
# recursively and joins the files with "\n---\n"; internal/system/importer/parser.go then fails the WHOLE import when a
# document's root is not a mapping or has no resource_type. An empty or comment-only file is such a document. That is
# what broke thunder-setup after PR #5 (comment-only placeholders for unlisted AI agents: "document 35 root must be a
# YAML mapping"), and a failed setup hook makes Argo CD delete the hook-failed PVCs. So: rebuild the platform part of
# the bundle exactly as the Job mounts it, for agents off / one / both and every installation render, and parse it
# the way Thunder does. The image's own 01/02 files are upstream's.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

echo "== test_thunder_bootstrap =="
cd "$ROOT"

# files <render> <out dir> -> the files the setup Job sees below /opt/thunderid/bootstrap, rebuilt from its volumeMounts
# and ConfigMap volumes the way the kubelet projects them: `items` (else every key at its own name), a subPath selects
# one file or one directory of the volume, a key missing from the ConfigMap is no file (optional item skipped; a
# subPath of a missing key is an empty directory). Any other volume type mounted there fails the test.
JOB='select(.kind == "Job" and .metadata.name == "thunder-setup") | .spec.template.spec'
files() {
  local render=$1 out=$2 sub="$TMP/th-sub.yaml" vol mp sp rel cm entries path key dest
  rm -rf "$out"; mkdir -p "$out"
  yq 'select((.kind == "Job" and .metadata.name == "thunder-setup") or .kind == "ConfigMap")' "$render" > "$sub"
  while IFS=$'\t' read -r vol mp sp; do
    case "$mp" in /opt/thunderid/bootstrap | /opt/thunderid/bootstrap/*) ;; *) continue ;; esac
    rel=${mp#/opt/thunderid/bootstrap}; rel=${rel#/}
    cm=$(V="$vol" yq -N "$JOB"' | .volumes[] | select(.name == strenv(V)) | .configMap.name // ""' "$sub" | tr -d '\r')
    if [[ -z "$cm" ]]; then
      assert_eq "volume $vol" "a ConfigMap volume" "only ConfigMap volumes are mounted into the bootstrap directory"
      continue
    fi
    entries=$(V="$vol" yq -N "$JOB"' | .volumes[] | select(.name == strenv(V)) | .configMap.items // [] | .[] | .path + "\t" + .key' "$sub" | tr -d '\r')
    if [[ -z "$entries" ]]; then
      entries=$(C="$cm" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(C)) | .data | keys | .[] | . + "\t" + .' "$sub" | tr -d '\r')
    fi
    while IFS=$'\t' read -r path key; do
      [[ -n "$path" ]] || continue
      if [[ -z "$sp" ]]; then dest="$rel/$path"
      elif [[ "$path" == "$sp" ]]; then dest="$rel"
      elif [[ "$path" == "$sp/"* ]]; then dest="$rel/${path#"$sp"/}"
      else continue; fi
      dest=${dest#/}
      [[ "$(C="$cm" K="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(C)) | .data | has(strenv(K))' "$sub" | tr -d '\r')" == true ]] || continue
      mkdir -p "$out/$(dirname "$dest")"
      C="$cm" K="$key" yq -N 'select(.kind == "ConfigMap" and .metadata.name == strenv(C)) | .data[strenv(K)]' "$sub" > "$out/$dest"
    done <<< "$entries"
  done < <(yq -N "$JOB"' | .containers[0].volumeMounts[] | .name + "\t" + .mountPath + "\t" + (.subPath // "")' "$sub" | tr -d '\r')
}

# bundle <dir> -> loadBundle: every *.yaml/*.yml/*.json (recursive, sorted), joined with "\n---\n"
bundle() {
  local f first=1
  while IFS= read -r f; do
    if (( first )); then first=0; else printf '\n---\n'; fi
    cat "$f"
  done < <(find "$1" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | LC_ALL=C sort)
}

# check <render> <label>: every document a mapping with resource_type; prints the offending document numbers
check() {
  local render=$1 label=$2 tags bad docs
  files "$render" "$TMP/b"
  bundle "$TMP/b" > "$TMP/bundle.yaml"
  docs=$(yq -N 'tag' "$TMP/bundle.yaml" | tr -d '\r')
  bad=$(printf '%s\n' "$docs" | awk '$0 != "!!map" { printf "%s%d(%s)", sep, NR, $0; sep=" " }')
  assert_eq "$bad" "" "$label: every Thunder bootstrap document is a YAML mapping"
  tags=$(yq -N 'select(tag == "!!map") | has("resource_type")' "$TMP/bundle.yaml" | tr -d '\r' | sort -u | tr '\n' ' ')
  assert_eq "$tags" "true " "$label: every Thunder bootstrap document has a resource_type"
  assert_match "$(printf '%s\n' "$docs" | wc -l | tr -d ' ')" '^[1-9][0-9]*$' "$label: the bundle is not empty"
}

render_standalone_addon thunder "$TMP/th-default.yaml"
check "$TMP/th-default.yaml" "agents [] (default)"
for agents in "rca" "finops" "rca,finops"; do
  helm template thunder addons/thunder --namespace thunder --set "bootstrapSecret.aiAgentClients={$agents}" > "$TMP/th.yaml"
  check "$TMP/th.yaml" "agents [$agents]"
done
# The renders hack/test.sh made per installation (overlays may add bootstrap scripts).
if [[ -n "${RENDERED_DIR:-}" && -d "${RENDERED_DIR:-}" ]]; then
  for r in "$RENDERED_DIR"/addon-thunder-*.yaml; do
    [[ -f "$r" ]] || continue
    check "$r" "$(basename "$r" .yaml)"
  done
fi

# Negative (mutation): the PR #5 placeholders - a comment-only and an empty file - are caught.
files "$TMP/th-default.yaml" "$TMP/neg"
assert_eq "$(cd "$TMP/neg" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" "./48-csp.yaml ./49-cors.yaml ./50-user-schema-and-users.yaml ./51-backstage-app.yaml ./54-cli-app.yaml ./59-openchoreo-observer-app.yaml ./70-openchoreo-promotion-gate-app.yaml ./ai-agent-clients/README " "agents off: the Job sees the platform scripts and the README, no agent file"
mkdir -p "$TMP/neg/ai-agent-clients"
printf '# rca agent client off\n' > "$TMP/neg/ai-agent-clients/53-rca-agent-client.yaml"
: > "$TMP/neg/ai-agent-clients/60-finops-agent-client.yaml"
bundle "$TMP/neg" > "$TMP/neg.yaml"
assert_match "$(yq -N 'tag' "$TMP/neg.yaml" | grep -vx '!!map' | sort -u | tr -d '\r')" '^!!null$' "comment-only and empty bootstrap files are detected as non-mapping documents"
# ... and a document without resource_type.
printf 'name: no-type\n' > "$TMP/neg/ai-agent-clients/53-rca-agent-client.yaml"; rm "$TMP/neg/ai-agent-clients/60-finops-agent-client.yaml"
bundle "$TMP/neg" > "$TMP/neg.yaml"
assert_match "$(yq -N 'select(tag == "!!map") | has("resource_type")' "$TMP/neg.yaml" | sort -u | tr '\n' ' ')" 'false' "a document without resource_type is detected"
# The README the agent directory always carries is not part of the bundle (not *.yaml).
assert_eq "$(find "$TMP/neg" -name README | wc -l | tr -d ' ')" 1 "README projected into the agent directory"
assert_eq "$(bundle "$TMP/neg" | grep -c 'OAuth clients of the OpenChoreo AI agents' || true)" 0 "README is not read as a bootstrap document"

finish
