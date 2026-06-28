#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-smoke" \
  "$ROOT/Sources/Momenterm/Models.swift" \
  "$ROOT/Sources/Momenterm/Shell.swift" \
  "$ROOT/Sources/Momenterm/GitDiffService.swift" \
  "$ROOT/Sources/Momenterm/UnifiedDiffParser.swift" \
  "$ROOT/Sources/Momenterm/HTMLRenderer.swift" \
  "$ROOT/Sources/MomentermSmoke/main.swift"

"$OUT/momenterm-smoke" "${1:-$ROOT}"
