#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.manual-test-build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_RUNTIME="/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -parse-as-library \
  -Onone \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -module-name DualSenseKit \
  -emit-module \
  -emit-module-path "$BUILD_DIR/DualSenseKit.swiftmodule" \
  -c "$ROOT"/Sources/DualSenseKit/*.swift \
  -o "$BUILD_DIR/DualSenseKit.o"

(
  cd "$BUILD_DIR"
  xcrun swiftc \
    -parse-as-library \
    -Onone \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK_PATH" \
    -I "$BUILD_DIR" \
    -module-name DualSenseKitSelfTest \
    -emit-module \
    -emit-module-path "$BUILD_DIR/DualSenseKitSelfTest.swiftmodule" \
    -c "$ROOT"/Sources/DualSenseKitDemoCore/*.swift "$ROOT/Tests/SelfTest/main.swift"
)

xcrun clang \
  "$BUILD_DIR"/*.o \
  -target arm64-apple-macosx13.0 \
  -isysroot "$SDK_PATH" \
  -L /Library/Developer/CommandLineTools/usr/lib/swift/macosx \
  -L "$SWIFT_RUNTIME" \
  -rpath "$SWIFT_RUNTIME" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework GameController \
  -framework IOKit \
  -framework Network \
  -framework Security \
  -o "$BUILD_DIR/SelfTest"

"$BUILD_DIR/SelfTest"
