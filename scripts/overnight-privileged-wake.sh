#!/usr/bin/env bash
# Root half of overnight-ctl start: install runner, run overnight as the
# logged-in user (no seatbelt, no secondbrain-agent), kickstart.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYS_RUNNER="/Library/Application Support/SecondBrain/sandbox/overnight-run.sh"
SYS_DIR="/Library/Application Support/SecondBrain/sandbox"
PROD="/Users/Shared/2nd-Brain-Night"
DEV="/Users/Shared/2nd-Brain-Dev"
INTERACTIVE="${SECONDBRAIN_INTERACTIVE_USER:-$(stat -f '%Su' /dev/console 2>/dev/null)}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "overnight-privileged-wake.sh must run as root" >&2
  exit 1
fi
[[ -n "$INTERACTIVE" ]] || { echo "no interactive user" >&2; exit 1; }

mkdir -p "$SYS_DIR" "$PROD/logs" "$PROD/state" "$PROD/queue/failed" \
  "$DEV/logs" "$DEV/state"
cp -f "$HERE/overnight-run.sh" "$SYS_RUNNER"
chmod 755 "$SYS_RUNNER"
rm -f "$SYS_DIR/secondbrain-agent.sb" "$SYS_DIR/secondbrain-dev.sb"

seed_interactive_ollama() {
  local dest="/Users/${INTERACTIVE}/.cline/data/settings"
  mkdir -p "$dest"
  python3 - "$dest/providers.json" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
base = "http://127.0.0.1:11434"
ollama = {
    "settings": {
        "provider": "ollama",
        "model": "qwen2.5-coder:7b",
        "baseUrl": base,
        "ollamaBaseUrl": base,
        "ollamaModelId": "qwen2.5-coder:7b",
    },
    "updatedAt": now,
    "tokenSource": "manual",
}
doc = {"version": 1, "providers": {}}
if os.path.isfile(path):
    try:
        loaded = json.load(open(path, encoding="utf-8"))
        if isinstance(loaded, dict):
            doc = loaded
    except Exception:
        pass
providers = dict(doc.get("providers") or {})
providers["ollama"] = ollama
providers["ollama-qwen-coder"] = ollama
doc["version"] = 1
doc["providers"] = providers
doc["lastUsedProvider"] = "ollama"
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
  chown -R "$INTERACTIVE:staff" "/Users/${INTERACTIVE}/.cline" 2>/dev/null || true
}
seed_interactive_ollama

# Old hub keeps the previous PATH / provider errors. Root can kill it.
pkill -9 -f 'cline-hub-daemon' 2>/dev/null || true
if command -v lsof >/dev/null; then
  lsof -ti tcp:25463 2>/dev/null | xargs kill -9 2>/dev/null || true
fi
rm -f "$PROD/state/current.json"

# Ollama is Homebrew CLI, not an icon on the Desktop. Install + start so
# overnight Cline has 127.0.0.1:11434. Model pull happens in overnight-run.
ensure_ollama_as_user() {
  local brew="/opt/homebrew/bin/brew"
  [[ -x "$brew" ]] || brew="/usr/local/bin/brew"
  [[ -x "$brew" ]] || return 0
  sudo -Hu "$INTERACTIVE" env HOME="/Users/$INTERACTIVE" \
    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$brew" install ollama >&2 || true
  sudo -Hu "$INTERACTIVE" env HOME="/Users/$INTERACTIVE" \
    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$brew" services start ollama >&2 || true
}
ensure_ollama_as_user

install_daemon() {
  local label="$1" drop="$2" env_name="$3" hour="$4" minute="$5"
  local plist="/Library/LaunchDaemons/${label}.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>UserName</key><string>${INTERACTIVE}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SYS_RUNNER}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${hour}</integer>
    <key>Minute</key><integer>${minute}</integer>
  </dict>
  <key>WatchPaths</key>
  <array>
    <string>${drop}/state/run-now</string>
  </array>
  <key>WorkingDirectory</key><string>${drop}</string>
  <key>StandardOutPath</key><string>${drop}/logs/overnight.stdout.log</string>
  <key>StandardErrorPath</key><string>${drop}/logs/overnight.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECONDBRAIN_ENV</key><string>${env_name}</string>
    <key>HOME</key><string>/Users/${INTERACTIVE}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST
  chmod 644 "$plist"
  launchctl bootout "system/${label}" 2>/dev/null || true
  launchctl bootstrap system "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true
}

install_daemon com.dao.secondbrain.overnight "$PROD" production 2 0
install_daemon com.dao.secondbrain.overnight-dev "$DEV" development 2 30

chown -R "$INTERACTIVE:staff" "$PROD/logs" "$PROD/state" "$PROD/queue" 2>/dev/null || true
chmod 770 "$PROD" "$PROD/logs" "$PROD/state" "$PROD/queue" "$PROD/queue/failed" 2>/dev/null || true
chmod -R u+rw "$PROD/logs" "$PROD/queue" 2>/dev/null || true

launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
