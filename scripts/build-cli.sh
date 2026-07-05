#!/usr/bin/env bash
set -euo pipefail

# Builds the momenterm control-socket CLI. Separate from
# scripts/build.sh (which only compiles the app) because the CLI is its own
# executable that shares the pure wire protocol with the app.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-cli" \
  "$ROOT/Sources/Momenterm/MomentermCommandProtocol.swift" \
  "$ROOT/Sources/MomentermCLI/main.swift" \
  -framework Foundation

echo "$OUT/momenterm-cli"
