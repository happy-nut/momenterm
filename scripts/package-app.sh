#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Momenterm.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

BIN="$("$ROOT/scripts/build.sh")"
SOURCE_ICON="$ROOT/assets/icon.icns"
ICON="$RESOURCES/Momenterm.icns"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/Momenterm"
cp "$SOURCE_ICON" "$ICON"
if [ -d "$ROOT/resources/webviews" ]; then
  cp -r "$ROOT/resources/webviews" "$RESOURCES/webviews"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Momenterm</string>
  <key>CFBundleIdentifier</key>
  <string>dev.happynut.momenterm</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Momenterm</string>
  <key>CFBundleIconFile</key>
  <string>Momenterm.icns</string>
  <key>CFBundleIconName</key>
  <string>Momenterm</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$APP"
