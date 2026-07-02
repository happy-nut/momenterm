#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the zsh shell-integration overlay: on a WINCH (pane
# split/resize) the prompt — including RPROMPT clocks — must redraw immediately
# instead of waiting for the next shell tick. Compiles NativePtyManager (which
# generates the overlay in terminalEnvironment()) in isolation and pins that the
# generated .zshrc (a) sources the user's real rc, (b) contains `zle reset-prompt`,
# (c) chains any existing TRAPWINCH. When a real zsh is present it also boots the
# overlay to prove the user's rc is sourced and the live TRAPWINCH behaves.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-shell-integration-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/NativePtyManager.swift" \
  "$ROOT/Sources/ShellIntegrationSmoke/main.swift"

cd "${1:-$ROOT}"
"$OUT/momenterm-shell-integration-smoke"
