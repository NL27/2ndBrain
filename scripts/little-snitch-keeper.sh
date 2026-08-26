#!/usr/bin/env bash
# Turn Little Snitch's network filter back on.
#
# Demo mode turns the filter off after three hours; Objective Development
# documents that you may re-enable it as often as you like (same as clicking
# the status menu). This script uses the official `littlesnitch` CLI when
# Terminal access is allowed, then a menu-bar click. It does not patch the
# app or touch license files.
set -uo pipefail

LOG_DIR="/Users/Shared/2nd-Brain-Night/logs"
VAULT_SECURITY="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}/Notes/Security"
mkdir -p "$LOG_DIR" "$VAULT_SECURITY" 2>/dev/null || true

log() {
  local kind="$1" msg="$2"
  python3 - "$kind" "$msg" "$LOG_DIR/activity.jsonl" <<'PY' 2>/dev/null || true
import json, sys
from datetime import datetime, timezone
kind, msg, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "ts": datetime.now(timezone.utc).isoformat(),
            "kind": kind,
            "severity": "info",
            "detail": msg[:200],
        }) + "\n")
except OSError:
    pass
PY
  echo "$kind $msg"
}

find_cli() {
  local c
  for c in \
      /usr/local/bin/littlesnitch \
      /opt/homebrew/bin/littlesnitch \
      "/Applications/Little Snitch.app/Contents/Components/littlesnitch" \
      "/Applications/Little Snitch.app/Contents/MacOS/littlesnitch" \
      "/Library/Little Snitch/littlesnitch"; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v littlesnitch 2>/dev/null && return 0
  return 1
}

if [[ ! -d "/Applications/Little Snitch.app" ]] && ! find_cli >/dev/null; then
  log littlesnitch-absent "Little Snitch is not installed — macOS firewall + pf still apply"
  exit 0
fi

CLI="$(find_cli || true)"
ENABLED=0

if [[ -n "$CLI" ]]; then
  # Preference key names differ across versions; try the documented ones.
  for key in networkFilterEnabled filterEnabled networkFilter isNetworkFilterActive; do
    if "$CLI" write-preference "$key" true >/dev/null 2>&1 \
       || sudo -n "$CLI" write-preference "$key" true >/dev/null 2>&1 \
       || sudo -n "$CLI" --user "$(id -un)" write-preference "$key" true >/dev/null 2>&1; then
      ENABLED=1
      log littlesnitch-filter-on "write-preference $key true"
      break
    fi
  done
fi

if (( ENABLED == 0 )); then
  # Same action as the human clicking Enable Network Filter in the status menu.
  if osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "System Events"
  set extraNames to {"Little Snitch", "Little Snitch Agent", "Little Snitch Network Monitor"}
  repeat with procName in extraNames
    if exists process procName then
      tell process procName
        try
          click menu extra 1 of menu bar 1
          delay 0.3
          set helpItems to {"Enable Network Filter", "Network Filter", "Turn On Network Filter", "Start Filter"}
          repeat with t in helpItems
            try
              click menu item t of menu 1 of menu extra 1 of menu bar 1
              return
            end try
          end repeat
          -- Checkbox-style: click the first item that mentions Filter
          try
            click (first menu item of menu 1 of menu extra 1 of menu bar 1 whose name contains "Filter")
          end try
        end try
      end tell
    end if
  end repeat
end tell
APPLESCRIPT
  then
    ENABLED=1
    log littlesnitch-filter-on "status-menu click"
  else
    log littlesnitch-filter-pending "Could not enable via CLI (allow Terminal access in Little Snitch → Settings → Security) or status menu"
  fi
fi

exit 0
