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
repair_drop_perms() {
  local drop="$1" group="$2"
  mkdir -p "$drop/logs" "$drop/state" "$drop/work" "$drop/queue"
  chgrp "$group" "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" 2>/dev/null || true
  chmod 770 "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" 2>/dev/null || true
}

touch_run_now() {
  repair_drop_perms "$PROD" secondbrain
  repair_drop_perms "$DEV" secondbrain-dev
  date -u +%Y-%m-%dT%H:%M:%SZ > "$PROD/state/run-now"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DEV/state/run-now"
}

worker_started() {
  pgrep -u secondbrain-agent >/dev/null 2>&1 \
    || { [[ -s "$PROD/logs/overnight.stdout.log" ]] && return 0; } \
    || { [[ -s "$PROD/logs/overnight.stderr.log" ]] && return 0; }
}

kickstart_as_admin() {
  echo "Asking macOS to fix log permissions and kickstart overnight (admin password)…" >&2
  osascript <<OSA >/dev/null
do shell script "chown -R $USER:secondbrain /Users/Shared/2nd-Brain-Night/logs /Users/Shared/2nd-Brain-Night/state; chmod 770 /Users/Shared/2nd-Brain-Night /Users/Shared/2nd-Brain-Night/logs /Users/Shared/2nd-Brain-Night/state; touch /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log; chown secondbrain-agent:secondbrain /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log; chmod 664 /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log; chown -R $USER:secondbrain-dev /Users/Shared/2nd-Brain-Dev/logs /Users/Shared/2nd-Brain-Dev/state 2>/dev/null; chmod 770 /Users/Shared/2nd-Brain-Dev /Users/Shared/2nd-Brain-Dev/logs /Users/Shared/2nd-Brain-Dev/state 2>/dev/null; touch /Users/Shared/2nd-Brain-Dev/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Dev/logs/overnight.stderr.log 2>/dev/null; chown secondbrain-dev:secondbrain-dev /Users/Shared/2nd-Brain-Dev/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Dev/logs/overnight.stderr.log 2>/dev/null; launchctl kickstart -k system/com.dao.secondbrain.overnight; launchctl kickstart -k system/com.dao.secondbrain.overnight-dev" with administrator privileges
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

# Same checks we used to type by hand: logs on disk + processes as the sandbox user.
report_worker() {
  echo "==> waiting 3s for launchd…"
  sleep 3
  echo "==> $PROD/logs"
  ls -la "$PROD/logs" 2>/dev/null || echo "(no logs directory)"
  echo "==> tail overnight.stdout.log"
  tail -n 40 "$PROD/logs/overnight.stdout.log" 2>/dev/null || echo "(no overnight.stdout.log yet)"
  echo "==> tail overnight.stderr.log"
  tail -n 20 "$PROD/logs/overnight.stderr.log" 2>/dev/null || echo "(no overnight.stderr.log yet)"
  echo "==> ps -u secondbrain-agent"
  if ! pgrep -u secondbrain-agent >/dev/null 2>&1; then
    echo "(no secondbrain-agent processes)"
  else
    ps -u secondbrain-agent 2>/dev/null || true
  fi
  echo "==> launchctl print (production)"
  launchctl print system/com.dao.secondbrain.overnight 2>/dev/null \
    | grep -E 'state =|pid =|last exit code|program =|runs =|error' \
    || echo "(cannot print daemon)"
  echo "==> overnight-run.sh"
  ls -la "/Library/Application Support/SecondBrain/sandbox/overnight-run.sh" 2>/dev/null \
    || echo "(missing overnight-run.sh)"
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
    report_worker
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
