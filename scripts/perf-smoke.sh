#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.build/debug"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

git -C "$TMP" init -q
git -C "$TMP" config user.email perf-smoke@example.com
git -C "$TMP" config user.name "Perf Smoke"
perl -e 'for ($i = 1; $i <= 6000; $i++) { print "line $i\n" }' > "$TMP/large.txt"
git -C "$TMP" add large.txt
git -C "$TMP" commit -q -m "base"
perl -0pi -e 's/line 3000/line 3000 changed/' "$TMP/large.txt"
perl -e 'print "x" x 1100000' > "$TMP/huge-untracked.txt"

swiftc \
  -o "$OUT/momenterm-perf-smoke" \
  "$ROOT/Sources/Momenterm/Errors.swift" \
  "$ROOT/Sources/Momenterm/Shell.swift" \
  "$ROOT/Sources/Momenterm/NativeGitClient.swift" \
  "$ROOT/Sources/Momenterm/NativeReviewTypes.swift" \
  "$ROOT/Sources/Momenterm/UnifiedDiffParser.swift" \
  "$ROOT/Sources/Momenterm/NativeHTMLRenderer.swift" \
  "$ROOT/Sources/Momenterm/NativeReviewCore.swift" \
  "$ROOT/Sources/PerfSmoke/main.swift" \
  -framework Foundation

"$OUT/momenterm-perf-smoke" "$TMP"
