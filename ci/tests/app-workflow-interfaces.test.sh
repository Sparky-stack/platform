#!/usr/bin/env bash
# Keeps the image phase of every app-<stack>.yaml in step with app-container.yaml.
# GitHub Actions cannot share `on.workflow_call` declarations between files, so each stack workflow repeats the
# image inputs, the registry secrets and the image outputs and passes them to its `container` job
# (app-container.yaml, the Kyverno-trusted signer). This test fails when a copy drifts:
#   - image inputs (the stack's inputs that app-container.yaml also declares, plus build_container) have the same
#     type and default in every stack and are all wired into the container job
#   - secrets and outputs are exactly app-container.yaml's, passed through 1:1
# Usage: bash ci/tests/app-workflow-interfaces.test.sh [workflows dir]   (needs mikefarah yq v4)
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/../.." && pwd)/.github/workflows}"
container="$dir/app-container.yaml"
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

keys() { yq -r "$1 // {} | keys | .[]" "$2" | LC_ALL=C sort | tr '\n' ' '; }
container_inputs=" $(keys '.on.workflow_call.inputs' "$container")"
container_secrets="$(keys '.on.workflow_call.secrets' "$container")"
container_outputs="$(keys '.on.workflow_call.outputs' "$container")"

ref_file="" ref_inputs=""
stacks=0
for f in "$dir"/app-*.yaml; do
  [[ "$(yq -r '.jobs.container.uses // ""' "$f")" == '$/.github/workflows/app-container.yaml' ]] || continue
  name="$(basename "$f")"
  stacks=$((stacks + 1))

  # Image inputs: name, type, default (descriptions may name stack-specific defaults).
  image_inputs=""
  for i in $(keys '.on.workflow_call.inputs' "$f"); do
    if [[ "$i" == build_container || "$container_inputs" == *" $i "* ]]; then
      image_inputs+="$i:$(yq -r ".on.workflow_call.inputs.$i | (.type) + \"=\" + (.default | tostring)" "$f") "
      if [[ "$i" != build_container ]]; then
        wired="$(yq -r ".jobs.container.with.$i // \"\" | tostring" "$f")"
        [[ "$wired" == *"inputs.$i"* ]] || fail "$name: input $i is not passed to the container job"
      fi
    fi
  done
  if [[ -z "$ref_file" ]]; then
    ref_file="$name" ref_inputs="$image_inputs"
  elif [[ "$image_inputs" != "$ref_inputs" ]]; then
    fail "$name: image inputs differ from $ref_file"$'\n'"  $name: $image_inputs"$'\n'"  $ref_file: $ref_inputs"
  fi

  # OpenChoreo manifests: every stack validates the app's deploy/openchoreo (app repos carry no validation code).
  [[ "$(yq -r '.jobs.manifests.uses // ""' "$f")" == '$/.github/workflows/app-openchoreo-manifests.yaml' ]] ||
    fail "$name: no 'manifests' job calling app-openchoreo-manifests.yaml"
  # shellcheck disable=SC2016 # the literal ${{ }} expression is the expected value
  [[ "$(yq -r '.on.workflow_call.inputs.openchoreo_manifests.default // ""' "$f")" == deploy/openchoreo &&
    "$(yq -r '.jobs.manifests.with.directory // ""' "$f")" == '${{ inputs.openchoreo_manifests }}' ]] ||
    fail "$name: input openchoreo_manifests (default deploy/openchoreo) is not passed to the manifests job"

  [[ "$(keys '.on.workflow_call.secrets' "$f")" == "$container_secrets" ]] ||
    fail "$name: secrets are not app-container.yaml's ($container_secrets)"
  for s in $container_secrets; do
    [[ "$(yq -r ".jobs.container.secrets.$s // \"\"" "$f")" == "\${{ secrets.$s }}" ]] ||
      fail "$name: secret $s is not passed to the container job"
  done

  [[ "$(keys '.on.workflow_call.outputs' "$f")" == "$container_outputs" ]] ||
    fail "$name: outputs are not app-container.yaml's ($container_outputs)"
  for o in $container_outputs; do
    [[ "$(yq -r ".on.workflow_call.outputs.$o.value // \"\"" "$f")" == "\${{ jobs.container.outputs.$o }}" ]] ||
      fail "$name: output $o is not jobs.container.outputs.$o"
  done
done

[[ "$stacks" -gt 0 ]] || fail "no app-*.yaml calls app-container.yaml from a 'container' job"
if [[ "$fails" -gt 0 ]]; then
  echo "$fails failure(s)" >&2
  exit 1
fi
echo "ok: $stacks stack workflows mirror app-container.yaml (image inputs, secrets, outputs)"
