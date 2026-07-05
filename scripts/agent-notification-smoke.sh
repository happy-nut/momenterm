#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the agent-notification OSC parser.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-agent-notification-smoke" \
  "$ROOT/Sources/Momenterm/AgentNotification.swift" \
  "$ROOT/Sources/AgentNotificationSmoke/main.swift"

"$OUT/momenterm-agent-notification-smoke"
