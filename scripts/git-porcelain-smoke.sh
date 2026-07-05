#!/usr/bin/env bash
set -euo pipefail

# Isolated smoke for NativeGitPorcelain.parse: verifies the IntelliJ-style change-type classification
# (modified=blue, untracked=red, added=green) behind file-tree VCS tints. Compiles the pure parser plus
# its assertion harness with swiftc — no AppKit, no app build.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-git-porcelain-smoke" \
  "$ROOT/Sources/Momenterm/NativeGitPorcelain.swift" \
  "$ROOT/Sources/GitPorcelainSmoke/main.swift"

"$OUT/momenterm-git-porcelain-smoke"
