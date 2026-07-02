#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the tmux-persistence detach contract.
# detach() must not kill the process tree: the tmux server session survives a
# Cmd+Q style detach and reattaches on the next spawn with the same sessionKey.
# tmux is optional — the smoke skips gracefully (exit 0) when tmux is absent.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-pty-detach-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/MomentermKeyDebug.swift" \
  "$ROOT/Sources/Momenterm/NativePtyManager.swift" \
  "$ROOT/Sources/PtyDetachSmoke/main.swift"

cd "${1:-$ROOT}"
"$OUT/momenterm-pty-detach-smoke"
