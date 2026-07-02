#!/usr/bin/env bash
set -euo pipefail

# Isolation check for the extracted inline views (refactor step #4).
# Type-checks NativeTextViews.swift against only its real dependencies — no
# MainWindowController. If any view still coupled to the controller, this fails.
# (Views carry little pure logic, so isolation is the meaningful guarantee here;
# runtime behaviour is covered by the full build + core smoke.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

swiftc -typecheck \
  "$ROOT/Sources/Momenterm/NativeDesignSystem.swift" \
  "$ROOT/Sources/Momenterm/NativeTheme.swift" \
  "$ROOT/Sources/Momenterm/NativeAnsiRenderer.swift" \
  "$ROOT/Sources/Momenterm/MomentermKeyDebug.swift" \
  "$ROOT/Sources/Momenterm/NativeTextViews.swift" \
  -framework AppKit

echo "textviews isolated typecheck ok: 8 views compile without MainWindowController"
