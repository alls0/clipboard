#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$BUILD_DIR/ModuleCache"

xcrun --sdk macosx swiftc \
  -swift-version 5 -parse-as-library \
  -sdk "$SDK_PATH" \
  -target "$ARCH-apple-macos13.0" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  "$ROOT/Sources/Pano/ClipboardStore.swift" \
  "$ROOT/Tests/ClipboardStoreChecks.swift" \
  -o "$BUILD_DIR/ClipboardStoreChecks"

"$BUILD_DIR/ClipboardStoreChecks"
