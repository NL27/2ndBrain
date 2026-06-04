#!/usr/bin/env bash
# Snapture uninstaller — removes the app and (optionally) all user data.
#
# Usage:
#   scripts/uninstall.sh            # remove app + all data, models, prefs
#   scripts/uninstall.sh --keep-data  # remove the app only
set -euo pipefail

KEEP_DATA=0
[[ "${1:-}" == "--keep-data" ]] && KEEP_DATA=1

echo "==> Quitting Snapture…"
osascript -e 'tell application "Snapture" to quit' >/dev/null 2>&1 || true
pkill -x Snapture >/dev/null 2>&1 || true
sleep 1

echo "==> Removing /Applications/Snapture.app…"
rm -rf "/Applications/Snapture.app"

if [[ "$KEEP_DATA" -eq 0 ]]; then
  echo "==> Removing user data, models, recordings, clipboard history…"
  rm -rf "$HOME/Library/Application Support/Snapture"

  echo "==> Removing preferences…"
  defaults delete com.dao.snapture >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.dao.snapture.plist"

  echo "==> Removing Keychain entries…"
  security delete-generic-password -s "com.dao.snapture.ai" >/dev/null 2>&1 || true
else
  echo "==> Keeping user data (per --keep-data)."
fi

cat <<'EOF'

✅ Snapture uninstalled.

Note: macOS keeps the privacy (TCC) permission records. To fully reset them:
  • System Settings → Privacy & Security → Screen Recording / Microphone → remove Snapture
EOF
