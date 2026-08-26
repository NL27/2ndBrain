#!/usr/bin/env bash
# Builds 2nd Brain and assembles a signed .app bundle in ./dist
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Executable / SwiftPM product (no spaces). Finder name can include a space.
EXEC_NAME="SecondBrain"
APP_NAME="2nd Brain"
CONFIG="${1:-release}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXEC_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Build product not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# The app runs this itself on first launch to install the local engines, so it
# has to travel inside the bundle.
cp "$ROOT/scripts/bootstrap.sh" "$APP/Contents/Resources/bootstrap.sh"
chmod +x "$APP/Contents/Resources/bootstrap.sh"
cp "$ROOT/scripts/sync-mcp-registry.py" "$APP/Contents/Resources/sync-mcp-registry.py"
chmod +x "$APP/Contents/Resources/sync-mcp-registry.py"
# bootstrap.sh shells out to these from its own directory.
cp "$ROOT/scripts/obsidian-setup.sh" "$APP/Contents/Resources/obsidian-setup.sh"
cp "$ROOT/scripts/obsidian_setup.py" "$APP/Contents/Resources/obsidian_setup.py"
chmod +x "$APP/Contents/Resources/obsidian-setup.sh" "$APP/Contents/Resources/obsidian_setup.py"
mkdir -p "$APP/Contents/Resources/sandbox" "$APP/Contents/Resources/skills"
cp "$ROOT/scripts/defend-setup.sh" "$APP/Contents/Resources/defend-setup.sh"
cp "$ROOT/scripts/defend-privileged.sh" "$APP/Contents/Resources/defend-privileged.sh"
cp "$ROOT/scripts/network-guard.py" "$APP/Contents/Resources/network-guard.py"
cp "$ROOT/scripts/overnight-run.sh" "$APP/Contents/Resources/overnight-run.sh"
cp "$ROOT/scripts/scan-secrets.py" "$APP/Contents/Resources/scan-secrets.py"
cp "$ROOT/scripts/host-integrity.py" "$APP/Contents/Resources/host-integrity.py"
cp "$ROOT/scripts/activity-watch.py" "$APP/Contents/Resources/activity-watch.py"
cp "$ROOT/scripts/little-snitch-keeper.sh" "$APP/Contents/Resources/little-snitch-keeper.sh"
cp "$ROOT/scripts/overnight-queue-sync.sh" "$APP/Contents/Resources/overnight-queue-sync.sh"
chmod +x "$APP/Contents/Resources/defend-setup.sh" \
         "$APP/Contents/Resources/defend-privileged.sh" \
         "$APP/Contents/Resources/network-guard.py" \
         "$APP/Contents/Resources/overnight-run.sh" \
         "$APP/Contents/Resources/scan-secrets.py" \
         "$APP/Contents/Resources/host-integrity.py" \
         "$APP/Contents/Resources/activity-watch.py" \
         "$APP/Contents/Resources/little-snitch-keeper.sh" \
         "$APP/Contents/Resources/overnight-queue-sync.sh"
cp "$ROOT/Resources/sandbox/"* "$APP/Contents/Resources/sandbox/"
cp -R "$ROOT/skills/mac-defend" "$ROOT/skills/mac-network-guard" "$ROOT/skills/overnight-sandbox" \
     "$ROOT/skills/secrets-hygiene" "$ROOT/skills/data-boundary" \
     "$ROOT/skills/prompt-injection-guard" "$ROOT/skills/mcp-trust" \
     "$ROOT/skills/persistence-hygiene" "$ROOT/skills/vault-exposure" \
     "$ROOT/skills/agent-hard-limits" \
     "$APP/Contents/Resources/skills/"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer a stable self-signed identity so macOS Privacy (TCC) remembers granted
# permissions across rebuilds.
IDENTITY_NAME="${SECONDBRAIN_SIGN_IDENTITY:-${SECONDBRAIN_SIGN_IDENTITY:-2nd Brain Self-Signed}}"
# Fall back to the previous 2ⁿᵈ Brain identity if the new one isn't installed yet.
if ! security find-identity 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  if security find-identity 2>/dev/null | grep -q "2nd Brain Self-Signed"; then
    IDENTITY_NAME="2nd Brain Self-Signed"
  fi
fi
if security find-identity 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  SIGN_ID="$IDENTITY_NAME"
  echo "==> Code signing with stable identity '$IDENTITY_NAME'…"
else
  SIGN_ID="-"
  echo "==> Code signing (ad-hoc — run scripts/create-signing-cert.sh for persistent permissions)…"
fi

codesign --force --deep \
  --sign "$SIGN_ID" \
  --identifier "com.dao.secondbrain" \
  --entitlements "$ROOT/Resources/SecondBrain.entitlements" \
  "$APP"

echo "==> Done: $APP"
