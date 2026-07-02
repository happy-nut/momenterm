#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
source "$ROOT/scripts/libghostty-env.sh"
configure_libghostty "$ROOT"
swiftc \
  -o "$OUT/Momenterm" \
  "${MOMENTERM_LIBGHOSTTY_SWIFTC_FLAGS[@]}" \
  "$ROOT"/Sources/Momenterm/*.swift \
  -framework AppKit \
  -framework UserNotifications \
  "${MOMENTERM_LIBGHOSTTY_LINK_FLAGS[@]}"

echo "$OUT/Momenterm"
