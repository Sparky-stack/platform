#!/usr/bin/env bash
# hack/tools.sh reads every mise.toml [tools] entry, including backend keys ("github:owner/repo") and inline tables
# ({ version = "x", bin = "y" }), as "<binary> <version>". A key it cannot parse would surface as MISSING in
# `task doctor` and the devcontainer post-create check on every OS.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/hack"
cp -R "$ROOT/hack/lib" "$ROOT/hack/tools.sh" "$tmp/hack/"
cat > "$tmp/mise.toml" <<'EOF'
[env]
FOO = "bar"

[tools]
# comment
kubectl = "1.35.10"   # trailing comment
"aqua:helm/helm" = "4.3.2"
"github:kyverno/kyverno" = { version = "1.20.0", bin = "kyverno" }
"github:owner/some-repo" = "0.1.0"
"github:owner/repo2" = { bin = "tool2", version = "2.0.0" }

[tasks.x]
run = "echo"
EOF
# bash 3.2 (macOS) cannot `source <(...)`: extract the function into a file instead.
sed -n '/^tools_table()/,/^}/p' "$ROOT/hack/tools.sh" > "$tmp/fn.sh"
table=$(cd "$tmp" && bash -c '. ./fn.sh; tools_table')
assert_eq "$(sed -n 1p <<<"$table")" "kubectl 1.35.10" "plain key"
assert_eq "$(sed -n 2p <<<"$table")" "helm 4.3.2" "backend key"
assert_eq "$(sed -n 3p <<<"$table")" "kyverno 1.20.0" "inline table bin"
assert_eq "$(sed -n 4p <<<"$table")" "some-repo 0.1.0" "backend repo basename"
assert_eq "$(sed -n 5p <<<"$table")" "tool2 2.0.0" "inline table any order"
assert_eq "$(wc -l <<<"$table" | tr -d ' ')" "5" "only [tools] entries"

# The real mise.toml: every entry parses to a bare binary name and a version.
real=$(cd "$ROOT" && FN="$tmp/fn.sh" bash -c '. "$FN"; tools_table')
bad=$(awk 'NF != 2 || $1 ~ /["{}:\/=]/ || $2 !~ /^[0-9][0-9A-Za-z.+-]*$/' <<<"$real")
assert_eq "$bad" "" "real mise.toml parses"

finish
