#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"
LOG="${TMPDIR:-/tmp}/momenterm-launch-smoke.log"

launch_and_stop() {
  local label="$1"
  shift

  : > "$LOG"
  MOMENTERM_DISABLE_STATE_PERSISTENCE=1 "$@" --repo "$REPO" >"$LOG" 2>&1 &
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

check_app_icon() {
  local app="$1"
  local icon="$2"
  local swift_file
  local swift_dir
  swift_dir="$(mktemp -d "${TMPDIR:-/tmp}/momenterm-icon-smoke.XXXXXX")"
  swift_file="$swift_dir/icon-smoke.swift"
  cat > "$swift_file" <<'SWIFT'
import AppKit

func fail(_ message: String) -> Never {
    fputs("icon smoke failed: \(message)\n", stderr)
    exit(1)
}

func averageRGB(_ image: NSImage) -> (Double, Double, Double) {
    let size = 64
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fail("could not allocate bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0.0
    for y in 0..<size {
        for x in 0..<size {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.12 else {
                continue
            }
            red += Double(color.redComponent)
            green += Double(color.greenComponent)
            blue += Double(color.blueComponent)
            count += 1
        }
    }
    guard count > 0 else {
        fail("icon has no visible pixels")
    }
    return (red / count, green / count, blue / count)
}

let separator = CommandLine.arguments.lastIndex(of: "--") ?? 0
let userArguments = Array(CommandLine.arguments.dropFirst(separator + 1))
guard userArguments.count == 2 else {
    fail("missing app and icon paths")
}
let appPath = userArguments[0]
let iconPath = userArguments[1]
guard let bundle = Bundle(path: appPath) else {
    fail("could not read app bundle")
}
guard bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "Momenterm.icns" else {
    fail("CFBundleIconFile is not Momenterm.icns")
}
guard bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "Momenterm" else {
    fail("CFBundleIconName is not Momenterm")
}
guard let sourceIcon = NSImage(contentsOfFile: iconPath) else {
    fail("could not load source icon")
}
let appIcon = NSWorkspace.shared.icon(forFile: appPath)
guard appIcon.representations.contains(where: { $0.pixelsWide >= 512 && $0.pixelsHigh >= 512 }) else {
    fail("AppKit did not expose a high-resolution app icon")
}
let source = averageRGB(sourceIcon)
let resolved = averageRGB(appIcon)
let distance = abs(source.0 - resolved.0) + abs(source.1 - resolved.1) + abs(source.2 - resolved.2)
guard distance < 0.22 else {
    fail("resolved app icon does not match bundled icon; distance=\(distance)")
}
SWIFT
  swift "$swift_file" -- "$app" "$icon"
  rm -rf "$swift_dir"
}

BIN="$("$ROOT/scripts/build.sh")"
launch_and_stop "direct" "$BIN"

"$ROOT/scripts/package-app.sh" >/dev/null
test -s "$ROOT/.build/Momenterm.app/Contents/Resources/Momenterm.icns"
cmp -s "$ROOT/assets/icon.icns" "$ROOT/.build/Momenterm.app/Contents/Resources/Momenterm.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/.build/Momenterm.app/Contents/Info.plist")" = "Momenterm.icns"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ROOT/.build/Momenterm.app/Contents/Info.plist")" = "Momenterm"
check_app_icon "$ROOT/.build/Momenterm.app" "$ROOT/assets/icon.icns"
PATH=/usr/bin:/bin launch_and_stop "app" "$ROOT/.build/Momenterm.app/Contents/MacOS/Momenterm"

DMG="$("$ROOT/scripts/package-dmg.sh")"
test -s "$DMG"
DMG_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/momenterm-dmg.XXXXXX")"
cleanup_dmg() {
  hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
  rmdir "$DMG_MOUNT" >/dev/null 2>&1 || true
}
trap cleanup_dmg EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$DMG_MOUNT" >/dev/null
test -d "$DMG_MOUNT/Momenterm.app"
test -L "$DMG_MOUNT/Applications"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DMG_MOUNT/Momenterm.app/Contents/Info.plist")" = "dev.happynut.momenterm"
cleanup_dmg
trap - EXIT
echo "dmg package smoke ok"

"$ROOT/scripts/key-input-smoke.sh"
