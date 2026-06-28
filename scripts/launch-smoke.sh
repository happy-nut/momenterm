#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"
LOG="${TMPDIR:-/tmp}/momenterm-launch-smoke.log"

launch_and_stop() {
  local label="$1"
  shift

  : > "$LOG"
  "$@" --repo "$REPO" >"$LOG" 2>&1 &
  local pid=$!
  sleep 4

  if ps -p "$pid" >/dev/null; then
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    echo "$label launch smoke ok"
    return
  fi

  echo "$label launch smoke failed" >&2
  cat "$LOG" >&2
  exit 1
}

BIN="$("$ROOT/scripts/build.sh")"
launch_and_stop "direct" "$BIN"

"$ROOT/scripts/package-app.sh" >/dev/null
PATH=/usr/bin:/bin launch_and_stop "app" "$ROOT/.build/Momenterm.app/Contents/MacOS/Momenterm"
