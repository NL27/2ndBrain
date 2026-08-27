#!/usr/bin/env bash
# 2ⁿᵈ Brain uninstaller — removes the app and (optionally) all user data.
#
# Usage:
#   scripts/uninstall.sh            # remove app + all data, models, prefs
#   scripts/uninstall.sh --keep-data  # remove the app only
set -euo pipefail

KEEP_DATA=0
[[ "${1:-}" == "--keep-data" ]] && KEEP_DATA=1

echo "==> Quitting 2ⁿᵈ Brain…"
osascript -e 'tell application "2nd Brain" to quit' >/dev/null 2>&1 || true
pkill -x SecondBrain >/dev/null 2>&1 || true
sleep 1

echo "==> Removing /Applications/2nd Brain.app…"
rm -rf "/Applications/2nd Brain.app"

if [[ "$KEEP_DATA" -eq 0 ]]; then
  # heed runs out of the support directory, so stop it before deleting it.
  for port in 5170 5002; do
    lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  done

  # The vault on the Desktop is deliberately untouched: it holds notes and
  # recordings the user created, not app state.
  echo "==> Removing app data, models, clipboard history, heed…"
  rm -rf "$HOME/Library/Application Support/SecondBrain"

  echo "==> Removing preferences…"
  defaults delete com.dao.secondbrain >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/com.dao.secondbrain.plist"

  echo "==> Removing Keychain entries…"
  security delete-generic-password -s "com.dao.secondbrain.ai" >/dev/null 2>&1 || true
else
  echo "==> Keeping user data (per --keep-data)."
fi

cat <<'EOF'

✅ 2ⁿᵈ Brain uninstalled.

Notes:
  • Your vault at ~/Desktop/2nd Brain is left alone — notes, screenshots, recordings
    and transcripts all stay, as does the Obsidian side of it. Delete it by hand if
    you really mean to.
  • Local CalDAV (Radicale) data is in ~/Library/Application Support/SecondBrain/radicale
    and LaunchAgents com.dao.secondbrain.radicale / caldav-sync. Remove those plists if
    you no longer want a local calendar server.
  • The overnight sandbox users `secondbrain-agent` (production) and
    `secondbrain-dev` (development) are also left alone (deleting a
    macOS user is irreversible from this script). Remove them in System Settings →
    Users & Groups if you created it.
  • Turn off "Start at Login" before uninstalling, or remove the leftover entry in
    System Settings → General → Login Items & Extensions.
  • heed lived in the data folder, so it's gone with it (its own settings and notes
    stay in ~/.heed-app).
  • The other engines are shared installs, so they're left alone. Remove them with:
      pipx uninstall tiron                          (frees ~5 GB with its models)
      brew uninstall whisper-cpp ffmpeg python@3.12
      rm -rf ~/.cache/huggingface                   (downloaded model cache)
  • macOS keeps the privacy (TCC) permission records. To fully reset them:
    System Settings → Privacy & Security → Screen Recording / Microphone → remove 2ⁿᵈ Brain
EOF
