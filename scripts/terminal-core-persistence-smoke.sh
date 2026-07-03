#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for NativeTerminalCore save -> restore identity persistence
# (US-15). Compiles the pure NativeTerminalCore + PaneLayoutCodec + JSONValue in
# isolation (no AppKit, no PTY, no MainWindowController) against an isolated
# UserDefaults suite, and pins that workspace `id` and tab `workspaceId` survive the
# normalization that runs on every save AND restore. Dropping either collapses
# same-path (~/) workspace instances into one scope on relaunch, losing per-instance
# prompt memo / review notes and terminal ownership.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-terminal-core-persistence-smoke" \
  "$ROOT/Sources/Momenterm/NativeReviewTypes.swift" \
  "$ROOT/Sources/Momenterm/PaneLayoutCodec.swift" \
  "$ROOT/Sources/Momenterm/NativeTerminalCore.swift" \
  "$ROOT/Sources/TerminalCorePersistenceSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-terminal-core-persistence-smoke"
