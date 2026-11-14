#!/usr/bin/env bash
# Go stack build/lint/test/vulncheck script.
# Contract:
#   Env in:
#     WORKDIR           (default: .)
#     RUN_LINT          (default: true)
#     RUN_VULNCHECK     (default: true)
#     GO_TEST_FLAGS     (default: -race -coverprofile=coverage.out -covermode=atomic ./...)
#   Files out:
#     ${WORKDIR}/coverage.out (when tests run with coverage)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

cd "${WORKDIR:-.}"

log "Running go vet"
go vet ./...

if [[ "${RUN_LINT:-true}" == "true" ]] && command -v golangci-lint >/dev/null 2>&1; then
  log "Running golangci-lint"
  golangci-lint run ./...
fi

log "Running go test -race with coverage"
# shellcheck disable=SC2086
go test ${GO_TEST_FLAGS:--race -coverprofile=coverage.out -covermode=atomic ./...}

if [[ "${RUN_VULNCHECK:-true}" == "true" ]]; then
  if ! command -v govulncheck >/dev/null 2>&1; then
    log "Installing govulncheck"
    go install golang.org/x/vuln/cmd/govulncheck@latest
    export PATH="$(go env GOPATH)/bin:${PATH}"
  fi
  log "Running govulncheck"
  govulncheck ./...
fi
