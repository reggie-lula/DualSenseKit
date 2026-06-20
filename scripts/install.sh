#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SOURCE="$ROOT/.manual-build/DualSenseKit.app"
APP_DEST="$HOME/Applications/DualSenseKit.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$ROOT/scripts/build.sh" >/dev/null
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"
xattr -cr "$APP_DEST"
rm -rf "$APP_DEST/Contents/_CodeSignature"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DEST" >/dev/null 2>&1 || true

echo "$APP_DEST"
