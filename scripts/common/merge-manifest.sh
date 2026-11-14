#!/usr/bin/env bash
# Merge per-platform image digests into one tagged manifest list (OCI index).
#
# Env in:
#   REPO         image repository, e.g. ghcr.io/koorikla/app (required)
#   DIGESTS_DIR  directory with one file per platform build; each file name is
#                a digest hex (sha256 without prefix) - docker/build-push
#                convention (required)
#   TAGS         newline- or space-separated full tag refs (required)
#   ANNOTATIONS  optional newline-separated index annotations (key=value)
# Outputs:
#   digest            sha256:... of the pushed index
#   image_digest_ref  REPO@sha256:...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_env REPO DIGESTS_DIR TAGS
require_cmd docker jq

sources=""
for f in "${DIGESTS_DIR}"/*; do
  [[ -f "$f" ]] || continue
  sources="${sources} ${REPO}@sha256:$(basename "$f")"
done
[[ -n "${sources}" ]] || die "no digests found in ${DIGESTS_DIR}"

tag_args=""
for t in ${TAGS}; do
  tag_args="${tag_args} -t ${t}"
done

ann_file="$(mktemp)"
printf '%s\n' "${ANNOTATIONS:-}" >"${ann_file}"
set --
while IFS= read -r a; do
  [[ -n "$a" ]] || continue
  # imagetools create only takes index-level annotations; drop the rest.
  case "$a" in
    index:*) set -- "$@" --annotation "$a" ;;
    manifest:* | manifest-descriptor:* | index-descriptor:*) ;;
    *) set -- "$@" --annotation "index:$a" ;;
  esac
done <"${ann_file}"
rm -f "${ann_file}"

log "imagetools create ${tag_args} ${sources}"
# shellcheck disable=SC2086
docker buildx imagetools create "$@" ${tag_args} ${sources}

first_tag=""
for t in ${TAGS}; do
  first_tag="$t"
  break
done
digest="$(docker buildx imagetools inspect "${first_tag}" --format '{{json .Manifest}}' | jq -r '.digest')"
case "${digest}" in
  sha256:*) ;;
  *) die "could not resolve index digest for ${first_tag}" ;;
esac

emit_output digest "${digest}"
emit_output image_digest_ref "${REPO}@${digest}"
step_summary "- Manifest list \`${REPO}@${digest}\`"
log "index ${REPO}@${digest}"
