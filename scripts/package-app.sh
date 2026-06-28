#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/Momenterm.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
MONACORI_DIST="${MONACORI_DIST:-$ROOT/../monacori/dist}"

if [[ ! -f "$MONACORI_DIST/build.js" ]]; then
  echo "monacori dist not found: $MONACORI_DIST" >&2
  echo "Set MONACORI_DIST=/absolute/path/to/monacori/dist" >&2
  exit 1
fi

BIN="$("$ROOT/scripts/build.sh")"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES/Support" "$RESOURCES/monacori"
cp "$BIN" "$MACOS/Momenterm"
cp "$ROOT/Support/monacori-bridge.mjs" "$RESOURCES/Support/monacori-bridge.mjs"
rsync -a --delete "$MONACORI_DIST/" "$RESOURCES/monacori/dist/"

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
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
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
