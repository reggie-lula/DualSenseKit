#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.manual-build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_RUNTIME="/Library/Developer/CommandLineTools/usr/lib/swift-6.2/macosx"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -parse-as-library \
  -Onone \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -module-name DualSenseBridgeSDK \
  -emit-module \
  -emit-module-path "$BUILD_DIR/DualSenseBridgeSDK.swiftmodule" \
  -c "$ROOT"/Sources/DualSenseBridgeSDK/*.swift \
  -o "$BUILD_DIR/DualSenseBridgeSDK.o"

(
  cd "$BUILD_DIR"
  xcrun swiftc \
    -parse-as-library \
    -Onone \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK_PATH" \
    -I "$BUILD_DIR" \
    -module-name DualSenseBridgeCore \
    -emit-module \
    -emit-module-path "$BUILD_DIR/DualSenseBridgeCore.swiftmodule" \
    -c "$ROOT"/Sources/DualSenseBridgeCore/*.swift
)

xcrun swiftc \
  -parse-as-library \
  -Onone \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" \
  -I "$BUILD_DIR" \
  -module-name DualSenseBridge \
  -c "$ROOT/Sources/DualSenseBridge/main.swift" \
  -o "$BUILD_DIR/main.o"

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
  -o "$BUILD_DIR/DualSenseBridge"

APP_DIR="$BUILD_DIR/DualSenseBridge.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/DualSenseBridge" "$APP_DIR/Contents/MacOS/DualSenseBridge"
chmod +x "$APP_DIR/Contents/MacOS/DualSenseBridge"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
xattr -cr "$APP_DIR"
rm -rf "$APP_DIR/Contents/_CodeSignature"

echo "$BUILD_DIR/DualSenseBridge"
echo "$APP_DIR"
