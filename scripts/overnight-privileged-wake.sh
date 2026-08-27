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

# Copy the runner in place. Only unload/reload the plist when it changed or
# the daemon is missing — bootout-every-Start left the job unloaded.
install_daemon() {
  local label="$1" drop="$2" env_name="$3" hour="$4" minute="$5"
  local plist="/Library/LaunchDaemons/${label}.plist"
  local tmp="${plist}.new"
  local log="$PROD/logs/overnight.stderr.log"
  cat > "$tmp" <<PLIST
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
    <key>CLINE_SESSION_BACKEND_MODE</key><string>local</string>
  </dict>
</dict>
</plist>
PLIST
  chmod 644 "$tmp"
  local loaded=0
  launchctl print "system/${label}" >/dev/null 2>&1 && loaded=1
  if [[ "$loaded" -eq 1 ]] && cmp -s "$tmp" "$plist" 2>/dev/null; then
    rm -f "$tmp"
    echo "wake: $label already loaded, plist unchanged" >> "$log"
    return 0
  fi
  mv -f "$tmp" "$plist"
  if [[ "$loaded" -eq 1 ]]; then
    launchctl bootout "system/${label}" >>"$log" 2>&1 || true
    sleep 1
  fi
  if ! launchctl bootstrap system "$plist" >>"$log" 2>&1; then
    echo "wake: bootstrap failed for $label, trying enable+load" >> "$log"
    launchctl enable "system/${label}" >>"$log" 2>&1 || true
    launchctl bootstrap system "$plist" >>"$log" 2>&1 \
      || launchctl load -w "$plist" >>"$log" 2>&1 || true
    sleep 1
  fi
  if ! launchctl print "system/${label}" >/dev/null 2>&1; then
    echo "wake: FAILED to load $label" >> "$log"
    return 1
  fi
  echo "wake: loaded $label" >> "$log"
}

install_daemon com.dao.secondbrain.overnight "$PROD" production 2 0
install_daemon com.dao.secondbrain.overnight-dev "$DEV" development 2 30

# Runner is stopped. Reap leftover overnight Cline clients in this drop
# (launchd kills bash; Cline children can keep running).
pkill -f "cline --cwd ${PROD}/work/" 2>/dev/null || true
pkill -f "cline --cwd ${DEV}/work/" 2>/dev/null || true
pkill -f "cline --cwd ${PROD}/overnight work/" 2>/dev/null || true
pkill -f "cline --cwd ${DEV}/overnight work/" 2>/dev/null || true
pkill -f 'cline-hub-daemon' 2>/dev/null || true
rm -f "$PROD/state/current.json"
rm -rf "$PROD/state/worker.lock" "$PROD/state/worker.pid"

if [[ -x /opt/homebrew/bin/ollama || -x /usr/local/bin/ollama ]]; then
  sudo -Hu "$INTERACTIVE" env HOME="/Users/$INTERACTIVE" \
    PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /opt/homebrew/bin/brew services start ollama >/dev/null 2>&1 || true
fi

chown -R "$INTERACTIVE:staff" "$PROD/logs" "$PROD/state" "$PROD/queue" 2>/dev/null || true
chmod 770 "$PROD" "$PROD/logs" "$PROD/state" "$PROD/queue" "$PROD/queue/failed" 2>/dev/null || true
chmod -R u+rw "$PROD/logs" "$PROD/queue" 2>/dev/null || true

launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
