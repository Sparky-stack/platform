#!/usr/bin/env bash
# koorikla-build init container `scripts` of the check steps (toolbox image). Toolchain images carry neither the
# ci/scripts nor jq, so this copies the scripts to the pod's /ci volume and turns check-env (a JSON object of the stack
# check's env flags, set by the tenant) into /ci/env.sh: one `export KEY='value'` per entry, values shell-quoted by jq
# (@sh), so a value is never run as code. check.sh sources it in the toolchain image.
#
# Env in:  CI_SCRIPTS (toolbox: /opt/koorikla-ci/scripts), CHECK_ENV
# Out:     /ci/scripts (a copy of ci/scripts), /ci/env.sh
set -euo pipefail

cp -R "$CI_SCRIPTS" /ci/scripts
printf '%s' "$CHECK_ENV" | jq -r 'to_entries[] | "export \(.key)=\(.value | tostring | @sh)"' > /ci/env.sh
