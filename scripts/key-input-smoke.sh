#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
source "$ROOT/scripts/libghostty-env.sh"
configure_libghostty "$ROOT"

sources=()
for file in "$ROOT"/Sources/Momenterm/*.swift; do
  if [[ "$file" == */main.swift ]]; then
    continue
  fi
  sources+=("$file")
done

swiftc \
  -o "$OUT/momenterm-key-input-smoke" \
  "${MOMENTERM_LIBGHOSTTY_SWIFTC_FLAGS[@]}" \
  "${sources[@]}" \
  "$ROOT/Sources/KeyInputSmoke/main.swift" \
  -framework AppKit \
  -framework UserNotifications \
  "${MOMENTERM_LIBGHOSTTY_LINK_FLAGS[@]}"

"$OUT/momenterm-key-input-smoke"
