#!/usr/bin/env bash
# Package a Helm chart and (optionally) push it to an OCI registry.
#
# Env in:
#   CHART_PATH     chart directory (required)
#   CHART_VERSION  version override; default: tag name without leading v when
#                  GIT_REF is refs/tags/v*, else Chart.yaml version
#   APP_VERSION    optional --app-version override
#   GIT_REF        e.g. refs/tags/v1.2.3 (GITHUB_REF)
#   OCI_REGISTRY   e.g. ghcr.io/koorikla/charts (push target, oci:// added)
#   PUSH           true/false, default false
#   CI_OUT_DIR     output dir, default ./.ci-out
# Outputs:
#   chart_name chart_version package (path to .tgz)
#   digest repo image_digest_ref (when pushed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_env CHART_PATH
require_cmd helm

out="$(out_dir)"
chart="${CHART_PATH}"
name="$(awk -F': *' '$1 == "name" {gsub(/["'\'']/, "", $2); print $2; exit}' "${chart}/Chart.yaml")"
[[ -n "${name}" ]] || die "cannot read chart name from ${chart}/Chart.yaml"

version="${CHART_VERSION:-}"
if [[ -z "${version}" ]]; then
  case "${GIT_REF:-}" in
    refs/tags/v[0-9]*) version="${GIT_REF#refs/tags/v}" ;;
  esac
fi

set -- package "${chart}" --destination "${out}"
[[ -z "${version}" ]] || set -- "$@" --version "${version}"
[[ -z "${APP_VERSION:-}" ]] || set -- "$@" --app-version "${APP_VERSION}"
log "helm $*"
pkg_line="$(helm "$@")"
pkg="${pkg_line##*: }"
[[ -f "${pkg}" ]] || die "helm package output not found: ${pkg_line}"
pkg_version="$(basename "${pkg}" .tgz)"
pkg_version="${pkg_version#"${name}"-}"

emit_output chart_name "${name}"
emit_output chart_version "${pkg_version}"
emit_output package "${pkg}"

if is_true "${PUSH:-false}"; then
  require_env OCI_REGISTRY
  reg="${OCI_REGISTRY#oci://}"
  log "helm push ${pkg} oci://${reg}"
  push_out="$(helm push "${pkg}" "oci://${reg}" 2>&1)"
  printf '%s\n' "${push_out}" >&2
  digest="$(printf '%s\n' "${push_out}" | awk '/^Digest:/ {print $2; exit}')"
  case "${digest}" in
    sha256:*) ;;
    *) die "could not parse digest from helm push output" ;;
  esac
  repo="${reg}/${name}"
  emit_output digest "${digest}"
  emit_output repo "${repo}"
  emit_output image_digest_ref "${repo}@${digest}"
  step_summary "- Pushed chart \`oci://${repo}:${pkg_version}\` (\`${digest}\`)"
fi
