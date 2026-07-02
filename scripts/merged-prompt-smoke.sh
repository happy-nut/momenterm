#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for merged-prompt terminal navigation (Option+Left/Right).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-merged-prompt-smoke" \
  "$ROOT/Sources/Momenterm/MergedPromptNavigation.swift" \
  "$ROOT/Sources/MergedPromptSmoke/main.swift"

"$OUT/momenterm-merged-prompt-smoke"
