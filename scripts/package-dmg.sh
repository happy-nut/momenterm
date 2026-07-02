#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/package-app.sh")"
DMG_ROOT="$ROOT/.build/dmg"
STAGING="$DMG_ROOT/Momenterm"
DMG="$ROOT/.build/Momenterm.dmg"
VOLUME_NAME="Momenterm"

rm -rf "$DMG_ROOT" "$DMG"
mkdir -p "$STAGING"

cp -R "$APP" "$STAGING/Momenterm.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

echo "$DMG"
