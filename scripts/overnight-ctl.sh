#!/usr/bin/env bash
# Start or stop overnight agents from the menu (interactive user).
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
PROD="/Users/Shared/2nd-Brain-Night"
DEV="/Users/Shared/2nd-Brain-Dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-status}"

mkdir -p "$VAULT/Notes/Overnight" "$PROD/state" "$DEV/state" 2>/dev/null || true

ensure_overnight_daemon() {
  if launchctl print system/com.dao.secondbrain.overnight >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -f "$HERE/defend-setup.sh" ]]; then
    return 1
  fi
  echo "Production daemon is not loaded — macOS will ask for an admin password to install it." >&2
  bash "$HERE/defend-setup.sh" || true
  launchctl print system/com.dao.secondbrain.overnight >/dev/null 2>&1
}

case "$CMD" in
  stop)
    printf 'stop\n' > "$VAULT/Notes/Overnight/STOP"
    printf 'stop\n' > "$PROD/STOP" 2>/dev/null || true
    printf 'stop\n' > "$DEV/STOP" 2>/dev/null || true
    echo "stopped"
    ;;
  start)
    rm -f "$VAULT/Notes/Overnight/STOP" "$PROD/STOP" "$DEV/STOP" \
          "$PROD/state/stop" "$DEV/state/stop"
    if [[ -x "$HERE/overnight-queue-sync.sh" ]]; then
      bash "$HERE/overnight-queue-sync.sh" >/dev/null 2>&1 || true
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ > "$PROD/state/run-now" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$DEV/state/run-now" 2>/dev/null || true
    ensure_overnight_daemon || true
    # WatchPaths should fire. kickstart wakes it immediately when the daemon is loaded.
    launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
    launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
    if launchctl print system/com.dao.secondbrain.overnight >/dev/null 2>&1; then
      echo "started (production daemon loaded — watch the log window for a pid)"
    else
      echo "started (STOP cleared). Production daemon is still not loaded — approve the admin dialog, then run: scripts/overnight-ctl.sh start"
    fi
    ;;
  status)
    if [[ -f "$VAULT/Notes/Overnight/STOP" || -f "$PROD/STOP" ]]; then
      echo "stopped"
    else
      echo "running-until-stop"
    fi
    ;;
  *)
    echo "usage: overnight-ctl.sh start|stop|status" >&2
    exit 1
    ;;
esac
