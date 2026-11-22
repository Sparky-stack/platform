#!/usr/bin/env bash
# koorikla-build steps `check` and `check-with-postgres`: ci/scripts/<stack>/check.sh in the stack's official toolchain
# image, run from the copy check-init.sh put on the pod's /ci volume. Caches live on the run's volume (/work/.cache,
# set through the step's env).
#
# Env in:  STACK, APP_PATH, CHECK_SETUP (optional setup command, e.g. installing a system package), /ci/env.sh
#          (check-env), plus the stack check's own env
set -euo pipefail

# shellcheck source=/dev/null  # written by check-init.sh at run time
. /ci/env.sh
export WORKDIR="/work/source/${APP_PATH#./}"
cd "$WORKDIR"
if [ -n "$CHECK_SETUP" ]; then echo ">> setup: $CHECK_SETUP"; bash -euo pipefail -c "$CHECK_SETUP"; fi
echo ">> ci/scripts/${STACK}/check.sh"
bash "/ci/scripts/${STACK}/check.sh"
