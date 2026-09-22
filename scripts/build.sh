#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Pano.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/ModuleCache"

echo "Pano derleniyor ($ARCH)…"
xcrun --sdk macosx swiftc \
  -swift-version 5 -O -parse-as-library \
  -sdk "$SDK_PATH" \
  -target "$ARCH-apple-macos13.0" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -framework AppKit -framework SwiftUI -framework Carbon \
  "$ROOT"/Sources/Pano/*.swift \
  -o "$APP_DIR/Contents/MacOS/Pano"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun --sdk macosx swift \
  -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  "$ROOT/scripts/make-icon.swift" "$BUILD_DIR/Pano.iconset" "$APP_DIR/Contents/Resources/Pano.icns"
/usr/bin/codesign --force --sign - "$APP_DIR"

echo "Hazır: $APP_DIR"
echo "Açmak için: open \"$APP_DIR\""
