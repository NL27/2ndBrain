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

seed_production_queue() {
  bash "$HERE/overnight-queue-seed.sh"
}

worker_started() {
  pgrep -f '/overnight-run.sh' >/dev/null 2>&1 \
    || pgrep -f '/opt/homebrew/bin/cline --cwd' >/dev/null 2>&1
}

# STOP file is not enough: Start clears it while the old bash is still in
# `sleep 30`, so the idle worker looks "already running" and never launches Cline.
stop_workers() {
  printf 'stop\n' > "$VAULT/Notes/Overnight/STOP"
  printf 'stop\n' > "$PROD/STOP" 2>/dev/null || true
  printf 'stop\n' > "$DEV/STOP" 2>/dev/null || true
  pkill -f '/overnight-run.sh' 2>/dev/null || true
  pkill -f "cline --cwd ${PROD}/work/" 2>/dev/null || true
  pkill -f "cline --cwd ${DEV}/work/" 2>/dev/null || true
  rm -rf "$PROD/state/worker.lock" "$DEV/state/worker.lock"
  sleep 1
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
  echo "Waiting for Ollama to finish loading qwen3.5:4b before Cline…" >&2
  local n=0 pid ollama_note
  pid="$(cat "$PROD/state/direct.pid" 2>/dev/null || true)"
  while (( n < 900 )); do
    pgrep -f '/opt/homebrew/bin/cline --cwd' >/dev/null 2>&1 && return 0
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if (( n % 10 == 0 )); then
      ollama_note="$(python3 - "$PROD/state/progress.json" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
if not os.path.isfile(path):
    print("loading")
    raise SystemExit
try:
    d = json.load(open(path, encoding="utf-8"))
except Exception:
    d = {}
print(d.get("ollama") or d.get("bar") or "loading")
PY
)"
      echo "  still waiting for Ollama (${n}s) — ${ollama_note:-loading}" >&2
    fi
    sleep 2
    n=$((n + 2))
  done
  worker_started
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
    echo "(empty — 01–05 will be seeded)"
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
    stop_workers
    echo "stopped"
    ;;
  start)
    stop_workers
    rm -f "$VAULT/Notes/Overnight/STOP" "$PROD/STOP" "$DEV/STOP" \
          "$PROD/state/stop" "$DEV/state/stop"
    seed_production_queue
    if [[ -x "$HERE/overnight-queue-sync.sh" ]]; then
      bash "$HERE/overnight-queue-sync.sh" >/dev/null 2>&1 || true
    fi
    if start_direct; then
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
    log="$PROD/logs/overnight.stderr.log"
    if ! pgrep -f '/overnight-run.sh' >/dev/null 2>&1 && [[ ! -f "$log" ]]; then
      echo "Overnight is not running. Start first: scripts/overnight-ctl.sh start" >&2
      exit 1
    fi
    mkdir -p "$PROD/logs"
    touch "$log"
    echo "Watching overnight (Ctrl-C stops this watcher, not Cline)."
    echo "Banners: NEW TASK / START PART / PART DONE / NEXT PART / SWITCH TASK / TASK DONE"
    echo
    tail -n 50 -F "$log"
    ;;
  ollama)
    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    echo "==> ollama binary"
    command -v ollama || { echo "ollama not on PATH"; exit 1; }
    ollama --version
    echo "==> brew services"
    brew services list 2>/dev/null | grep -i ollama || echo "(no brew service line)"
    echo "==> GET http://127.0.0.1:11434/api/tags"
    if ! curl -fsS -m 5 http://127.0.0.1:11434/api/tags; then
      echo "not listening — starting brew services ollama"
      brew services start ollama || true
      sleep 2
      curl -fsS -m 5 http://127.0.0.1:11434/api/tags || { echo "Ollama did not start"; exit 1; }
    fi
    echo
    echo "==> generate (qwen3.5:4b, one short reply)"
    python3 - <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(
    "http://127.0.0.1:11434/api/generate",
    data=json.dumps({
        "model": "qwen3.5:4b",
        "prompt": "Reply with the single word ok.",
        "stream": False,
        "think": False,
        "keep_alive": -1,
        "options": {"num_predict": 32, "temperature": 0},
    }).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        body = json.loads(r.read().decode())
except Exception as e:
    print("FAIL:", e)
    sys.exit(1)
text = (body.get("response") or "").strip()
if not text:
    print("FAIL: empty response")
    sys.exit(1)
print("OK:", text.replace("\n", " ")[:200])
PY
    ;;
  *)
    echo "usage: overnight-ctl.sh start|stop|status|watch|ollama" >&2
    exit 1
    ;;
esac
