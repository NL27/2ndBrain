#!/usr/bin/env bash
# Start or stop overnight agents from the menu (interactive user).
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
PROD="/Users/Shared/2nd-Brain-Night"
DEV="/Users/Shared/2nd-Brain-Dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-status}"

mkdir -p "$VAULT/Notes/Overnight" "$PROD/state" "$PROD/logs" "$DEV/state" "$DEV/logs" 2>/dev/null || true

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

# launchd only notices run-now after the daemon is loaded. User-level kickstart
# on a system LaunchDaemon is usually ignored; WatchPaths or root kickstart works.
touch_run_now() {
  mkdir -p "$PROD/state" "$PROD/logs" "$DEV/state" "$DEV/logs"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$PROD/state/run-now"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DEV/state/run-now"
}

worker_started() {
  [[ -f "$PROD/logs/overnight.stdout.log" || -f "$PROD/logs/overnight.stderr.log" ]] \
    || pgrep -u secondbrain-agent >/dev/null 2>&1
}

kickstart_as_admin() {
  echo "Asking macOS to kickstart the overnight daemon (admin password)…" >&2
  osascript <<'OSA' >/dev/null
do shell script "launchctl kickstart -k system/com.dao.secondbrain.overnight; launchctl kickstart -k system/com.dao.secondbrain.overnight-dev" with administrator privileges
OSA
}

wake_overnight() {
  touch_run_now
  launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
  launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
  local n=0
  while (( n < 6 )); do
    worker_started && return 0
    sleep 1
    n=$((n + 1))
  done
  kickstart_as_admin || true
  n=0
  while (( n < 8 )); do
    worker_started && return 0
    sleep 1
    n=$((n + 1))
  done
  return 1
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
    ensure_overnight_daemon || true
    if ! launchctl print system/com.dao.secondbrain.overnight >/dev/null 2>&1; then
      echo "started (STOP cleared). Production daemon is still not loaded — approve the admin dialog, then run: scripts/overnight-ctl.sh start"
      exit 0
    fi
    if wake_overnight; then
      echo "started (production worker is up — watch the log window for a pid)"
    else
      echo "started (daemon loaded, worker did not appear). Check /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log"
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
