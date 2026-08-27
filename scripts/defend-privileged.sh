#!/usr/bin/env bash
# Privileged half of first-install isolation. Run via osascript "with
# administrator privileges" so one password dialog covers everything.
#
# Creates hidden non-admin users (production + development), Shared drop
# folders, deny ACLs, a pf anchor, overnight LaunchDaemons, and the Little
# Snitch filter keeper.
set -euo pipefail

GROUP_PROD="secondbrain"
GROUP_DEV="secondbrain-dev"
DROP_PROD="/Users/Shared/2nd-Brain-Night"
DROP_DEV="/Users/Shared/2nd-Brain-Dev"
INTERACTIVE="${SECONDBRAIN_INTERACTIVE_USER:-}"
INTERACTIVE_HOME="${SECONDBRAIN_INTERACTIVE_HOME:-}"
SUPPORT_SYS="/Library/Application Support/SecondBrain/sandbox"
ETC="/usr/local/etc/secondbrain"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [[ -z "$INTERACTIVE" ]]; then
  INTERACTIVE="$(stat -f '%Su' /dev/console 2>/dev/null || echo "")"
fi
if [[ -z "$INTERACTIVE_HOME" && -n "$INTERACTIVE" ]]; then
  INTERACTIVE_HOME="$(dscl . -read "/Users/$INTERACTIVE" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
fi
[[ -n "$INTERACTIVE" && -n "$INTERACTIVE_HOME" ]] || {
  echo "could not determine the logged-in user" >&2
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "defend-privileged.sh must run as root" >&2
  exit 1
fi

ensure_group() {
  local group="$1" real="$2"
  if ! dscl . -read "/Groups/$group" >/dev/null 2>&1; then
    dseditgroup -o create -n /Local/Default -r "$real" "$group"
  fi
  dseditgroup -o edit -n /Local/Default -a "$INTERACTIVE" -t user "$group" 2>/dev/null || true
}

ensure_user() {
  local user="$1" full="$2" group="$3"
  if ! dscl . -read "/Users/$user" >/dev/null 2>&1; then
    PASS="$(/usr/bin/openssl rand -base64 24)"
    sysadminctl -addUser "$user" \
      -fullName "$full" \
      -password "$PASS" \
      -home "/Users/$user" \
      -admin no
    unset PASS
    dscl . -create "/Users/$user" IsHidden 1
    defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add "$user" 2>/dev/null || true
  fi
  dseditgroup -o edit -n /Local/Default -a "$user" -t user "$group" 2>/dev/null || true
  dseditgroup -o edit -n /Local/Default -d "$user" -t user admin 2>/dev/null || true
  dseditgroup -o edit -n /Local/Default -d "$user" -t user wheel 2>/dev/null || true
  /usr/sbin/createhomedir -c -u "$user" >/dev/null 2>&1 || true
  mkdir -p "/Users/$user"
  chown -R "$user:staff" "/Users/$user"
  chmod 700 "/Users/$user"
  chmod -a "user:$user deny read,write,execute,delete,append,add_file,add_subdirectory,directory_inherit,file_inherit" \
    "$INTERACTIVE_HOME" 2>/dev/null || true
  chmod +a "user:$user deny read,write,execute,delete,append,add_file,add_subdirectory,directory_inherit,file_inherit" \
    "$INTERACTIVE_HOME"
}

ensure_drop() {
  local drop="$1" group="$2" user="${3:-}"
  mkdir -p "$drop"/{queue,queue/done,queue/rejected,work,logs,state}
  # Recurse: a josh:wheel logs dir is not writable by secondbrain-agent, so
  # launchd never creates overnight.stdout.log and the job never starts.
  chown -R "$INTERACTIVE:$group" "$drop"
  chmod 770 "$drop"
  chmod -R g+rwX,o-rwx "$drop"
  chmod 770 "$drop/logs" "$drop/state" "$drop/queue" "$drop/work"
  if [[ -n "$user" ]]; then
    touch "$drop/logs/overnight.stdout.log" "$drop/logs/overnight.stderr.log"
    chown "$user:$group" "$drop/logs/overnight.stdout.log" "$drop/logs/overnight.stderr.log"
    chmod 664 "$drop/logs/overnight.stdout.log" "$drop/logs/overnight.stderr.log"
  fi
  echo "$INTERACTIVE" > "$drop/.interactive-user"
  chmod 640 "$drop/.interactive-user"
  chown "$INTERACTIVE:$group" "$drop/.interactive-user"
}

install_overnight_daemon() {
  local label="$1" user="$2" group="$3" drop="$4" env_name="$5" hour="$6" minute="$7" profile="$8"
  local plist="/Library/LaunchDaemons/${label}.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>UserName</key><string>${user}</string>
  <key>GroupName</key><string>${group}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SUPPORT_SYS}/overnight-run.sh</string>
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
    <key>SECONDBRAIN_SANDBOX_PROFILE</key>
    <string>${SUPPORT_SYS}/${profile}</string>
    <key>SECONDBRAIN_SANDBOX_DIR</key>
    <string>${SUPPORT_SYS}</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
PLIST
  chmod 644 "$plist"
  launchctl bootout "system/${label}" 2>/dev/null || true
  launchctl bootstrap system "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true
}

ensure_group "$GROUP_PROD" "2nd Brain"
ensure_group "$GROUP_DEV" "2nd Brain Dev"
ensure_user "secondbrain-agent" "2nd Brain Agent" "$GROUP_PROD"
ensure_user "secondbrain-dev" "2nd Brain Dev" "$GROUP_DEV"
dseditgroup -o edit -n /Local/Default -d "secondbrain-agent" -t user "$GROUP_DEV" 2>/dev/null || true
dseditgroup -o edit -n /Local/Default -d "secondbrain-dev" -t user "$GROUP_PROD" 2>/dev/null || true

ensure_drop "$DROP_PROD" "$GROUP_PROD" secondbrain-agent
ensure_drop "$DROP_DEV" "$GROUP_DEV" secondbrain-dev

# --- sandbox profile + allowlist (system copy, agent-readable) -------------
SANDBOX_SRC="$ROOT/Resources/sandbox"
[[ -f "$SANDBOX_SRC/secondbrain-agent.sb" ]] || SANDBOX_SRC="$HERE/sandbox"

mkdir -p "$SUPPORT_SYS" "$ETC"
for f in secondbrain-agent.sb secondbrain-dev.sb allowlist.json allowlist-dev.json \
         environments.json known-persistence.json pf.anchor.conf; do
  [[ -f "$SANDBOX_SRC/$f" ]] && cp -f "$SANDBOX_SRC/$f" "$SUPPORT_SYS/$f"
done
if [[ -f "$SANDBOX_SRC/pf.anchor.conf" ]]; then
  mkdir -p /etc/pf.anchors
  cp -f "$SANDBOX_SRC/pf.anchor.conf" /etc/pf.anchors/com.dao.secondbrain
fi
touch "$ETC/allow.ips" "$ETC/allow-dev.ips"
grep -q '127.0.0.1' "$ETC/allow.ips" 2>/dev/null || printf '127.0.0.1\n::1\n' >> "$ETC/allow.ips"
grep -q '127.0.0.1' "$ETC/allow-dev.ips" 2>/dev/null || printf '127.0.0.1\n::1\n' >> "$ETC/allow-dev.ips"
chmod 644 "$SUPPORT_SYS"/* "$ETC/allow.ips" "$ETC/allow-dev.ips" 2>/dev/null || true

if [[ -f /etc/pf.anchors/com.dao.secondbrain ]]; then
  pfctl -a com.dao.secondbrain -f /etc/pf.anchors/com.dao.secondbrain 2>/dev/null || true
  pfctl -e 2>/dev/null || true
fi

FW=/usr/libexec/ApplicationFirewall/socketfilterfw
if [[ -x "$FW" ]]; then
  "$FW" --setglobalstate on >/dev/null
  "$FW" --setstealthmode on >/dev/null
  if [[ -d "/Applications/2nd Brain.app" ]]; then
    "$FW" --add "/Applications/2nd Brain.app" >/dev/null 2>&1 || true
    "$FW" --unblockapp "/Applications/2nd Brain.app" >/dev/null 2>&1 || true
  fi
fi

# Cline CLI for overnight (not the VS Code extension). Prefer a world-readable
# copy at /usr/local/bin so secondbrain-agent can exec it.
install_cline_system() {
  local src="" c
  for c in \
      "$INTERACTIVE_HOME/.local/bin/cline" \
      /opt/homebrew/bin/cline \
      /usr/local/bin/cline; do
    if [[ -x "$c" ]]; then src="$c"; break; fi
  done
  if [[ -z "$src" ]] && command -v npm >/dev/null; then
    c="$(npm prefix -g 2>/dev/null || true)/bin/cline"
    [[ -n "$c" && -x "$c" ]] && src="$c"
  fi
  [[ -n "$src" ]] || return 0
  mkdir -p /usr/local/bin
  cp -f "$src" /usr/local/bin/cline
  chmod 755 /usr/local/bin/cline
  for user in secondbrain-agent secondbrain-dev; do
    [[ -d "/Users/$user" ]] || continue
    mkdir -p "/Users/$user/.local/bin"
    cp -f "$src" "/Users/$user/.local/bin/cline"
    chown -R "$user:staff" "/Users/$user/.local"
    chmod 755 "/Users/$user/.local/bin/cline"
  done
}
install_cline_system

cp -f "$HERE/overnight-run.sh" "$SUPPORT_SYS/overnight-run.sh" 2>/dev/null || true
cp -f "$HERE/little-snitch-keeper.sh" "$SUPPORT_SYS/little-snitch-keeper.sh" 2>/dev/null || true
cp -f "$HERE/caldav-sync.py" "$HERE/caldav_lib.py" "$HERE/caldav-book.py" "$HERE/overnight-ctl.sh" \
  "$SUPPORT_SYS/" 2>/dev/null || true
chmod 755 "$SUPPORT_SYS/overnight-run.sh" "$SUPPORT_SYS/little-snitch-keeper.sh" \
  "$SUPPORT_SYS/caldav-sync.py" "$SUPPORT_SYS/caldav-book.py" "$SUPPORT_SYS/overnight-ctl.sh" 2>/dev/null || true

# Overnight Cline talks to the interactive user's Ollama on 127.0.0.1:11434.
# Seed local-only providers (no OpenRouter keys) so night jobs pick Qwen.
seed_agent_ollama_providers() {
  local user dest
  for user in secondbrain-agent secondbrain-dev; do
    [[ -d "/Users/$user" ]] || continue
    dest="/Users/$user/.cline/data/settings"
    mkdir -p "$dest"
    python3 - "$dest/providers.json" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def entry(provider, model, base):
    return {
        "settings": {"provider": provider, "model": model, "baseUrl": base},
        "updatedAt": now,
        "tokenSource": "manual",
    }
doc = {
    "version": 1,
    "lastUsedProvider": "ollama-qwen-coder",
    "providers": {
        "omlx-local": entry("openai-compatible", "qwen3-coder-next", "http://127.0.0.1:8000/v1"),
        "ollama-qwen35": entry("ollama", "qwen3.5:4b", "http://127.0.0.1:11434"),
        "ollama-qwen-coder": entry("ollama", "qwen2.5-coder:7b", "http://127.0.0.1:11434"),
    },
}
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
    chown -R "$user:staff" "/Users/$user/.cline"
    chmod -R go-rwx "/Users/$user/.cline"
  done
}
seed_agent_ollama_providers

# CalDAV password for production overnight (loopback). Not for secondbrain-dev.
CREDS_FILE="${INTERACTIVE_HOME}/Library/Application Support/SecondBrain/radicale/credentials.env"
if [[ -f "$CREDS_FILE" ]]; then
  mkdir -p "/Users/secondbrain-agent/.config/secondbrain"
  cp -f "$CREDS_FILE" "/Users/secondbrain-agent/.config/secondbrain/caldav.env"
  chown secondbrain-agent:staff "/Users/secondbrain-agent/.config/secondbrain/caldav.env"
  chmod 600 "/Users/secondbrain-agent/.config/secondbrain/caldav.env"
fi

install_overnight_daemon com.dao.secondbrain.overnight \
  secondbrain-agent "$GROUP_PROD" "$DROP_PROD" production 2 0 secondbrain-agent.sb
install_overnight_daemon com.dao.secondbrain.overnight-dev \
  secondbrain-dev "$GROUP_DEV" "$DROP_DEV" development 2 30 secondbrain-dev.sb

# Root kickstart actually starts the job. User-level kickstart on a system
# daemon is ignored, and WatchPaths misses writes that happened before load.
mkdir -p "$DROP_PROD/logs" "$DROP_PROD/state" "$DROP_DEV/logs" "$DROP_DEV/state"
if [[ ! -f "$DROP_PROD/STOP" ]]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DROP_PROD/state/run-now"
  chown "$INTERACTIVE:$GROUP_PROD" "$DROP_PROD/state/run-now" 2>/dev/null || true
  launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
fi
if [[ ! -f "$DROP_DEV/STOP" ]]; then
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DROP_DEV/state/run-now"
  chown "$INTERACTIVE:$GROUP_DEV" "$DROP_DEV/state/run-now" 2>/dev/null || true
  launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
fi

# Little Snitch demo filter turns off after 3 hours — re-enable (official CLI / menu).
KEEPER="/Library/LaunchDaemons/com.dao.secondbrain.snitch-keeper.plist"
cat > "$KEEPER" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.snitch-keeper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SUPPORT_SYS}/little-snitch-keeper.sh</string>
  </array>
  <key>StartInterval</key><integer>10800</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${DROP_PROD}/logs/snitch-keeper.stdout.log</string>
  <key>StandardErrorPath</key><string>${DROP_PROD}/logs/snitch-keeper.stderr.log</string>
</dict>
</plist>
PLIST
chmod 644 "$KEEPER"
launchctl bootout system/com.dao.secondbrain.snitch-keeper 2>/dev/null || true
launchctl bootstrap system "$KEEPER" 2>/dev/null || launchctl load -w "$KEEPER" 2>/dev/null || true

echo "ok users=secondbrain-agent,secondbrain-dev drops=$DROP_PROD,$DROP_DEV interactive=$INTERACTIVE"
