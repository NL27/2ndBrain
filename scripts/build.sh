#!/usr/bin/env bash
# Builds Snapture and assembles a signed .app bundle in ./dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Snapture"
CONFIG="${1:-release}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Build product not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Optional app icon, if present.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Code signing (ad-hoc)…"
# Ad-hoc signing with a stable identifier so macOS TCC remembers granted
# permissions across launches.
codesign --force --deep \
  --sign - \
  --identifier "com.dao.snapture" \
  --entitlements "$ROOT/Resources/Snapture.entitlements" \
  "$APP"

echo "==> Done: $APP"
