#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for terminal pane split layout serialization (cmux axis 3 /
# PRD US-4). Compiles the pure PaneLayoutCodec + JSONValue in isolation (no
# AppKit, no PTY, no MainWindowController) and pins the
# encode -> JSON -> decode round-trip for single-pane, below/horizontal,
# side-by-side/vertical, nested splits, sanitization, and v2 backward
# compatibility (legacy record without a "panes" key -> single pane).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-pane-layout-smoke" \
  "$ROOT/Sources/Momenterm/NativeReviewTypes.swift" \
  "$ROOT/Sources/Momenterm/PaneLayoutCodec.swift" \
  "$ROOT/Sources/PaneLayoutSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-pane-layout-smoke"
