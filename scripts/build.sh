#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/Momenterm" \
  "$ROOT"/Sources/Momenterm/*.swift \
  -framework AppKit \
  -framework WebKit

echo "$OUT/Momenterm"
