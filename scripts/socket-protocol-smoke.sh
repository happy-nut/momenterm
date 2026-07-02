#!/usr/bin/env bash
set -euo pipefail

# Regression smoke for the Momenterm control-socket wire protocol (cmux axis 4).
# Compiles the pure MomentermCommand encode/decode in isolation (no AppKit, no
# socket, no MainWindowController) and pins the command -> JSON-line -> command
# round-trip plus graceful nil on malformed/unknown/partial input. Then confirms
# the CLI binary itself compiles (via scripts/build-cli.sh) so the shared
# protocol stays buildable from both the app and the CLI.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"

mkdir -p "$OUT"
swiftc \
  -o "$OUT/momenterm-socket-protocol-smoke" \
  "$ROOT/Sources/Momenterm/MomentermCommandProtocol.swift" \
  "$ROOT/Sources/SocketProtocolSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-socket-protocol-smoke"

# The protocol is only useful if the CLI that speaks it still builds.
"$ROOT/scripts/build-cli.sh" >/dev/null
echo "socket-protocol smoke ok: CLI binary compiles"
