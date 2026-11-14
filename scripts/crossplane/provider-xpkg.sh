#!/usr/bin/env bash
# Build one provider/function .xpkg per platform, each embedding that
# platform's controller image, ready for `xpkg push -f a.xpkg,b.xpkg` (which
# creates a multi-arch package index).
#
# Env in:
#   PACKAGE_ROOT      directory with crossplane.yaml + crds (required)
#   IMAGE_DIGEST_REF  controller image index, repo@sha256:... (empty = build a
#                     single package without an embedded runtime, e.g. on PRs)
#   PLATFORMS         comma list, default linux/amd64,linux/arm64
#   EXAMPLES_DIR      optional examples root relative to PACKAGE_ROOT
#   IGNORE            optional extra --ignore patterns
#   CI_OUT_DIR        output dir, default ./.ci-out
# Outputs:
#   package_files  comma list of built .xpkg files
# Requires: crossplane, crane (daemonless per-platform pull).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_env PACKAGE_ROOT
require_cmd crossplane

out="$(out_dir)"
files=""

if [[ -z "${IMAGE_DIGEST_REF:-}" ]]; then
  log "no runtime image: building package without embedded runtime"
  OUTPUT="${out}/package.xpkg" CI_OUT_DIR="${out}" bash "${SCRIPT_DIR}/xpkg-build.sh"
  emit_output package_files "${out}/package.xpkg"
  exit 0
fi

require_cmd crane
repo="${IMAGE_DIGEST_REF%@*}"
for p in $(csv_words "${PLATFORMS:-linux/amd64,linux/arm64}"); do
  slug="$(platform_slug "$p")"
  pdigest="$(crane digest --platform "$p" "${IMAGE_DIGEST_REF}")"
  tarball="${out}/runtime-${slug}.tar"
  log "pull ${repo}@${pdigest} (${p}) -> ${tarball}"
  crane pull --platform "$p" "${repo}@${pdigest}" "${tarball}"
  OUTPUT="${out}/package-${slug}.xpkg" EMBED_RUNTIME_TARBALL="${tarball}" CI_OUT_DIR="${out}" \
    bash "${SCRIPT_DIR}/xpkg-build.sh"
  rm -f "${tarball}"
  [[ -z "${files}" ]] || files="${files},"
  files="${files}${out}/package-${slug}.xpkg"
done

emit_output package_files "${files}"
