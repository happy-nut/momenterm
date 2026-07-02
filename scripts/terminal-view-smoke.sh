#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for NativeTerminalTextView (selectable + minimum inset).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-terminal-view-smoke" \
  "$ROOT/Sources/Momenterm/NativeDesignSystem.swift" \
  "$ROOT/Sources/Momenterm/NativeTheme.swift" \
  "$ROOT/Sources/Momenterm/NativeAnsiRenderer.swift" \
  "$ROOT/Sources/Momenterm/NativeTextViews.swift" \
  "$ROOT/Sources/TerminalViewSmoke/main.swift" \
  -framework AppKit

"$OUT/momenterm-terminal-view-smoke"
