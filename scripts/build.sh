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

# Prefer a stable self-signed identity so macOS Privacy (TCC) remembers granted
# permissions across rebuilds. A self-signed cert is fine here — TCC keys on the
# stable certificate, not on trust — so we match the identity by name whether or
# not it's marked "trusted". Falls back to ad-hoc if it isn't installed.
IDENTITY_NAME="${SNAPTURE_SIGN_IDENTITY:-Snapture Self-Signed}"
if security find-identity 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  SIGN_ID="$IDENTITY_NAME"
  echo "==> Code signing with stable identity '$IDENTITY_NAME'…"
else
  SIGN_ID="-"
  echo "==> Code signing (ad-hoc — run scripts/create-signing-cert.sh for persistent permissions)…"
fi

codesign --force --deep \
  --sign "$SIGN_ID" \
  --identifier "com.dao.snapture" \
  --entitlements "$ROOT/Resources/Snapture.entitlements" \
  "$APP"

echo "==> Done: $APP"
