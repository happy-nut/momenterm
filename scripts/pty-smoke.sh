#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-pty-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/MomentermKeyDebug.swift" \
  "$ROOT/Sources/Momenterm/NativePtyManager.swift" \
  "$ROOT/Sources/PtySmoke/main.swift"

env npm_config_prefix=/tmp/momenterm-bad-prefix INIT_CWD=/tmp/momenterm-bad-init NODE=/tmp/momenterm-bad-node LANG=C LC_ALL=C LC_CTYPE=C "$OUT/momenterm-pty-smoke" "${1:-$ROOT}"
