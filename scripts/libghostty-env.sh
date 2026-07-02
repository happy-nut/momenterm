#!/usr/bin/env bash

configure_libghostty() {
  MOMENTERM_LIBGHOSTTY_SWIFTC_FLAGS=()
  MOMENTERM_LIBGHOSTTY_LINK_FLAGS=()

  if [[ "${MOMENTERM_DISABLE_LIBGHOSTTY:-}" == "1" ]]; then
    return 0
  fi

  local root="$1"
  local version="storage.1.2.8"
  local checksum="eab8ecf086806acd6c0cfa198635c70e8b711c3a4d449bb0eb79b717b3960e24"
  local vendor="$root/.build/vendor/libghostty"
  local zip="$vendor/GhosttyKit.xcframework.zip"
  local xcframework="$vendor/GhosttyKit.xcframework"
  local slice="$xcframework/macos-arm64_x86_64"
  local headers="$slice/Headers"
  local library="$slice/libghostty.a"

  if [[ ! -f "$library" || ! -f "$headers/ghostty.h" ]]; then
    mkdir -p "$vendor"
    rm -rf "$xcframework"
    curl -L --fail --silent --show-error \
      -o "$zip" \
      "https://github.com/Lakr233/libghostty-spm/releases/download/$version/GhosttyKit.xcframework.zip"
    local actual
    actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
    if [[ "$actual" != "$checksum" ]]; then
      echo "libghostty checksum mismatch: expected $checksum, got $actual" >&2
      return 1
    fi
    unzip -q "$zip" -d "$vendor"
  fi

  MOMENTERM_LIBGHOSTTY_SWIFTC_FLAGS=(
    -D MOMENTERM_LIBGHOSTTY
    -I "$headers"
  )
  MOMENTERM_LIBGHOSTTY_LINK_FLAGS=(
    -L "$slice"
    -lghostty
    -lc++
    -framework QuartzCore
    -framework Metal
    -framework Carbon
    -framework IOSurface
  )
}
