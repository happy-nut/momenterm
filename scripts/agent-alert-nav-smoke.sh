#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the agent-alert unread jump navigation (Cmd+Shift+U).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-agent-alert-nav-smoke" \
  "$ROOT/Sources/Momenterm/AgentAlertNavigation.swift" \
  "$ROOT/Sources/AgentAlertNavSmoke/main.swift"

"$OUT/momenterm-agent-alert-nav-smoke"
