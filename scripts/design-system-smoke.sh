#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-design-system-smoke" \
  "$ROOT/Sources/Momenterm/NativeDesignSystem.swift" \
  "$ROOT/Sources/Momenterm/NativeTheme.swift" \
  "$ROOT/Sources/DesignSystemSmoke/main.swift" \
  -framework AppKit

"$OUT/momenterm-design-system-smoke"
