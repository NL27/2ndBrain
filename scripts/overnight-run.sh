#!/usr/bin/env bash
# Overnight Cline runner. Runs as the logged-in user (no seatbelt / no
# secondbrain-agent). Queue and logs stay in the Shared drop folder.
set -uo pipefail
# launchd PATH is /usr/bin:/bin; Cline shells out to ioreg in /usr/sbin.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_NAME="${SECONDBRAIN_ENV:-production}"
if [[ -z "${SECONDBRAIN_SANDBOX_DIR:-}" ]]; then
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$_here/../Resources/sandbox/environments.json" ]]; then
    export SECONDBRAIN_SANDBOX_DIR="$(cd "$_here/../Resources/sandbox" && pwd)"
  elif [[ -f "$_here/environments.json" ]]; then
    export SECONDBRAIN_SANDBOX_DIR="$_here"
  fi
fi
eval "$(python3 - "$ENV_NAME" <<'PY'
import json, os, sys
from pathlib import Path
name = sys.argv[1]
roots = [
    Path("/Library/Application Support/SecondBrain/sandbox/environments.json"),
    Path.home() / "Library/Application Support/SecondBrain/sandbox/environments.json",
]
here = Path(os.environ.get("SECONDBRAIN_SANDBOX_DIR", ""))
if here:
    roots.insert(0, here / "environments.json")
data = {}
try:
    for p in roots:
        if p.is_file():
            data = json.loads(p.read_text(encoding="utf-8"))
            break
except Exception:
    data = {}
env = (data.get("environments") or {}).get(name) or {}
def sh(key, value):
    print(f"{key}={json.dumps(str(value))}")
sh("AGENT_USER", env.get("user") or os.environ.get("SECONDBRAIN_AGENT_USER", "secondbrain-agent"))
sh("DROP", env.get("drop") or "/Users/Shared/2nd-Brain-Night")
sh("PROFILE_NAME", env.get("sandbox_profile") or "secondbrain-agent.sb")
sh("TIMEOUT_DEFAULT", 0 if env.get("timeout") == 0 else (env.get("timeout") if env.get("timeout") is not None else 0))
sh("ITER_TIMEOUT_DEFAULT", env.get("iter_timeout") or 3600)
sh("MAX_ITERS_DEFAULT", env.get("max_iters") or 8)
sh("SAFETY_DEFAULT", env.get("safety_timeout") or 604800)
sh("UNTIL_STOP_DEFAULT", "1" if env.get("until_stop", True) else "0")
sh("NETWORK_MODE", env.get("network") or "allowlist")
sh("ENV_LABEL", name)
PY
)"

AGENT_USER="$(id -un)"
DROP="${DROP:-/Users/Shared/2nd-Brain-Night}"
STATE="$DROP/state/current.json"
LOG="$DROP/logs/activity.jsonl"
QUEUE="$DROP/queue"
WORK="$DROP/work"
CLINE_BIN="${CLINE_BIN:-}"
TIMEOUT="${OVERNIGHT_BUDGET:-${TIMEOUT_DEFAULT:-0}}"
ITER_TIMEOUT="${OVERNIGHT_ITER_TIMEOUT:-${ITER_TIMEOUT_DEFAULT:-3600}}"
MAX_ITERS="${OVERNIGHT_MAX_ITERS:-${MAX_ITERS_DEFAULT:-8}}"
SAFETY="${OVERNIGHT_SAFETY:-${SAFETY_DEFAULT:-604800}}"
UNTIL_STOP="${OVERNIGHT_UNTIL_STOP:-${UNTIL_STOP_DEFAULT:-1}}"

mkdir -p "$DROP/logs" "$DROP/state" "$WORK" "$QUEUE"

# One production worker. WatchPaths + kickstart used to start two Cline slices.
LOCKDIR="$DROP/state/worker.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  old_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "overnight-run already active pid=$old_pid — not starting a second Cline" >&2
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || {
    echo "overnight-run already active" >&2
    exit 0
  }
fi
echo $$ > "$LOCKDIR/pid"
release_lock() { rm -rf "$LOCKDIR" 2>/dev/null || true; }
trap 'echo "overnight-run stopping — leaving the queue item in place" >&2; release_lock; exit 143' TERM INT HUP
trap release_lock EXIT
pkill -f "cline --cwd ${WORK}/" 2>/dev/null || true
echo "======== $(date -u +%Y-%m-%dT%H:%M:%SZ) overnight-run pid=$$ ========" >&2

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:-1] if False else sys.argv[1]))' "$1"
}

log_event() {
  local kind="$1"; shift
  python3 - "$kind" "$LOG" "$@" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
kind, path = sys.argv[1], sys.argv[2]
extra = dict(zip(sys.argv[3::2], sys.argv[4::2]))
event = {"ts": datetime.now(timezone.utc).isoformat(), "kind": kind, **extra}
line = json.dumps(event) + "\n"
candidates = [path]
p = Path(path)
candidates.append(str(p.with_name("overnight-activity.jsonl")))
for dest in candidates:
    try:
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        with open(dest, "a", encoding="utf-8") as f:
            f.write(line)
        sys.exit(0)
    except OSError:
        continue
# Logging must not kill the worker (josh:wheel activity.jsonl is not writable
# by secondbrain-agent).
sys.exit(0)
PY
}

whoami_now="$(id -un)"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "overnight-run must not run as root" >&2
  exit 1
fi

if [[ -z "$CLINE_BIN" ]]; then
  for candidate in \
      /opt/homebrew/bin/cline \
      /usr/local/bin/cline \
      "$(command -v cline 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && CLINE_BIN="$candidate" && break
  done
fi
if [[ -z "$CLINE_BIN" ]]; then
  log_event failed reason "cline-not-installed"
  echo "cline is not installed (need /opt/homebrew/bin/cline)" >&2
  exit 1
fi

# Cline 3 -P is a built-in SDK id (ollama), not a custom providers.json key.
# Seed ~/.cline so overnight does not depend on an interactive `cline auth`.
ensure_ollama_provider() {
  python3 - "${HOME}/.cline/data/settings/providers.json" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path = sys.argv[1]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
base = "http://127.0.0.1:11434"
ollama = {
    "settings": {
        "provider": "ollama",
        "model": "qwen3.5:4b",
        "baseUrl": base,
        "ollamaBaseUrl": base,
        "ollamaModelId": "qwen3.5:4b",
        "timeout": 900,
        "requestTimeout": 900000,
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
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
}
ensure_ollama_provider

# Homebrew Ollama is a CLI (+ menubar), not an app on the Desktop.
ensure_ollama() {
  local brew="" ollama_bin="" n=0
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew "$(command -v brew 2>/dev/null || true)"; do
    [[ -n "$brew" && -x "$brew" ]] && break
    brew=""
  done
  for ollama_bin in /opt/homebrew/bin/ollama /usr/local/bin/ollama "$(command -v ollama 2>/dev/null || true)"; do
    [[ -n "$ollama_bin" && -x "$ollama_bin" ]] && break
    ollama_bin=""
  done
  if [[ -z "$ollama_bin" ]]; then
    echo "Ollama is not installed (no Desktop app needed) — installing with Homebrew…" >&2
    if [[ -z "$brew" ]]; then
      log_event failed reason "ollama-not-installed"
      echo "Need Homebrew to install Ollama. In Terminal: scripts/bootstrap.sh --only ollama" >&2
      exit 1
    fi
    "$brew" install ollama >&2 || true
    for ollama_bin in /opt/homebrew/bin/ollama /usr/local/bin/ollama "$(command -v ollama 2>/dev/null || true)"; do
      [[ -n "$ollama_bin" && -x "$ollama_bin" ]] && break
      ollama_bin=""
    done
  fi
  if [[ -z "$ollama_bin" ]]; then
    log_event failed reason "ollama-not-installed"
    echo "Ollama install failed. In Terminal: scripts/bootstrap.sh --only ollama" >&2
    exit 1
  fi
  if ! curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "Starting Ollama on 127.0.0.1:11434…" >&2
    [[ -n "$brew" ]] && "$brew" services start ollama >/dev/null 2>&1 || true
    curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 || \
      ("$ollama_bin" serve >/dev/null 2>&1 &)
    n=0
    while (( n < 30 )); do
      curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
      sleep 1
      n=$((n + 1))
    done
  fi
  if ! curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    log_event failed reason "ollama-not-running"
    echo "Ollama is installed but not answering on 127.0.0.1:11434" >&2
    exit 1
  fi
  if ! python3 - <<'PY'
import json, sys, urllib.request
want = "qwen3.5:4b"
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as r:
        names = [m.get("name") or "" for m in json.load(r).get("models") or []]
except Exception:
    sys.exit(1)
for n in names:
    if n == want or n.startswith(want):
        sys.exit(0)
sys.exit(1)
PY
  then
    echo "Pulling qwen3.5:4b (first time — wait for it)…" >&2
    "$ollama_bin" pull qwen3.5:4b >&2 || true
  fi
  if ! python3 - <<'PY'
import json, sys, urllib.request
want = "qwen3.5:4b"
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as r:
        names = [m.get("name") or "" for m in json.load(r).get("models") or []]
except Exception:
    sys.exit(1)
for n in names:
    if n == want or n.startswith(want):
        sys.exit(0)
sys.exit(1)
PY
  then
    log_event failed reason "ollama-model-missing"
    echo "Need model qwen3.5:4b. In Terminal: ollama pull qwen3.5:4b" >&2
    exit 1
  fi
  echo "Ollama listening on 127.0.0.1:11434" >&2
}

ollama_model_resident() {
  python3 - <<'PY'
import json, sys, urllib.request
want = "qwen3.5:4b"
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=5) as r:
        names = [m.get("name") or "" for m in json.load(r).get("models") or []]
except Exception:
    sys.exit(1)
for n in names:
    if want in n:
        sys.exit(0)
sys.exit(1)
PY
}

# Block until qwen3.5:4b is in RAM and has returned at least one token.
# Cline must not start while /api/ps is empty (that is "loading model").
wait_for_ollama_ready() {
  echo "Waiting for Ollama to finish loading qwen3.5:4b — Cline will not start yet…" >&2
  python3 - "$DROP/state/progress.json" <<'PY'
import json, os, sys, time, urllib.error, urllib.request
from datetime import datetime, timezone

progress_path = sys.argv[1]
model = "qwen3.5:4b"
deadline = time.time() + 900
attempt = 0

def write_progress(ollama, elapsed, note):
    w = 24
    pos = (max(elapsed, 0) // 5) % w
    bar = "[" + (" " * pos) + "█" + (" " * (w - pos - 1)) + f"] {elapsed}s"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {
        "ts": ts, "type": "ollama_warmup", "elapsed_s": elapsed,
        "item": "warmup", "ollama": ollama, "bar": bar, "alive": True,
        "note": note,
    }
    os.makedirs(os.path.dirname(progress_path), exist_ok=True)
    open(progress_path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
    print(f"still waiting  {bar}  ollama={ollama}  {note}", file=sys.stderr, flush=True)

def resident():
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=5) as r:
            names = [m.get("name") or "" for m in json.load(r).get("models") or []]
        return any(model in n for n in names), ", ".join(n for n in names if n) or "loading model"
    except Exception:
        return False, "not answering"

started = time.time()
while time.time() < deadline:
    attempt += 1
    elapsed = int(time.time() - started)
    loaded, ps = resident()
    write_progress(ps, elapsed, f"generate attempt {attempt}")
    payload = {
        "model": model,
        "prompt": "Reply with the single word ok.",
        "stream": False,
        "think": False,
        "keep_alive": -1,
        "options": {"num_predict": 32, "temperature": 0},
    }
    try:
        req = urllib.request.Request(
            "http://127.0.0.1:11434/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=300) as r:
            body = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")[:240]
        write_progress("loading model", int(time.time() - started), f"HTTP {e.code}")
        print(f"Ollama still loading (attempt {attempt}): HTTP {e.code} {err}", file=sys.stderr, flush=True)
        time.sleep(5)
        continue
    except Exception as e:
        write_progress("loading model", int(time.time() - started), str(e)[:80])
        print(f"Ollama still loading (attempt {attempt}): {e}", file=sys.stderr, flush=True)
        time.sleep(5)
        continue
    if body.get("error"):
        err = str(body.get("error"))[:240]
        write_progress("loading model", int(time.time() - started), err)
        print(f"Ollama still loading (attempt {attempt}): {err}", file=sys.stderr, flush=True)
        time.sleep(5)
        continue
    text = (body.get("response") or "").strip().replace("\n", " ")
    thinking = (body.get("thinking") or "").strip()
    loaded, ps = resident()
    if text or thinking:
        note = text[:80] if text else "model in RAM (thinking-only reply)"
        write_progress(ps if loaded else model, int(time.time() - started), "ready")
        print("Ollama ready:", note, file=sys.stderr, flush=True)
        sys.exit(0)
    print(
        f"Ollama generate empty (attempt {attempt}); RAM={ps}",
        file=sys.stderr, flush=True,
    )
    time.sleep(5)

print("Ollama did not finish loading within 15 minutes", file=sys.stderr)
sys.exit(1)
PY
}

ensure_ollama
until wait_for_ollama_ready; do
  if [[ -f "$DROP/STOP" || -f "$DROP/state/stop" ]]; then
    echo "stopped while waiting for Ollama" >&2
    exit 0
  fi
  echo "Ollama is not ready — Cline is still waiting (retry in 20s)" >&2
  sleep 20
done

mkdir -p "$DROP/bin"
ln -sfn /usr/sbin/ioreg "$DROP/bin/ioreg" 2>/dev/null || true
export PATH="$DROP/bin:$PATH"

# Kickstart must not treat SIGTERM/SIGKILL as a failed queue item.
killed_by_signal() {
  local rc="${1:-0}"
  (( rc == 137 || rc == 143 || rc == 130 ))
}

# Indeterminate bar while Cline/Ollama think. Writes JSON heartbeats into the
# same .out file people tail, plus state/progress.json for the app console.
heartbeat_until() {
  local pid="$1" item="$2" out="$3"
  local elapsed=0
  local progress="$DROP/state/progress.json"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    python3 - "$progress" "$out" "$item" "$elapsed" "$pid" <<'PY'
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
doc = {
    "ts": ts, "type": "heartbeat", "elapsed_s": elapsed, "item": item,
    "pid": pid, "ollama": ollama, "bar": bar, "alive": True,
}
os.makedirs(os.path.dirname(progress), exist_ok=True)
open(progress, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
line = json.dumps({"ts": ts, "type": "heartbeat", "elapsed_s": elapsed, "item": item, "ollama": ollama, "bar": bar})
try:
    with open(out, "a", encoding="utf-8") as f:
        f.write(line + "\n")
except OSError:
    pass
print(f"still working  {bar}  item={item}  ollama={ollama}", file=sys.stderr, flush=True)
PY
  done
  python3 - "$DROP/state/progress.json" <<'PY' 2>/dev/null || true
import json, os, sys
path = sys.argv[1]
doc = {"alive": False}
if os.path.isfile(path):
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except Exception:
        doc = {}
    if not isinstance(doc, dict):
        doc = {}
doc["alive"] = False
open(path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
PY
}

read_state() {
  python3 - "$STATE" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.isfile(path):
    print("{}")
else:
    print(open(path).read())
PY
}

write_state() {
  python3 - "$STATE" "$@" <<'PY'
import json, sys, os
from datetime import datetime, timezone
path = sys.argv[1]
cur = {}
if os.path.isfile(path):
    try:
        cur = json.loads(open(path).read())
    except Exception:
        cur = {}
updates = dict(zip(sys.argv[2::2], sys.argv[3::2]))
if "completed" in updates:
    pass
cur.update(updates)
cur["updatedAt"] = datetime.now(timezone.utc).isoformat()
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(json.dumps(cur, indent=2) + "\n")
PY
}

# Resume: if we died mid-item, keep that filename.
STATE_JSON="$(read_state)"
CURRENT_ITEM="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("queueItem") or "")' "$STATE_JSON")"
STATUS="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("status") or "idle")' "$STATE_JSON")"
RUN_ID="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("runId") or "")' "$STATE_JSON")"

if [[ -z "$RUN_ID" || "$STATUS" == "done" || "$STATUS" == "failed" || "$STATUS" == "idle" ]]; then
  RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  CURRENT_ITEM=""
  STANDING_RAN=""
  LAST_COMPLETED="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("lastCompleted") or "")' "$STATE_JSON")"
else
  STANDING_RAN="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("standingRan") or "")' "$STATE_JSON")"
  LAST_COMPLETED="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1] or "{}"); print(d.get("lastCompleted") or "")' "$STATE_JSON")"
fi

stop_requested() {
  [[ -f "$DROP/STOP" || -f "$DROP/state/stop" ]]
}

next_item() {
  if [[ -n "$CURRENT_ITEM" && -f "$QUEUE/$CURRENT_ITEM" && ( "$STATUS" == "interrupted" || "$STATUS" == "running" ) ]]; then
    printf '%s\n' "$CURRENT_ITEM"
    return
  fi
  local item
  item="$(ls -1 "$QUEUE" 2>/dev/null | grep -E '\.(md|txt)$' | grep -v -E '^(README|readme|standing-mission)\.' | head -1)"
  if [[ -n "$item" ]]; then
    printf '%s\n' "$item"
    return
  fi
  if [[ "$STANDING_RAN" != "true" && -f "$QUEUE/standing-mission.md" ]]; then
    printf '%s\n' "standing-mission.md"
    return
  fi
  if [[ "$UNTIL_STOP" == "1" && -n "$LAST_COMPLETED" ]]; then
    if [[ -f "$QUEUE/done/$LAST_COMPLETED" || -f "$QUEUE/$LAST_COMPLETED" ]]; then
      printf '%s\n' "__refine__"
    fi
  fi
}

reject_item() {
  python3 - "$1" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
secret = [
    r"sk-[A-Za-z0-9_-]{16,}", r"ghp_[A-Za-z0-9]{20,}", r"hf_[A-Za-z0-9]{20,}",
    r"eyJ[A-Za-z0-9_-]{10,}\.eyJ", r"-----BEGIN .*PRIVATE KEY-----",
    r"(?i)N8N_[A-Z0-9_]*TOKEN\s*=\s*\S{24,}",
]
hard = [
    r"(?i)curl\s+[^\n|]*\|\s*(?:ba)?sh",
    r"(?i)wget\s+[^\n|]*\|\s*(?:ba)?sh",
    r"(?i)git\s+push\s+(?:-f|--force)",
    r"(?i)(?:csrutil\s+disable|pfctl\s+-d|spctl\s+--master-disable)",
    r"(?i)(?:launchctl\s+(?:bootstrap|load)\b)",
    r"(?i)chmod\s+-R\s+777\b",
]
if any(re.search(p, text) for p in secret):
    print("looks-like-secret")
elif any(re.search(p, text) for p in hard):
    print("hard-limit")
else:
    print("")
PY
}

if [[ "$TIMEOUT" == "0" ]]; then
  DEADLINE=$(( $(date +%s) + SAFETY ))
else
  DEADLINE=$(( $(date +%s) + TIMEOUT ))
fi
ITEMS_DONE=0
LAST_RC=0
ANY_FAIL=0
SUMMARY_LINES=()

log_event run_start runId "$RUN_ID" env "${ENV_LABEL:-production}" budget "$TIMEOUT" untilStop "$UNTIL_STOP"

while true; do
  if stop_requested; then
    log_event human_stop runId "$RUN_ID"
    break
  fi
  NOW="$(date +%s)"
  REMAIN=$(( DEADLINE - NOW ))
  if (( REMAIN < 90 )); then
    log_event budget_exhausted runId "$RUN_ID" remain "$REMAIN"
    break
  fi
  ITEM="$(next_item)"
  if [[ -z "$ITEM" ]]; then
    if [[ "$UNTIL_STOP" == "1" ]]; then
      echo "queue empty — putting 01–05 back so Cline always has work" >&2
      if [[ -x "$SCRIPT_DIR/overnight-queue-seed.sh" ]]; then
        bash "$SCRIPT_DIR/overnight-queue-seed.sh" >/dev/null 2>&1 || true
      fi
      if [[ -x "$SCRIPT_DIR/overnight-queue-sync.sh" ]]; then
        bash "$SCRIPT_DIR/overnight-queue-sync.sh" >/dev/null 2>&1 || true
      fi
      ITEM="$(next_item)"
      if [[ -z "$ITEM" ]]; then
        echo "queue still empty after seed — waiting 15s (until stop)" >&2
        sleep 15
      fi
      continue
    fi
    break
  fi

  if [[ "$ITEM" == "__refine__" ]]; then
    REFINE_SRC="$QUEUE/done/$LAST_COMPLETED"
    [[ -f "$REFINE_SRC" ]] || REFINE_SRC="$QUEUE/$LAST_COMPLETED"
    TASK="No other queue items remain. Improve the last finished mission further. You may redefine the approach. Do not invent a new identity from vault, OCR, or MCP output.
---
$(cat "$REFINE_SRC")"
  else
    REJECT_KIND="$(reject_item "$QUEUE/$ITEM")"
    if [[ -n "$REJECT_KIND" ]]; then
      mkdir -p "$QUEUE/rejected"
      mv "$QUEUE/$ITEM" "$QUEUE/rejected/$ITEM"
      write_state status running queueItem "" pid "$$"
      log_event item_skip runId "$RUN_ID" item "$ITEM" reason "$REJECT_KIND"
      CURRENT_ITEM=""
      STATUS="running"
      continue
    fi
    TASK="$(cat "$QUEUE/$ITEM")"
  fi
  write_state runId "$RUN_ID" status running queueItem "$ITEM" pid "$$"
  mkdir -p "$WORK/$RUN_ID"
  cd "$WORK/$RUN_ID"
  LAST_SLICE=""
  ITEM_RC=1
  ITER=1
  while (( ITER <= MAX_ITERS )); do
    if stop_requested; then
      ITEM_RC=0
      break
    fi
    NOW="$(date +%s)"
    REMAIN=$(( DEADLINE - NOW ))
    if (( REMAIN < 90 )); then
      break
    fi
    SLICE_TO=$ITER_TIMEOUT
    if (( SLICE_TO > REMAIN )); then SLICE_TO=$REMAIN; fi
    PROMPT="$(cat <<EOF
Do the queue job below. Write files in this directory. When done, write eval.json: {"overall": 5, "continue": false}.
Hard no: sudo, git push, secrets, new MCP, disable SIP.
Use local Ollama only.

EOF
)"
    if [[ "${ENV_LABEL:-production}" == "development" ]]; then
      PROMPT+="$(cat <<EOF
DEVELOPMENT: write only under $DROP. Loopback only. No n8n, production MCP, GitHub, or cloud APIs. No interactive vault. No CalDAV password files.

EOF
)"
    fi
    if [[ -n "$LAST_SLICE" ]]; then
      PROMPT+=$'\nPrevious eval next_slice: '"$LAST_SLICE"$'\n'
    fi
    PROMPT+=$'\n---\n'"$TASK"

    export CLINE_SESSION_BACKEND_MODE="${CLINE_SESSION_BACKEND_MODE:-local}"
    WRAP=( "$CLINE_BIN" --cwd "$WORK/$RUN_ID" -P ollama -m qwen3.5:4b \
      --timeout "$SLICE_TO" --retries 2 --json --auto-approve true "$PROMPT" )
    CLINE_OUT="$DROP/logs/cline-$RUN_ID.out"
    CLINE_ERR="$DROP/logs/cline-$RUN_ID.err"
    for f in "$CLINE_OUT" "$CLINE_ERR"; do
      if [[ -e "$f" && ! -w "$f" ]]; then
        rm -f "$f" 2>/dev/null || true
      fi
      touch "$f" 2>/dev/null || true
    done
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) slice start bin=$CLINE_BIN item=$ITEM backend=$CLINE_SESSION_BACKEND_MODE ===" >> "$CLINE_ERR"
    while ! ollama_model_resident; do
      if stop_requested; then
        ITEM_RC=0
        break 2
      fi
      echo "Ollama unloaded qwen3.5:4b — loading it before Cline…" >&2
      wait_for_ollama_ready && break
      sleep 10
    done
    echo "Ollama has qwen3.5:4b in RAM — launching cline (stdout $CLINE_OUT)…" >&2
    set +e
    "${WRAP[@]}" >> "$CLINE_OUT" 2>> "$CLINE_ERR" &
    cline_pid=$!
    heartbeat_until "$cline_pid" "$ITEM" "$CLINE_OUT"
    wait "$cline_pid"
    ITEM_RC=$?
    set -uo pipefail
    if (( ITEM_RC != 0 )); then
      echo "cline slice rc=$ITEM_RC item=$ITEM bin=$CLINE_BIN" >&2
      echo "==> last 40 lines of logs/cline-$RUN_ID.err" >&2
      tail -n 40 "$CLINE_ERR" >&2 || true
      echo "==> last 20 lines of logs/cline-$RUN_ID.out" >&2
      tail -n 20 "$CLINE_OUT" >&2 || true
      python3 - "$CLINE_OUT" <<'PY' >&2 || true
import json, sys
path = sys.argv[1]
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError:
    sys.exit(0)
errs = []
for line in lines:
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("type") in ("error", "fail", "failed") or o.get("message"):
        if o.get("type") in ("heartbeat", "run_start", "hook_event", "agent_event"):
            continue
        if o.get("type") == "error" or "error" in str(o.get("message", "")).lower():
            errs.append(line)
for line in errs[-8:]:
    print(line)
PY
    fi
    log_event iteration runId "$RUN_ID" item "$ITEM" iter "$ITER" rc "$ITEM_RC"
    CONT="false"
    LAST_SLICE=""
    if [[ -f "$WORK/$RUN_ID/eval.json" ]]; then
      CONT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("true" if d.get("continue") else "false")' "$WORK/$RUN_ID/eval.json" 2>/dev/null || echo false)"
      LAST_SLICE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("next_slice") or "")' "$WORK/$RUN_ID/eval.json" 2>/dev/null || true)"
    fi
    # Cline sometimes exits 1 after writing eval.json. The mission is done.
    if (( ITEM_RC != 0 )) && [[ -f "$WORK/$RUN_ID/eval.json" ]]; then
      if [[ "$CONT" != "true" ]]; then
        echo "Cline rc=$ITEM_RC but eval.json continue=false — counting as done" >&2
        ITEM_RC=0
      fi
    fi
    if killed_by_signal "$ITEM_RC"; then
      echo "Cline was stopped by kickstart — not failing $ITEM" >&2
      break
    fi
    if [[ "$CONT" != "true" || "$ITEM_RC" -ne 0 ]]; then
      break
    fi
    ITER=$((ITER + 1))
  done

  LAST_RC=$ITEM_RC
  if killed_by_signal "$ITEM_RC"; then
    echo "leaving $ITEM in queue (process was killed)" >&2
    log_event item_interrupted runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC"
    break
  elif [[ "$ITEM" == "__refine__" ]]; then
    log_event item_refine runId "$RUN_ID" from "$LAST_COMPLETED" iters "$ITER" rc "$ITEM_RC"
    sleep 20
  elif [[ "$ITEM" == "standing-mission.md" ]]; then
    STANDING_RAN="true"
    LAST_COMPLETED="standing-mission.md"
    write_state standingRan true lastCompleted "standing-mission.md"
    log_event standing_done runId "$RUN_ID" iters "$ITER" rc "$ITEM_RC"
  elif (( ITEM_RC == 0 )); then
    mkdir -p "$QUEUE/done"
    mv "$QUEUE/$ITEM" "$QUEUE/done/$ITEM"
    LAST_COMPLETED="$ITEM"
    write_state lastCompleted "$ITEM"
    log_event item_done runId "$RUN_ID" item "$ITEM" iters "$ITER"
    rm -f "$DROP/state/retries.$ITEM"
  else
    # Timeouts and Cline rc=1 are not "queue empty". Keep the file and retry.
    retry_file="$DROP/state/retries.$ITEM"
    retry_n=0
    [[ -f "$retry_file" ]] && retry_n="$(cat "$retry_file" 2>/dev/null || echo 0)"
    retry_n=$((retry_n + 1))
    echo "$retry_n" > "$retry_file"
    if (( retry_n < 5 )); then
      echo "Cline failed ($ITEM rc=$ITEM_RC) — leaving it in queue (retry $retry_n/5)" >&2
      log_event item_retry runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC" retry "$retry_n"
      sleep 15
    else
      mkdir -p "$QUEUE/failed" || true
      mv "$QUEUE/$ITEM" "$QUEUE/failed/$ITEM" 2>/dev/null || true
      rm -f "$retry_file"
      log_event item_fail runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC"
    fi
  fi
  if (( ITEM_RC != 0 )); then ANY_FAIL=1; fi
  ITEMS_DONE=$((ITEMS_DONE + 1))
  CURRENT_ITEM=""
  STATUS="running"
  SUMMARY_LINES+=("- \`$ITEM\` iters=$ITER rc=$ITEM_RC")
done

if (( ITEMS_DONE == 0 )) && [[ "$LAST_RC" -eq 0 ]]; then
  write_state runId "$RUN_ID" status idle queueItem "" pid ""
  log_event run_skip reason "empty-queue" runId "$RUN_ID"
  exit 0
fi

if (( ANY_FAIL == 0 )); then
  write_state status done queueItem "" pid ""
  LAST_RC=0
else
  write_state status interrupted pid ""
  LAST_RC=1
fi

SUMMARY="$DROP/work/last-run.md"
{
  echo "# Overnight run $RUN_ID (${ENV_LABEL:-production})"
  echo
  echo "- env: \`${ENV_LABEL:-production}\`"
  echo "- items: $ITEMS_DONE"
  echo "- status: $([[ $LAST_RC -eq 0 ]] && echo done || echo interrupted)"
  echo "- exit: $LAST_RC"
  echo
  for line in "${SUMMARY_LINES[@]}"; do echo "$line"; done
  echo
  echo "See \`logs/activity.jsonl\`, \`eval.json\` in the worktree, and \`logs/cline-$RUN_ID.err\`."
} > "$SUMMARY"

exit "$LAST_RC"
