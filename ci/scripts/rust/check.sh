#!/usr/bin/env bash
# Rust checks: pinned toolchain (rust-toolchain.toml), cargo fmt --check,
# clippy -D warnings, tests (cargo-nextest when installed, else cargo test),
# cargo-deny (advisories, bans, licenses, sources) and cargo-audit.
#
# Env in:
#   WORKDIR        crate / workspace directory, default .
#   RUN_FMT        default true
#   RUN_CLIPPY     default true
#   CLIPPY_ARGS    default "--all-targets --all-features --locked -- -D warnings"
#   RUN_TEST       default true
#   TEST_RUNNER    auto | nextest | cargo, default auto (nextest when installed)
#   TEST_ARGS      extra test arguments (default --workspace --all-features --locked)
#   RUN_DENY       default true (cargo-deny; licenses only checked with a deny.toml)
#   RUN_AUDIT      default true (cargo-audit)
# Tools: cargo-deny and cargo-audit must be on PATH (cargo-nextest is used when
# present). Nothing is installed or compiled at run time: app-rust.yaml installs
# the prebuilt, checksummed binaries at the versions it pins.
# Files out: target/ (build cache)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd cargo
cd "${WORKDIR:-.}"
[[ -f Cargo.toml ]] || die "Cargo.toml not found in ${WORKDIR:-.}"
[[ -f Cargo.lock ]] || die "Cargo.lock not found in ${WORKDIR:-.}: commit it for binaries (--locked builds)"
export CARGO_TERM_COLOR="${CARGO_TERM_COLOR:-always}"

if [[ -f rust-toolchain.toml || -f rust-toolchain ]]; then
  if command -v rustup >/dev/null 2>&1; then
    # rustup >= 1.28 installs the toolchain (and its components) named by the file.
    log "rustup toolchain install (rust-toolchain.toml)"
    rustup toolchain install
  else
    warn "rust-toolchain.toml present but rustup missing; using $(cargo --version)"
  fi
else
  warn "no rust-toolchain.toml: the toolchain is not pinned"
fi
log "$(cargo --version); $(rustc --version)"

# require_tool BIN - fail unless BIN is on PATH (see "Tools" above).
require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    die "$1 not installed (install the prebuilt version pinned in .github/workflows/app-rust.yaml)"
}

if is_true "${RUN_FMT:-true}"; then
  log "cargo fmt --all --check"
  cargo fmt --all --check
fi

if is_true "${RUN_CLIPPY:-true}"; then
  # shellcheck disable=SC2086
  log "cargo clippy ${CLIPPY_ARGS:---all-targets --all-features --locked -- -D warnings}"
  # shellcheck disable=SC2086
  cargo clippy ${CLIPPY_ARGS:---all-targets --all-features --locked -- -D warnings}
fi

if is_true "${RUN_TEST:-true}"; then
  runner="${TEST_RUNNER:-auto}"
  if [[ "${runner}" == "auto" ]]; then
    if cargo nextest --version >/dev/null 2>&1; then runner=nextest; else runner=cargo; fi
  fi
  test_args="${TEST_ARGS:---workspace --all-features --locked}"
  case "${runner}" in
    nextest)
      log "cargo nextest run ${test_args}"
      # shellcheck disable=SC2086
      cargo nextest run ${test_args} --no-tests=warn
      # nextest does not run doctests; only library targets have them.
      meta="$(cargo metadata --no-deps --format-version 1 --locked)"
      case "${meta}" in
        *'"doctest":true'*)
          log "cargo test --doc"
          # shellcheck disable=SC2086
          cargo test --doc ${test_args}
          ;;
      esac
      ;;
    cargo)
      log "cargo test ${test_args}"
      # shellcheck disable=SC2086
      cargo test ${test_args}
      ;;
    *) die "unknown TEST_RUNNER ${runner}" ;;
  esac
fi

if is_true "${RUN_DENY:-true}"; then
  require_tool cargo-deny
  if [[ -f deny.toml || -f .cargo/deny.toml ]]; then
    log "cargo deny check (advisories bans licenses sources)"
    cargo deny --locked check
  else
    warn "no deny.toml: checking advisories, bans and sources only (add one to enforce licenses)"
    cargo deny --locked check advisories bans sources
  fi
fi

if is_true "${RUN_AUDIT:-true}"; then
  require_tool cargo-audit
  log "cargo audit"
  cargo audit
fi
