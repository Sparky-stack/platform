#!/bin/sh
# koorikla-build step `build`: rootless BuildKit (no Docker daemon, no DinD, not privileged; the step's securityContext
# explains the two relaxations). POSIX sh: the BuildKit image has neither bash nor jq. Builds every platform of
# PLATFORMS, pushes by digest with SLSA provenance (mode=min) and the registry build cache.
#
# Env in:  IMAGE_REPO, REGISTRY_HOST, SHORT_SHA, DOCKER_CONTEXT, DOCKERFILE_PATH, BUILD_ARGS (JSON
#          [{"name":..,"value":..}]), PLATFORMS, BUILD_CACHE, HOME
# Mounts:  /work (read-only run volume), /registry-auth, /registry-ca (optional), /buildkitd (optional mirrors)
# Out:     /tmp/digest-ref (<repo>@sha256:..), /tmp/image (<repo>:<short-sha>@sha256:..)
set -eu

mkdir -p "$HOME/.config/buildkit" "$HOME/.docker"
cp /registry-auth/config.json "$HOME/.docker/config.json"
cfg="$HOME/.config/buildkit/buildkitd.toml"
: > "$cfg"
if [ -f /registry-ca/ca.crt ]; then
  # Base images through the Harbor proxy caches (ConfigMap buildkitd-config, addon openchoreo-workflow-plane
  # values buildkitMirrors, #38): registry mirrors that need the Harbor CA, so only together with it.
  if [ -f /buildkitd/buildkitd.toml ]; then
    cat /buildkitd/buildkitd.toml > "$cfg"
    echo ">> registry mirrors (BuildKit falls back to the upstream when a mirror fails):"
    awk -F'"' '/^\[registry\./ { h = $2 } /^ *mirrors = / { print "   " h " -> " $2 }' "$cfg"
  fi
  grep -qF "[registry.\"$REGISTRY_HOST\"]" "$cfg" || printf '[registry."%s"]\n  ca = ["/registry-ca/ca.crt"]\n' "$REGISTRY_HOST" >> "$cfg"
  # buildkitd.toml covers buildkitd's registry requests only: buildctl fetches the registry's bearer token
  # itself (session auth provider) with Go's system roots, so it must trust the CA too ("failed to fetch
  # oauth token: ... x509: certificate signed by unknown authority" otherwise).
  cat /etc/ssl/certs/ca-certificates.crt /registry-ca/ca.crt > "$HOME/ca.pem"
  export SSL_CERT_FILE="$HOME/ca.pem"
fi
ctx="/work/source/${DOCKER_CONTEXT#./}"
df="/work/source/${DOCKERFILE_PATH#./}"
[ -f "$df" ] || { echo ">> Dockerfile not found: $DOCKERFILE_PATH"; exit 1; }
# The context and Dockerfile must resolve inside the checkout: this pod also mounts the registry push
# credentials, which a ../ or a symlinked context root would otherwise hand to COPY.
for p in "$ctx" "$(dirname "$df")"; do
  case "$(realpath "$p")/" in /work/source/*) ;; *) echo ">> $p resolves outside the repository"; exit 1 ;; esac
done
set -- --opt "build-arg:VERSION=$SHORT_SHA"
# build-args: JSON [{"name":..,"value":..}] -> --opt build-arg:NAME=VALUE (no jq in this image). The last entry has no
# trailing newline (sed keeps the input's missing one): `|| [ -n "$a" ]` reads it too.
printf '%s' "$BUILD_ARGS" | tr -d '\n' | sed -e 's/^\[//' -e 's/\]$//' -e 's/},[[:space:]]*{/}\n{/g' > /tmp/args
while IFS= read -r a || [ -n "$a" ]; do
  [ -n "$a" ] || continue
  n=$(printf '%s' "$a" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  v=$(printf '%s' "$a" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$n" ] && set -- "$@" --opt "build-arg:$n=$v"
done < /tmp/args
if [ "$BUILD_CACHE" = true ]; then
  set -- "$@" --export-cache "type=registry,ref=$IMAGE_REPO:buildcache,mode=max,image-manifest=true,oci-mediatypes=true" \
              --import-cache "type=registry,ref=$IMAGE_REPO:buildcache"
fi
echo ">> building $IMAGE_REPO:$SHORT_SHA for $PLATFORMS"
buildctl-daemonless.sh build \
  --frontend dockerfile.v0 \
  --local context="$ctx" \
  --local dockerfile="$(dirname "$df")" \
  --opt filename="$(basename "$df")" \
  --opt platform="$PLATFORMS" \
  --opt attest:provenance=mode=min \
  "$@" \
  --output "type=image,name=$IMAGE_REPO:$SHORT_SHA,push=true,oci-mediatypes=true" \
  --metadata-file /tmp/metadata.json
digest=$(sed -n 's/.*"containerimage.digest"[[:space:]]*:[[:space:]]*"\(sha256:[0-9a-f]*\)".*/\1/p' /tmp/metadata.json | head -1)
[ -n "$digest" ] || { echo ">> no digest in build metadata"; cat /tmp/metadata.json; exit 1; }
printf '%s@%s' "$IMAGE_REPO" "$digest" > /tmp/digest-ref
printf '%s:%s@%s' "$IMAGE_REPO" "$SHORT_SHA" "$digest" > /tmp/image
echo ">> pushed $(cat /tmp/image)"
