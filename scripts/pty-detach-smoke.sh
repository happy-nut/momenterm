#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the product-default persistent-terminal contract.
# detach() must not kill the process tree: the backend session survives a Cmd+Q
# style detach and reattaches on the next spawn with the same sessionKey.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -D DEBUG \
  -o "$OUT/momenterm-pty-detach-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/MomentermKeyDebug.swift" \
  "$ROOT/Sources/Momenterm/NativePtyManager.swift" \
  "$ROOT/Sources/PtyDetachSmoke/main.swift"

cd "${1:-$ROOT}"
"$OUT/momenterm-pty-detach-smoke"
