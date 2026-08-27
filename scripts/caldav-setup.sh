#!/usr/bin/env bash
# Local CalDAV (Radicale) on 127.0.0.1:5232 — not Google, not LAN.
# Password stays in Application Support (mode 600), never the vault.
set -uo pipefail

MODE="install"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT="${HOME}/Library/Application Support/SecondBrain/radicale"
VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
USER_NAME="$(id -un)"
PORT=5232

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift;;
    *) shift;;
  esac
done

emit() { printf 'STEP|%s|%s|%s\n' "$1" "$2" "$3"; }

have() { command -v "$1" >/dev/null 2>&1; }

radicale_bin() {
  if have radicale; then command -v radicale; return; fi
  [[ -x "$HOME/.local/bin/radicale" ]] && echo "$HOME/.local/bin/radicale"
}

healthy() {
  curl -fsS -m 2 "http://127.0.0.1:${PORT}/.web/" >/dev/null 2>&1 \
    || curl -fsS -m 2 "http://127.0.0.1:${PORT}/" >/dev/null 2>&1
}

ensure_pipx() {
  have pipx && return 0
  have brew && brew install pipx >&2 && pipx ensurepath >&2 || true
  have pipx
}

write_config() {
  mkdir -p "$SUPPORT/collections" "$SUPPORT"
  chmod 700 "$SUPPORT"
  cat > "$SUPPORT/config" <<EOF
[server]
hosts = 127.0.0.1:${PORT}

[auth]
type = htpasswd
htpasswd_filename = ${SUPPORT}/users
htpasswd_encryption = autodetect
delay = 1

[rights]
type = owner_only

[storage]
type = multifilesystem
filesystem_folder = ${SUPPORT}/collections

[logging]
level = warning
EOF
  chmod 600 "$SUPPORT/config"
}

ensure_users() {
  if [[ -f "$SUPPORT/users" && -f "$SUPPORT/credentials.env" ]]; then
    return 0
  fi
  local pass hash
  pass="$(/usr/bin/openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  hash=""
  if command -v openssl >/dev/null; then
    hash="$(openssl passwd -6 "$pass" 2>/dev/null || true)"
  fi
  if [[ -z "$hash" && -x /opt/homebrew/opt/openssl@3/bin/openssl ]]; then
    hash="$(/opt/homebrew/opt/openssl@3/bin/openssl passwd -6 "$pass" 2>/dev/null || true)"
  fi
  if [[ -z "$hash" ]]; then
    hash="$(/usr/bin/openssl passwd -apr1 "$pass")"
  fi
  printf '%s:%s\n' "$USER_NAME" "$hash" > "$SUPPORT/users"
  printf '%s:%s\n' "secondbrain-agent" "$hash" >> "$SUPPORT/users"
  chmod 600 "$SUPPORT/users"
  cat > "$SUPPORT/credentials.env" <<EOF
CALDAV_URL=http://127.0.0.1:${PORT}/${USER_NAME}/
CALDAV_USER=${USER_NAME}
CALDAV_PASSWORD=${pass}
CALDAV_AGENT_USER=secondbrain-agent
EOF
  chmod 600 "$SUPPORT/credentials.env"
  unset pass
}

install_launchagent() {
  local bin plist
  bin="$(radicale_bin)"
  [[ -n "$bin" ]] || return 1
  plist="$HOME/Library/LaunchAgents/com.dao.secondbrain.radicale.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.radicale</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bin}</string>
    <string>--config</string>
    <string>${SUPPORT}/config</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/secondbrain-radicale.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/secondbrain-radicale.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.radicale" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null || true
}

write_vault_howto() {
  mkdir -p "$VAULT/Notes/Calendar"
  cat > "$VAULT/Notes/Calendar/CalDAV.md" <<EOF
---
tags: [calendar, caldav]
---
# Local CalDAV

Server: \`http://127.0.0.1:${PORT}/\` (this Mac only). Password: \`CALDAV_PASSWORD\` in \`~/Library/Application Support/SecondBrain/radicale/credentials.env\` (mode 600 — never the vault).

Apple Calendar → Add Account → Other CalDAV Account → Manual → server \`127.0.0.1:${PORT}\`, username \`${USER_NAME}\`. Then subscribe to the calendars below and set colours if Apple does not pick them up: **Private = blue**, **Professional = red**.

| Calendar | Colour | Who sees what |
|----------|--------|----------------|
| Private | blue | You: everything. Friends: **where** (location) on \`Private (where)\`, not what or with whom |
| Professional | red | You: everything. Work: **Busy** only on \`Work (busy)\` |
| Tasks | grey | To-dos. They do not block meetings unless the task has both \`due:\` and \`at:\` |

Join: both you and the other person must accept before the full private event is exported (\`scripts/caldav-book.py join-request\` / \`join-accept\`).

Booking (times only — no titles leave this Mac):

\`\`\`
python3 scripts/caldav-book.py propose --calendar professional --mode times --days 3 --choices 3
python3 scripts/caldav-book.py propose --calendar private --mode window --start 18:00 --end 20:00 --date 2026-08-28
python3 scripts/caldav-book.py accept --offer ID --slot SLOT --title "…" --guest "Name"
python3 scripts/caldav-book.py optimize
\`\`\`

Send the generated \`Notes/Calendar/offer-….md\` card. Cloud n8n cannot reach this loopback server.
EOF
}

emit caldav checking "Looking for local CalDAV (Radicale on 127.0.0.1:${PORT})"

if [[ "$MODE" == "check" ]]; then
  if healthy || [[ -x "$(radicale_bin 2>/dev/null || true)" ]]; then
    emit caldav ok "Radicale CalDAV on 127.0.0.1:${PORT}"
    exit 0
  fi
  emit caldav failed "CalDAV not installed"
  exit 1
fi

if ! have radicale && [[ ! -x "$HOME/.local/bin/radicale" ]]; then
  emit caldav installing "Installing Radicale (local CalDAV)"
  ensure_pipx || { emit caldav failed "pipx missing — cannot install Radicale"; exit 1; }
  if ! pipx install radicale >&2; then
    sleep 4
    pipx install radicale >&2 || { emit caldav failed "pipx could not install Radicale — re-run setup"; exit 1; }
  fi
  pipx inject radicale passlib >&2 || true
fi

write_config
ensure_users
write_vault_howto
if install_launchagent; then
  sleep 2
fi
if [[ -f "$HERE/caldav-sync.py" ]]; then
  mkdir -p "$HOME/Library/Application Support/SecondBrain/sandbox"
  cp -f "$HERE/caldav-sync.py" "$HERE/caldav_lib.py" "$HERE/caldav-book.py" \
    "$HOME/Library/Application Support/SecondBrain/sandbox/" 2>/dev/null || true
  chmod +x "$HOME/Library/Application Support/SecondBrain/sandbox/caldav-sync.py" \
    "$HOME/Library/Application Support/SecondBrain/sandbox/caldav-book.py" 2>/dev/null || true
  SYNC_PLIST="$HOME/Library/LaunchAgents/com.dao.secondbrain.caldav-sync.plist"
  cat > "$SYNC_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dao.secondbrain.caldav-sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${HOME}/Library/Application Support/SecondBrain/sandbox/caldav-sync.py</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SECOND_BRAIN_VAULT</key>
    <string>${VAULT}</string>
  </dict>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/secondbrain-caldav-sync.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/secondbrain-caldav-sync.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.dao.secondbrain.caldav-sync" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$SYNC_PLIST" 2>/dev/null || launchctl load -w "$SYNC_PLIST" 2>/dev/null || true
  python3 "$HERE/caldav-sync.py" >&2 || true
fi

if healthy || [[ -n "$(radicale_bin)" ]]; then
  emit caldav ok "Local CalDAV at http://127.0.0.1:${PORT}/ — add it in Apple Calendar (password not in the vault)"
  exit 0
fi
emit caldav failed "Radicale installed but not answering on :${PORT}"
exit 1
