#!/usr/bin/env bash
# Go checks: go vet, golangci-lint (optional), go test -race + coverage,
# govulncheck.
#
# Env in:
#   WORKDIR        module directory, default .
#   RUN_LINT       true/false, default true (skipped when golangci-lint missing)
#   RUN_VULNCHECK  true/false, default true (installs govulncheck if missing)
#   GO_TEST_FLAGS  default: -race -coverprofile=coverage.out -covermode=atomic ./...
# Files out:
#   $WORKDIR/coverage.out
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_cmd go
cd "${WORKDIR:-.}"

log "go vet ./..."
go vet ./...

if is_true "${RUN_LINT:-true}"; then
  if command -v golangci-lint >/dev/null 2>&1; then
    log "golangci-lint run ./..."
    golangci-lint run ./...
  else
    warn "golangci-lint not installed; skipping lint"
  fi
fi

log "go test ${GO_TEST_FLAGS:--race -coverprofile=coverage.out -covermode=atomic ./...}"
# shellcheck disable=SC2086
go test ${GO_TEST_FLAGS:--race -coverprofile=coverage.out -covermode=atomic ./...}
if [[ -f coverage.out ]]; then
  total="$(go tool cover -func=coverage.out | awk '/^total:/ {print $NF}')"
  log "coverage: ${total}"
  step_summary "- Go coverage (\`${WORKDIR:-.}\`): ${total}"
fi

if is_true "${RUN_VULNCHECK:-true}"; then
  if ! command -v govulncheck >/dev/null 2>&1; then
    log "installing govulncheck"
    go install golang.org/x/vuln/cmd/govulncheck@latest
    PATH="$(go env GOPATH)/bin:${PATH}"
    export PATH
  fi
  log "govulncheck ./..."
  govulncheck ./...
fi
