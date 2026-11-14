#!/usr/bin/env bash
# Install a pinned Crossplane CLI (`crossplane`) for Linux/macOS, amd64/arm64.
#
# Env in:
#   CROSSPLANE_VERSION  CLI version, default v2.5.0 (crossplane/cli releases)
#   CROSSPLANE_CHANNEL  default stable
#   INSTALL_DIR         default ${RUNNER_TEMP:-$HOME/.local}/bin
# Outputs:
#   crossplane  absolute path of the installed binary (also added to
#               GITHUB_PATH when running in GitHub Actions)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd curl uname

version="${CROSSPLANE_VERSION:-v2.5.0}"
channel="${CROSSPLANE_CHANNEL:-stable}"
dir="${INSTALL_DIR:-${RUNNER_TEMP:-${HOME}/.local}/bin}"
mkdir -p "${dir}"

case "$(uname -s)" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) die "unsupported OS $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

if [[ -x "${dir}/crossplane" ]] && "${dir}/crossplane" version --client 2>/dev/null | grep -q "${version}"; then
  log "crossplane ${version} already installed in ${dir}"
else
  url="https://cli.crossplane.io/${channel}/${version}/bin/${os}_${arch}/crossplane"
  log "downloading ${url}"
  curl -fsSL --retry 3 -o "${dir}/crossplane.tmp" "${url}"
  chmod +x "${dir}/crossplane.tmp"
  mv "${dir}/crossplane.tmp" "${dir}/crossplane"
fi

"${dir}/crossplane" version --client >&2
if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${dir}" >>"${GITHUB_PATH}"
fi
emit_output crossplane "${dir}/crossplane"
