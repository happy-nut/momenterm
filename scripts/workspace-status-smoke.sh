#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for WorkspaceStatusProvider's pure parsing (cmux axis 2:
# rich workspace rail status). Compiles the provider + Shell in isolation (no AppKit,
# no process spawning) and pins the gh-PR-JSON and lsof-output parsers.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-workspace-status-smoke" \
  "$ROOT/Sources/Momenterm/Shell.swift" \
  "$ROOT/Sources/Momenterm/WorkspaceStatusProvider.swift" \
  "$ROOT/Sources/WorkspaceStatusSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-workspace-status-smoke"
