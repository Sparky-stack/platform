#!/usr/bin/env bash
# Every Chart.lock matches its Chart.yaml (helm's digest, hack/lib/chartlock.py), so `helm dependency build` works on
# a clean checkout and in Argo CD's repo-server even when the local charts/ cache would hide a stale lock.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$ROOT/hack/lib/portable.sh"

cd "$ROOT"
dirs=()
for d in charts/* addons/*; do
  if [[ -f "$d/Chart.yaml" ]] && grep -q '^dependencies:' "$d/Chart.yaml"; then dirs+=("$d"); fi
done
out=$(py hack/lib/chartlock.py "${dirs[@]}" 2>&1) && rc=0 || rc=$?
assert_eq "$rc:$out" "0:" "every Chart.lock in sync with its Chart.yaml (${#dirs[@]} charts)"

# Negative: a Chart.yaml edit after the lock (the PR #5 regression: a condition added) is caught, and so is a missing
# lock; restoring the field brings it back in sync.
mk() { rm -rf "$TMP/c"; mkdir -p "$TMP/c"; cp addons/external-dns/Chart.yaml addons/external-dns/Chart.lock "$TMP/c/"; }
mk; yq -i 'del(.dependencies[0].condition)' "$TMP/c/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'out of sync' "dropping a dependency condition is detected"
mk; yq -i '.dependencies[0].version = "0.0.1"' "$TMP/c/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'out of sync' "a version bump without a lock update is detected"
mk; rm "$TMP/c/Chart.lock"
assert_match "$(py hack/lib/chartlock.py "$TMP/c" || true)" 'without a Chart.lock' "a missing lock is detected"
mk
assert_eq "$(py hack/lib/chartlock.py "$TMP/c"; echo $?)" "0" "unchanged copy stays in sync"
# Behaviour, not text: deps.sh on a scratch tree with one stale lock and a warm charts/ cache exits 1 before any
# network call (repo registration and builds come after the lock check).
rm -rf "$TMP/tree"; mkdir -p "$TMP/tree/hack/lib" "$TMP/tree/addons" "$TMP/tree/charts"
cp hack/deps.sh "$TMP/tree/hack/"; cp hack/lib/portable.sh hack/lib/chartlock.py "$TMP/tree/hack/lib/"
cp -R addons/external-dns "$TMP/tree/addons/"; mkdir -p "$TMP/tree/addons/external-dns/charts"
yq -i 'del(.dependencies[0].condition)' "$TMP/tree/addons/external-dns/Chart.yaml"
# A no-op helm on PATH: if deps.sh skipped the check it would "succeed" offline instead of failing.
mkdir -p "$TMP/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/helm"; chmod +x "$TMP/bin/helm"
out=$(PATH="$TMP/bin:$PATH" bash "$TMP/tree/hack/deps.sh" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "deps.sh fails on a stale lock even with a warm charts/ cache"
assert_match "$out" 'deps: Chart.lock out of sync' "deps.sh names the stale lock"

# Pinned dependency digests (Chart.yaml annotation platform.koorikla.io/dependency-digests, checked by
# `chartlock.py --tarballs`): the mesh addon's Istio charts come from OCI and are pinned by tarball sha256.
pinned=$(yq '.annotations["platform.koorikla.io/dependency-digests"] // ""' addons/mesh/Chart.yaml)
assert_match "$pinned" 'base-1\.32\.0\.tgz sha256:[0-9a-f]{64}' "mesh pins its dependency tarballs by digest"
assert_eq "$(yq '[.dependencies[] | select(.name != "cert-manager-istio-csr") | .repository] | unique | join(",")' addons/mesh/Chart.yaml)" \
  "oci://ghcr.io/istio/release/charts" "mesh pulls upstream's OCI Istio charts"
retired=$(grep -lE 'istio-release\.storage\.googleapis\.com|gcr\.io/istio-release|registry\.istio\.io' \
  charts/*/Chart.yaml charts/*/Chart.lock addons/*/Chart.yaml addons/*/Chart.lock 2>/dev/null || true)
assert_eq "$retired" "" "no chart uses an Istio source retired on 2026-12-16"
out=$(py hack/lib/chartlock.py --tarballs "${dirs[@]}" 2>&1) && rc=0 || rc=$?
assert_eq "$rc:$out" "0:" "every vendored tarball matches its pinned digest"

# Scratch pinned chart: the mesh addon's Chart.yaml/lock (valid lock digest; annotations are not part of it) with pins
# of dummy tarballs, so the checks below need neither network nor the real charts.
pin_chart() { # pin_chart <dir>: fresh scratch chart in <dir> with genuine dummy tarballs in <dir>/charts
  rm -rf "$1"; mkdir -p "$1/charts"; cp addons/mesh/Chart.yaml addons/mesh/Chart.lock "$1/"
  local lines="" t
  for t in base-1.32.0 istiod-1.32.0 cni-1.32.0 ztunnel-1.32.0 cert-manager-istio-csr-v0.19.1; do
    printf 'genuine %s\n' "$t" > "$1/charts/$t.tgz"
    lines+="$t.tgz sha256:$(sha256_file "$1/charts/$t.tgz")"$'\n'
  done
  PINS="$lines" yq -i '.annotations["platform.koorikla.io/dependency-digests"] = strenv(PINS)' "$1/Chart.yaml"
}
pin_chart "$TMP/p"
assert_eq "$(py hack/lib/chartlock.py --tarballs "$TMP/p"; echo $?)" "0" "genuine pinned tarballs pass"
assert_eq "$(py hack/lib/chartlock.py "$TMP/p"; echo $?)" "0" "pins do not touch the Chart.lock digest"
printf 'tampered\n' > "$TMP/p/charts/cni-1.32.0.tgz"
assert_match "$(py hack/lib/chartlock.py --tarballs "$TMP/p" || true)" \
  'charts/cni-1\.32\.0\.tgz is sha256:[0-9a-f]+, pinned' "a tarball with other bytes is detected"
pin_chart "$TMP/p"
yq -i '.annotations["platform.koorikla.io/dependency-digests"] |= sub("ztunnel-1.32.0.tgz [^\n]*\n"; "")' \
  "$TMP/p/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py --tarballs "$TMP/p" || true)" 'ztunnel-1\.32\.0\.tgz has no pinned digest' \
  "a locked dependency without a pin is detected (e.g. a version bump without new digests)"
pin_chart "$TMP/p"
yq -i '.annotations["platform.koorikla.io/dependency-digests"] += "old-1.0.0.tgz sha256:00\n"' "$TMP/p/Chart.yaml"
assert_match "$(py hack/lib/chartlock.py --tarballs "$TMP/p" || true)" \
  'pinned digest for old-1\.0\.0\.tgz matches no Chart\.lock' "a pin without a locked dependency is detected"

# deps.sh behaviour with a logging fake helm on a scratch tree:
# - repositories are registered in a throwaway repository config, never the user's: a stale registration there (Istio's
#   retired GCS bucket answered 403 during upstream's scream tests) is neither refreshed nor loaded.
# - a cached tarball that differs from its pin is rebuilt; a download that still differs fails.
rm -rf "$TMP/t2"; mkdir -p "$TMP/t2/hack/lib" "$TMP/t2/addons" "$TMP/t2/charts" "$TMP/fake"
cp hack/deps.sh "$TMP/t2/hack/"; cp hack/lib/portable.sh hack/lib/chartlock.py "$TMP/t2/hack/lib/"
cp -R addons/external-dns "$TMP/t2/addons/"; rm -rf "$TMP/t2/addons/external-dns/charts"
pin_chart "$TMP/t2/addons/mesh"; cp "$TMP/t2/addons/mesh/charts/"* "$TMP/fake/"
printf 'tampered\n' > "$TMP/t2/addons/mesh/charts/base-1.32.0.tgz"
export FAKE_SRC="$TMP/fake" FAKE_LOG="$TMP/helm.log"
edns_url=$(yq '.dependencies[0].repository' addons/external-dns/Chart.yaml)
printf 'repositories:\n- name: stale-istio\n  url: https://istio-release.storage.googleapis.com/charts\n' > "$TMP/user-repos.yaml"
cat > "$TMP/bin/helm" <<'FAKE'
#!/usr/bin/env bash
echo "$* [repos=$HELM_REPOSITORY_CONFIG]" >> "$FAKE_LOG"
case "$1 $2" in
  "dependency build")
    d=$4; mkdir -p "$d/charts"
    if [[ $d == *mesh ]]; then cp "$FAKE_SRC/"* "$d/charts/"
    else for t in $(yq -r '.dependencies[] | .name + "-" + .version + ".tgz"' "$d/Chart.lock"); do : > "$d/charts/$t"; done
    fi ;;
esac
FAKE
chmod +x "$TMP/bin/helm"; : > "$FAKE_LOG"
out=$(HELM_REPOSITORY_CONFIG="$TMP/user-repos.yaml" PATH="$TMP/bin:$PATH" bash "$TMP/t2/hack/deps.sh" 2>&1) \
  && rc=0 || rc=$?
log=$(cat "$FAKE_LOG")
assert_eq "$rc" "0" "deps.sh builds with a stale repository in the user's helm config ($out)"
assert_match "$log" "(^|"$'\n'")repo add r[0-9a-f]{10} $edns_url --force-update " "deps.sh registers the needed repository"
assert_eq "$(grep -c -e 'user-repos.yaml' -e '^repo update' "$FAKE_LOG" || true)" "0" \
  "helm never sees the user's repository config, and no repo update refreshes everything"
assert_match "$log" 'dependency build --skip-refresh addons/mesh' "a tampered cached tarball is rebuilt"
assert_eq "$(py hack/lib/chartlock.py --tarballs "$TMP/t2/addons/mesh"; echo $?)" "0" \
  "rebuilt tarballs match their pins"
printf 'tampered\n' > "$TMP/fake/cni-1.32.0.tgz"; rm -rf "$TMP/t2/addons/mesh/charts"
out=$(PATH="$TMP/bin:$PATH" bash "$TMP/t2/hack/deps.sh" 2>&1) && rc=0 || rc=$?; echo "DBG $out" >&2; ls "$TMP/t2/addons/mesh/charts" >&2
assert_eq "$rc" "1" "deps.sh fails when a download differs from its pin"
assert_match "$out" 'differ from their pinned digests' "deps.sh names the digest mismatch"

finish
