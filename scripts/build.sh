#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.manual-build"
MODE="${1:-app}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"

case "$MODE" in
  app|"")
    PRODUCT="DualSenseKitApp"
    APP_NAME="DualSenseKit"
    PLIST="$ROOT/Resources/Info.plist"
    ;;
  --demo|demo)
    PRODUCT="DualSenseKitDemo"
    APP_NAME="DualSenseKitDemo"
    PLIST="$ROOT/Resources/DemoInfo.plist"
    ;;
  *)
    echo "usage: scripts/build.sh [--demo]" >&2
    exit 2
    ;;
esac

swift build --disable-sandbox --product "$PRODUCT"
BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"

mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/$APP_NAME" "$BUILD_DIR/$APP_NAME.app"
cp "$BIN" "$BUILD_DIR/$APP_NAME"

APP_DIR="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
xattr -cr "$APP_DIR"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
SIGN_IDENTITY="${DUALSENSEKIT_CODESIGN_IDENTITY:-${CODESIGN_IDENTITY:-DualSenseKit}}"
if [[ -n "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  codesign \
    --force \
    --deep \
    --sign - \
    --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" \
    "$APP_DIR"
  cat >&2 <<'EOF'
warning: built with stable ad-hoc signing because no matching code signing identity was found.
         The designated requirement is pinned to the bundle identifier to reduce TCC permission resets.
         If you later create a valid identity, set DUALSENSEKIT_CODESIGN_IDENTITY to use it.
EOF
fi

echo "$BUILD_DIR/$APP_NAME"
echo "$APP_DIR"
