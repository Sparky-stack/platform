#!/usr/bin/env bash
# Dev container post-create: install mise (pinned by MISE_VERSION), activate it for interactive shells, then install
# the toolchain from mise.toml (its postinstall hook adds the helm-unittest plugin).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/bin:$PATH"

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [[ -f "$rc" ]] || continue
  shell=$(basename "$rc" | sed 's/^\.//; s/rc$//')
  grep -q 'mise activate' "$rc" || echo "eval \"\$($HOME/.local/bin/mise activate $shell)\"" >> "$rc"
done

mise trust --yes "$PWD/mise.toml"
mise install
mise exec -- task doctor
