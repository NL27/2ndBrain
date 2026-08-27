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
SYS_RUNNER="/Library/Application Support/SecondBrain/sandbox/overnight-run.sh"

allow_agent_append() {
  local drop="$1" agent="$2" f
  chmod -a "user:$agent allow read,write,append" "$drop/logs" 2>/dev/null || true
  chmod +a "user:$agent allow list,search,add_file,add_subdirectory,read,write,append" "$drop/logs" 2>/dev/null || true
  for f in "$drop/logs"/*.jsonl; do
    [[ -f "$f" ]] || continue
    chmod -a "user:$agent allow read,write,append" "$f" 2>/dev/null || true
    chmod +a "user:$agent allow read,write,append" "$f" 2>/dev/null || true
  done
}

repair_drop_perms() {
  local drop="$1" group="$2" agent="$3"
  local f
  mkdir -p "$drop/logs" "$drop/state" "$drop/work" "$drop/queue"
  chgrp "$group" "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" 2>/dev/null || true
  chmod 770 "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" 2>/dev/null || true
  for f in "$drop/logs"/*.jsonl "$drop/state"/*; do
    [[ -e "$f" ]] || continue
    [[ "$(stat -f '%Su' "$f" 2>/dev/null)" == "root" ]] && continue
    chgrp "$group" "$f" 2>/dev/null || true
    chmod g+rw "$f" 2>/dev/null || true
  done
  allow_agent_append "$drop" "$agent"
}

touch_run_now() {
  repair_drop_perms "$PROD" secondbrain secondbrain-agent
  repair_drop_perms "$DEV" secondbrain-dev secondbrain-dev
  date -u +%Y-%m-%dT%H:%M:%SZ > "$PROD/state/run-now"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$DEV/state/run-now"
}

worker_started() {
  pgrep -u secondbrain-agent -f 'overnight-run.sh' >/dev/null 2>&1 \
    || pgrep -u secondbrain-agent -f '/cline' >/dev/null 2>&1
}

# A crash in the first second used to count as "up" and skip installing the new runner.
worker_stable() {
  worker_started || return 1
  sleep 2
  worker_started
}

system_runner_stale() {
  [[ -f "$HERE/overnight-run.sh" ]] || return 1
  local sb="$HERE/../Resources/sandbox/secondbrain-agent.sb"
  [[ -f "$sb" ]] || sb="$HERE/secondbrain-agent.sb"
  ! cmp -s "$HERE/overnight-run.sh" "$SYS_RUNNER" 2>/dev/null \
    || { [[ -f "$sb" ]] && ! cmp -s "$sb" "/Library/Application Support/SecondBrain/sandbox/secondbrain-agent.sb" 2>/dev/null; }
}

kickstart_as_admin() {
  local sb_dir="$HERE/../Resources/sandbox"
  [[ -f "$sb_dir/secondbrain-agent.sb" ]] || sb_dir="$HERE"
  echo "Asking macOS to install overnight-run.sh, sandbox profile, fix the agent home, and kickstart (admin password)…" >&2
  osascript <<OSA >/dev/null
do shell script "cp '$HERE/overnight-run.sh' '$SYS_RUNNER'; chmod 755 '$SYS_RUNNER'; cp '$sb_dir/secondbrain-agent.sb' '/Library/Application Support/SecondBrain/sandbox/secondbrain-agent.sb'; cp '$sb_dir/secondbrain-dev.sb' '/Library/Application Support/SecondBrain/sandbox/secondbrain-dev.sb'; /usr/sbin/createhomedir -c -u secondbrain-agent >/dev/null 2>&1; true; /usr/sbin/createhomedir -c -u secondbrain-dev >/dev/null 2>&1; true; mkdir -p /Users/secondbrain-agent /Users/secondbrain-dev; chown -R secondbrain-agent:staff /Users/secondbrain-agent; chown -R secondbrain-dev:staff /Users/secondbrain-dev; chmod 700 /Users/secondbrain-agent /Users/secondbrain-dev; chown -R $USER:secondbrain /Users/Shared/2nd-Brain-Night/logs /Users/Shared/2nd-Brain-Night/state; chmod 770 /Users/Shared/2nd-Brain-Night /Users/Shared/2nd-Brain-Night/logs /Users/Shared/2nd-Brain-Night/state; chmod g+rw /Users/Shared/2nd-Brain-Night/logs/*.jsonl 2>/dev/null; true; : > /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log; : > /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log; chown secondbrain-agent:secondbrain /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log /Users/Shared/2nd-Brain-Night/logs/activity.jsonl; chmod 664 /Users/Shared/2nd-Brain-Night/logs/overnight.stdout.log /Users/Shared/2nd-Brain-Night/logs/overnight.stderr.log /Users/Shared/2nd-Brain-Night/logs/activity.jsonl; launchctl kickstart -k system/com.dao.secondbrain.overnight; launchctl kickstart -k system/com.dao.secondbrain.overnight-dev" with administrator privileges
OSA
}

wake_overnight() {
  local did_admin=0
  touch_run_now
  if system_runner_stale; then
    echo "System overnight-run.sh is stale — admin password to install this repo's script." >&2
    kickstart_as_admin || true
    did_admin=1
  else
    launchctl kickstart -k system/com.dao.secondbrain.overnight 2>/dev/null || true
    launchctl kickstart -k system/com.dao.secondbrain.overnight-dev 2>/dev/null || true
  fi
  worker_stable && return 0
  if (( did_admin == 0 )); then
    kickstart_as_admin || true
  fi
  worker_stable
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
  echo "==> overnight-run.sh (system vs repo)"
  ls -la "$SYS_RUNNER" 2>/dev/null || echo "(missing overnight-run.sh)"
  if cmp -s "$HERE/overnight-run.sh" "$SYS_RUNNER" 2>/dev/null; then
    echo "system copy matches this repo"
  else
    echo "STALE: system copy does not match $HERE/overnight-run.sh — approve the admin dialog"
  fi
  echo "==> /Users/secondbrain-agent"
  ls -ld /Users/secondbrain-agent 2>/dev/null || echo "(no home directory)"
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
