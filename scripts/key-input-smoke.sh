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
  -D DEBUG \
  -o "$OUT/momenterm-key-input-smoke" \
  "${MOMENTERM_LIBGHOSTTY_SWIFTC_FLAGS[@]}" \
  "${sources[@]}" \
  "$ROOT"/Sources/KeyInputSmoke/*.swift \
  -framework AppKit \
  -framework UserNotifications \
  "${MOMENTERM_LIBGHOSTTY_LINK_FLAGS[@]}"

# The smoke drives the real controller, which persists workspace/review/file-tree state through
# UserDefaults.standard, keyed off the executable name. cfprefsd caches that domain in memory, so a
# plain `defaults delete` before the run races with the daemon and stale state leaks between repeated
# local runs (making persistence-sensitive assertions flaky). Run a uniquely-named copy instead so
# every invocation gets a guaranteed-fresh, un-cached domain. (Other GUI smokes use UUID-suffixed
# domains and are already isolated.)
RUN="$(mktemp -t momenterm-key-input-smoke.XXXXXX)"
cp "$OUT/momenterm-key-input-smoke" "$RUN"
chmod +x "$RUN"
set +e
"$RUN"
status=$?
set -e
rm -f "$RUN"
defaults delete "$(basename "$RUN")" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$(basename "$RUN").plist" 2>/dev/null || true
exit "$status"
