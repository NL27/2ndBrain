#!/usr/bin/env bash
# Start or stop overnight agents from the menu (interactive user).
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
PROD="/Users/Shared/2nd-Brain-Night"
DEV="/Users/Shared/2nd-Brain-Dev"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-status}"

mkdir -p "$VAULT/Notes/Overnight" "$PROD/state" "$PROD/logs" "$DEV/state" "$DEV/logs" 2>/dev/null || true

# Start runs overnight-run.sh as the logged-in user. No LaunchDaemon, no
# defend-setup, no admin password. 02:00 launchd is optional.
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
  mkdir -p "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" \
    "$drop/queue/done" "$drop/queue/rejected" "$drop/queue/failed"
  chgrp "$group" "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" 2>/dev/null || true
  chmod 770 "$drop" "$drop/logs" "$drop/state" "$drop/work" "$drop/queue" \
    "$drop/queue/done" "$drop/queue/rejected" "$drop/queue/failed" 2>/dev/null || true
  for f in "$drop/logs"/* "$drop/state"/*; do
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
  pgrep -f '/overnight-run.sh' >/dev/null 2>&1 \
    || pgrep -f '/opt/homebrew/bin/cline' >/dev/null 2>&1
}

worker_stable() {
  worker_started || return 1
  sleep 2
  worker_started
}

start_direct() {
  mkdir -p "$PROD/logs" "$PROD/state" "$PROD/queue" "$PROD/work"
  rm -rf "$PROD/state/worker.lock" "$PROD/state/current.json"
  echo "======== $(date -u +%Y-%m-%dT%H:%M:%SZ) overnight-ctl start (direct, no launchd) ========" >> "$PROD/logs/overnight.stderr.log"
  echo "Starting overnight as $USER from $HERE/overnight-run.sh (no admin)…" >&2
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export SECONDBRAIN_ENV=production
  export CLINE_SESSION_BACKEND_MODE=local
  nohup /bin/bash "$HERE/overnight-run.sh" \
    >> "$PROD/logs/overnight.stdout.log" \
    2>> "$PROD/logs/overnight.stderr.log" &
  echo $! > "$PROD/state/direct.pid"
  worker_stable
}

# Same checks we used to type by hand: logs on disk + processes as the sandbox user.
report_worker() {
  echo "==> waiting 3s…"
  sleep 3
  echo "==> $PROD/logs"
  ls -la "$PROD/logs" 2>/dev/null || echo "(no logs directory)"
  echo "==> tail overnight.stdout.log"
  tail -n 40 "$PROD/logs/overnight.stdout.log" 2>/dev/null || echo "(no overnight.stdout.log yet)"
  echo "==> tail overnight.stderr.log"
  tail -n 20 "$PROD/logs/overnight.stderr.log" 2>/dev/null || echo "(no overnight.stderr.log yet)"
  echo "==> overnight / cline processes"
  pgrep -lf overnight-run.sh 2>/dev/null || echo "(no overnight-run.sh)"
  pgrep -lf /opt/homebrew/bin/cline 2>/dev/null || echo "(no homebrew cline)"
  echo "==> launchd (optional 02:00 job)"
  launchctl print system/com.dao.secondbrain.overnight 2>/dev/null \
    | grep -E 'state =|pid =|last exit code|program =|runs =|error|user =' \
    || echo "not loaded (Start does not need it)"
  echo "==> queue"
  found=0
  for f in "$PROD/queue"/*.md "$PROD/queue"/*.txt; do
    [[ -f "$f" ]] || continue
    echo "${f##*/}"
    found=1
  done
  if [[ "$found" -eq 0 ]]; then
    echo "(empty — copy 00-smoke.md here)"
  fi
  echo "==> queue/failed"
  ls -1 "$PROD/queue/failed" 2>/dev/null || echo "(none)"
  echo "==> newest cline out"
  newest_out="$(ls -t "$PROD/logs"/cline-*.out 2>/dev/null | head -1 || true)"
  if [[ -n "$newest_out" ]]; then
    echo "$newest_out"
    tail -n 40 "$newest_out"
  else
    echo "(none yet)"
  fi
  echo "==> ollama on 127.0.0.1:11434"
  if curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    curl -fsS -m 2 http://127.0.0.1:11434/api/tags \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(", ".join(m.get("name","") for m in d.get("models") or []) or "(no models pulled)")'
  else
    echo "not answering — overnight will brew install / start Ollama (no Desktop app)"
  fi
  echo "==> overnight-run.sh"
  echo "direct: $HERE/overnight-run.sh"
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
    if worker_started; then
      echo "already running"
    elif start_direct; then
      echo "started (direct worker as $USER — no admin)"
    else
      echo "started but worker did not appear — check $PROD/logs/overnight.stderr.log"
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
  watch)
    out="$(ls -t "$PROD/logs"/cline-*.out 2>/dev/null | head -1 || true)"
    pid="$(pgrep -n -f '/opt/homebrew/bin/cline --cwd' || true)"
    if [[ -z "$pid" ]]; then
      echo "Cline is not running. Start first: scripts/overnight-ctl.sh start" >&2
      exit 1
    fi
    echo "Watching Cline pid=$pid  (Ctrl-C stops the watcher, not Cline)"
    item="queue"
    [[ -n "$out" ]] || out="$PROD/logs/cline-watch.out"
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      sleep 5
      elapsed=$((elapsed + 5))
      python3 - "$PROD/state/progress.json" "$out" "$item" "$elapsed" "$pid" <<'PY'
import json, os, sys, urllib.request
from datetime import datetime, timezone
progress, out, item, elapsed, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
w = 24
pos = (elapsed // 5) % w
bar = "[" + (" " * pos) + "█" + (" " * (w - pos - 1)) + f"] {elapsed}s"
ollama = "idle"
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=1) as r:
        names = [m.get("name") or "" for m in json.load(r).get("models") or []]
        ollama = ", ".join(n for n in names if n) or "loading model"
except Exception:
    ollama = "not answering"
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
line = json.dumps({"ts": ts, "type": "heartbeat", "elapsed_s": elapsed, "item": item, "ollama": ollama, "bar": bar})
os.makedirs(os.path.dirname(progress), exist_ok=True)
open(progress, "w", encoding="utf-8").write(json.dumps({
    "ts": ts, "type": "heartbeat", "elapsed_s": elapsed, "item": item,
    "pid": pid, "ollama": ollama, "bar": bar, "alive": True,
}, indent=2) + "\n")
try:
    with open(out, "a", encoding="utf-8") as f:
        f.write(line + "\n")
except OSError:
    pass
print(f"still working  {bar}  ollama={ollama}", flush=True)
PY
    done
    echo "Cline pid $pid has exited"
    ;;
  *)
    echo "usage: overnight-ctl.sh start|stop|status|watch" >&2
    exit 1
    ;;
esac
