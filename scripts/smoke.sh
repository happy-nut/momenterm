#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-core-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/Shell.swift" \
  "$ROOT/Sources/Momenterm/NativeReviewCore.swift" \
  "$ROOT/Sources/CoreSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-core-smoke" "$REPO"
