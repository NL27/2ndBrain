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
VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
VAULT_QUEUE="$VAULT/Notes/Overnight/queue"
STATE="$DROP/state/current.json"
LOG="$DROP/logs/activity.jsonl"
EVENTS="$DROP/logs/overnight.events.log"
TIMINGS="$DROP/logs/timings.jsonl"
QUEUE="$DROP/queue"
WORK="$DROP/work"
OVERNIGHT_WORK="$DROP/overnight work"
CLINE_DATA="$DROP/state/cline-data"
CLINE_BIN="${CLINE_BIN:-}"
TIMEOUT="${OVERNIGHT_BUDGET:-${TIMEOUT_DEFAULT:-0}}"
ITER_TIMEOUT="${OVERNIGHT_ITER_TIMEOUT:-${ITER_TIMEOUT_DEFAULT:-28800}}"
MAX_ITERS="${OVERNIGHT_MAX_ITERS:-${MAX_ITERS_DEFAULT:-8}}"
SAFETY="${OVERNIGHT_SAFETY:-${SAFETY_DEFAULT:-604800}}"
UNTIL_STOP="${OVERNIGHT_UNTIL_STOP:-${UNTIL_STOP_DEFAULT:-1}}"

mkdir -p "$DROP/logs" "$DROP/state" "$WORK" "$OVERNIGHT_WORK" "$QUEUE"
: >> "$EVENTS" "$TIMINGS"

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
pkill -f "cline --cwd ${OVERNIGHT_WORK}/" 2>/dev/null || true
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
# Isolated --data-dir so overnight does not inherit a 900ms timeout from ~/.cline.
ensure_ollama_provider() {
  python3 - "$1" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(sys.argv[1])
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
base = "http://127.0.0.1:11434"
# Cline treats provider "timeout" as milliseconds. 900 was 0.9s and aborted every call.
timeout_ms = 14_400_000  # 4 hours
ollama = {
    "settings": {
        "provider": "ollama",
        "model": "qwen3.5:4b",
        "baseUrl": base,
        "ollamaBaseUrl": base,
        "ollamaModelId": "qwen3.5:4b",
        "timeout": timeout_ms,
        "requestTimeout": timeout_ms,
        "requestTimeoutMs": timeout_ms,
        "timeoutMs": timeout_ms,
        "ollamaTimeoutMs": timeout_ms,
    },
    "updatedAt": now,
    "tokenSource": "manual",
}
prov_path = root / "settings" / "providers.json"
doc = {"version": 1, "providers": {}}
if prov_path.is_file():
    try:
        loaded = json.loads(prov_path.read_text(encoding="utf-8"))
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
prov_path.parent.mkdir(parents=True, exist_ok=True)
prov_path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

for rel in ("globalState.json", "settings/global-settings.json"):
    path = root / rel
    extra = {}
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                extra = loaded
        except Exception:
            extra = {}
    extra["requestTimeoutMs"] = timeout_ms
    extra["ollamaRequestTimeoutMs"] = timeout_ms
    extra["timeout"] = timeout_ms
    extra["timeoutMs"] = timeout_ms
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(extra, indent=2) + "\n", encoding="utf-8")
print(timeout_ms)
PY
}
ensure_ollama_provider "${HOME}/.cline/data" >/dev/null
OLLAMA_TIMEOUT_MS="$(ensure_ollama_provider "$CLINE_DATA")"
OLLAMA_TIMEOUT_MS="${OLLAMA_TIMEOUT_MS:-14400000}"
echo "Cline Ollama request timeout is $(( OLLAMA_TIMEOUT_MS / 60000 )) minutes ($OLLAMA_TIMEOUT_MS ms) via $CLINE_DATA" >&2
CLINE_DATA_ARGS=()
if "$CLINE_BIN" --help 2>&1 | grep -q -- '--data-dir'; then
  CLINE_DATA_ARGS=( --data-dir "$CLINE_DATA" )
else
  echo "Cline has no --data-dir flag — timeout was also written to ~/.cline/data" >&2
fi

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
started = time.time()

def write_progress(ollama, elapsed, note):
    s = max(0, int(elapsed))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    clock = f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc = {
        "ts": ts, "type": "ollama_warmup", "elapsed_s": s, "clock": clock,
        "item": "warmup", "part": "load", "ollama": ollama, "alive": True,
        "note": note, "started_at": int(started),
    }
    os.makedirs(os.path.dirname(progress_path), exist_ok=True)
    open(progress_path, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")

def resident():
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=5) as r:
            names = [m.get("name") or "" for m in json.load(r).get("models") or []]
        return any(model in n for n in names), ", ".join(n for n in names if n) or "loading model"
    except Exception:
        return False, "not answering"

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

fmt_hms() {
  python3 -c 'import sys; s=max(0,int(sys.argv[1])); h=s//3600; m=(s%3600)//60; sec=s%60; print(f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}")' "${1:-0}"
}

log_timing() {
  python3 - "$TIMINGS" "$@" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
event = {"ts": datetime.now(timezone.utc).isoformat()}
event.update(dict(zip(sys.argv[2::2], sys.argv[3::2])))
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(event) + "\n")
PY
}

# One line per part/task change. Live elapsed is in progress.json (watch redraws it).
announce() {
  local line
  line="$(printf '%s' "$1")"
  shift || true
  {
    printf '%s\n' "$line"
    for extra in "$@"; do
      [[ -n "$extra" ]] && printf '  %s\n' "$extra"
    done
  } | tee -a "$EVENTS" >&2
}

queue_waiting() {
  ls -1 "$QUEUE" 2>/dev/null | grep -E '\.(md|txt)$' | grep -v -E '^(README|readme|standing-mission)\.' | tr '\n' ' '
}

peek_next_after() {
  local current="$1"
  ls -1 "$QUEUE" 2>/dev/null | grep -E '\.(md|txt)$' | grep -v -E '^(README|readme|standing-mission)\.' | grep -v -F -x "$current" | head -1
}

retire_queue_file() {
  local item="$1" bin="$2"
  mkdir -p "$QUEUE/$bin" "$VAULT_QUEUE/$bin"
  mv "$QUEUE/$item" "$QUEUE/$bin/$item" 2>/dev/null || true
  if [[ -f "$VAULT_QUEUE/$item" ]]; then
    mv "$VAULT_QUEUE/$item" "$VAULT_QUEUE/$bin/$item" 2>/dev/null || true
  fi
}

task_slug() {
  python3 -c '
import re, sys
s = re.sub(r"\.(md|txt)$", "", sys.argv[1], flags=re.I)
s = re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip("-.")
print(s or "task")
' "$1"
}

task_dir_for() {
  printf '%s/%s\n' "$OVERNIGHT_WORK" "$(task_slug "$1")"
}

write_overnight_index() {
  python3 - "$OVERNIGHT_WORK" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
lines = [
    "# Overnight work",
    "",
    "Each subfolder is one queue job. Every file Cline created for that job is inside it.",
    "",
]
for path in sorted(p for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")):
    lines.append(f"- [{path.name}]({path.name}/)")
lines.append("")
(root / "README.md").write_text("\n".join(lines), encoding="utf-8")
PY
}

# Keepers the job wrote to Shared vault-out (or Notes/ in the task folder)
# also land in overnight work/<task>/ so review is one place.
file_task_outputs() {
  local dir="$1" since="${2:-0}"
  mkdir -p "$WORK/vault-out/Notes" "$dir"
  if [[ -d "$dir/vault-out" ]]; then
    if command -v rsync >/dev/null; then
      rsync -a "$dir/vault-out/" "$WORK/vault-out/"
    else
      cp -R "$dir/vault-out/." "$WORK/vault-out/"
    fi
  fi
  if [[ -d "$dir/Notes" ]]; then
    if command -v rsync >/dev/null; then
      rsync -a "$dir/Notes/" "$WORK/vault-out/Notes/"
    else
      cp -R "$dir/Notes/." "$WORK/vault-out/Notes/"
    fi
  fi
  python3 - "$WORK/vault-out" "$dir/vault-out" "$since" <<'PY'
import shutil, sys
from pathlib import Path
src, dest, since_s = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
try:
    since = float(since_s)
except ValueError:
    since = 0.0
if not src.is_dir():
    raise SystemExit(0)
for path in src.rglob("*"):
    if not path.is_file():
        continue
    if since and path.stat().st_mtime + 1 < since:
        continue
    target = dest / path.relative_to(src)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, target)
PY
  write_overnight_index
}

# Live clock for watch: progress.json only — no new stderr line every 5s.
heartbeat_until() {
  local pid="$1" item="$2" out="$3" part="${4:-1}" started="${5:-}"
  local elapsed=0
  local progress="$DROP/state/progress.json"
  [[ -n "$started" ]] || started="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$(( $(date +%s) - started ))
    python3 - "$progress" "$item" "$elapsed" "$pid" "$part" "$MAX_ITERS" "$started" <<'PY'
import json, os, sys, urllib.request
from datetime import datetime, timezone
progress, item, elapsed, pid, part, max_iters, started = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4],
    sys.argv[5], sys.argv[6], int(sys.argv[7]),
)
s = max(0, elapsed)
h, rem = divmod(s, 3600)
m, sec = divmod(rem, 60)
clock = f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"
ollama = "idle"
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=1) as r:
        names = [m.get("name") or "" for m in json.load(r).get("models") or []]
        ollama = ", ".join(n for n in names if n) or "loading model"
except Exception:
    ollama = "not answering"
ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc = {
    "ts": ts, "type": "heartbeat", "elapsed_s": s, "clock": clock,
    "item": item, "part": part, "part_of": max_iters, "pid": pid,
    "started_at": started, "ollama": ollama, "alive": True,
}
os.makedirs(os.path.dirname(progress), exist_ok=True)
open(progress, "w", encoding="utf-8").write(json.dumps(doc, indent=2) + "\n")
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
PREV_TASK=""
TASK_T0=""
PART_SUMMARY=""

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
      if [[ -x "$SCRIPT_DIR/overnight-queue-sync.sh" ]]; then
        bash "$SCRIPT_DIR/overnight-queue-sync.sh" >/dev/null 2>&1 || true
      fi
      ITEM="$(next_item)"
      if [[ -z "$ITEM" ]]; then
        announce "QUEUE EMPTY  waiting for a new vault file (not repeating 01–05)"
        sleep 60
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
      announce "SKIP TASK  $ITEM" \
        "Rejected ($REJECT_KIND) — not running this file." \
        "Next queue file will be a different task."
      write_state status running queueItem "" pid "$$"
      log_event item_skip runId "$RUN_ID" item "$ITEM" reason "$REJECT_KIND"
      CURRENT_ITEM=""
      STATUS="running"
      continue
    fi
    TASK="$(cat "$QUEUE/$ITEM")"
  fi
  if [[ -n "$PREV_TASK" && "$ITEM" != "$PREV_TASK" ]]; then
    announce "→ TASK  $ITEM  (was $PREV_TASK)"
    TASK_T0="$(date +%s)"
    PART_SUMMARY=""
  elif [[ "$ITEM" == "$PREV_TASK" ]]; then
    announce "→ RETRY  $ITEM"
  else
    announce "→ TASK  $ITEM"
    TASK_T0="$(date +%s)"
    PART_SUMMARY=""
  fi
  PREV_TASK="$ITEM"
  write_state runId "$RUN_ID" status running queueItem "$ITEM" pid "$$"
  TASK_DIR="$(task_dir_for "$ITEM")"
  mkdir -p "$TASK_DIR"
  if [[ -f "$QUEUE/$ITEM" ]]; then
    cp -f "$QUEUE/$ITEM" "$TASK_DIR/_queue-job.md"
  elif [[ "$ITEM" == "__refine__" && -n "${REFINE_SRC:-}" && -f "$REFINE_SRC" ]]; then
    cp -f "$REFINE_SRC" "$TASK_DIR/_queue-job.md"
  fi
  write_overnight_index
  cd "$TASK_DIR"
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
Do the queue job below. Write every file in this directory (overnight work/$(task_slug "$ITEM")/). Do not write into other task folders.
This is slice $ITER of up to $MAX_ITERS on the SAME queue file. Finish as much Done when as you can this slice, then stop and write eval.json:
{"overall": 1-5, "continue": true or false, "done_when_complete": true or false, "next_slice": "one sentence"}
- continue true and done_when_complete false if any Done when line is still unmet (the runner will start slice $((ITER + 1)) on this same file)
- continue false and done_when_complete true ONLY when every Done when line is actually met
If the job names work/vault-out/..., write those keepers here and copy them to $DROP/work/vault-out/Notes/ so the vault can file them.
Do not mark the job complete after a first draft. Hard no: sudo, git push, secrets, new MCP, disable SIP.
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
    export CLINE_REQUEST_TIMEOUT_MS="${OLLAMA_TIMEOUT_MS:-14400000}"
    WRAP=( "$CLINE_BIN" --cwd "$TASK_DIR" "${CLINE_DATA_ARGS[@]}" \
      -P ollama -m qwen3.5:4b \
      --timeout "$SLICE_TO" --retries 2 --thinking none --json --auto-approve true "$PROMPT" )
    CLINE_OUT="$TASK_DIR/cline.out"
    CLINE_ERR="$TASK_DIR/cline.err"
    for f in "$CLINE_OUT" "$CLINE_ERR"; do
      if [[ -e "$f" && ! -w "$f" ]]; then
        rm -f "$f" 2>/dev/null || true
      fi
      touch "$f" 2>/dev/null || true
    done
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) slice start bin=$CLINE_BIN item=$ITEM backend=$CLINE_SESSION_BACKEND_MODE ===" >> "$CLINE_ERR"
    announce "→ SLICE  $ITEM  $ITER of up to $MAX_ITERS"
    PART_T0="$(date +%s)"
    while ! ollama_model_resident; do
      if stop_requested; then
        ITEM_RC=0
        break 2
      fi
      announce "  loading Ollama before Cline…"
      wait_for_ollama_ready && break
      sleep 10
    done
    set +e
    "${WRAP[@]}" >> "$CLINE_OUT" 2>> "$CLINE_ERR" &
    cline_pid=$!
    heartbeat_until "$cline_pid" "$ITEM" "$CLINE_OUT" "$ITER" "$PART_T0"
    wait "$cline_pid"
    ITEM_RC=$?
    set -uo pipefail
    if (( ITEM_RC != 0 )); then
      echo "cline slice rc=$ITEM_RC item=$ITEM bin=$CLINE_BIN" >&2
      echo "==> last 40 lines of overnight work/$(task_slug "$ITEM")/cline.err" >&2
      tail -n 40 "$CLINE_ERR" >&2 || true
      echo "==> last 20 lines of overnight work/$(task_slug "$ITEM")/cline.out" >&2
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
    CONT="true"
    LAST_SLICE=""
    DONE_WHEN="false"
    if [[ -f "$TASK_DIR/eval.json" ]]; then
      CONT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("true" if d.get("continue") else "false")' "$TASK_DIR/eval.json" 2>/dev/null || echo true)"
      DONE_WHEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("true" if d.get("done_when_complete") else "false")' "$TASK_DIR/eval.json" 2>/dev/null || echo false)"
      LAST_SLICE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("next_slice") or "")' "$TASK_DIR/eval.json" 2>/dev/null || true)"
    fi
    # A 4B model often writes continue false after a first draft. Keep slicing
    # until Done when is actually marked complete or we hit the cap.
    # Never retire a job after only slice 1 — the old WRAP prompt taught the
    # model to emit continue false immediately.
    if [[ "$ITER" -eq 1 && "$ITER" -lt "$MAX_ITERS" ]]; then
      if [[ "$DONE_WHEN" == "true" || "$CONT" != "true" ]]; then
        announce "  slice 1 is never the last slice — starting slice 2 on $ITEM"
      fi
      DONE_WHEN="false"
      CONT="true"
    fi
    if [[ "$DONE_WHEN" != "true" && "$ITER" -lt "$MAX_ITERS" ]]; then
      if [[ "$CONT" != "true" ]]; then
        announce "  slice $ITER said it was done, but Done when is not complete — starting the next slice on $ITEM"
      fi
      CONT="true"
    fi
    if [[ "$ITER" -ge "$MAX_ITERS" ]]; then
      CONT="false"
    fi
    # Cline sometimes exits 1 after writing eval.json.
    if (( ITEM_RC != 0 )); then
      if [[ "$CONT" == "true" ]]; then
        echo "Cline rc=$ITEM_RC — keeping $ITEM for the next slice" >&2
        ITEM_RC=0
      elif [[ -f "$TASK_DIR/eval.json" ]]; then
        echo "Cline rc=$ITEM_RC but this was the last slice — counting as done" >&2
        ITEM_RC=0
      fi
    fi
    if killed_by_signal "$ITEM_RC"; then
      echo "Cline was stopped by kickstart — not failing $ITEM" >&2
      break
    fi
    PART_SEC=$(( $(date +%s) - PART_T0 ))
    PART_HMS="$(fmt_hms "$PART_SEC")"
    log_timing kind part item "$ITEM" part "$ITER" seconds "$PART_SEC" rc "$ITEM_RC"
    PART_SUMMARY="${PART_SUMMARY:+$PART_SUMMARY, }slice $ITER ${PART_HMS}"
    file_task_outputs "$TASK_DIR" "${TASK_T0:-0}"
    if [[ "$CONT" == "true" && "$ITEM_RC" -eq 0 ]]; then
      announce "✓ SLICE  $ITEM  $ITER of up to $MAX_ITERS  $PART_HMS  (same task continues)"
      ITER=$((ITER + 1))
      continue
    fi
    if [[ "$ITEM_RC" -eq 0 ]]; then
      announce "✓ SLICE  $ITEM  $ITER of up to $MAX_ITERS  $PART_HMS  (Done when complete or last slice)"
    else
      announce "✗ SLICE  $ITEM  $ITER of up to $MAX_ITERS  $PART_HMS  rc=$ITEM_RC"
    fi
    break
  done

  file_task_outputs "$TASK_DIR" "${TASK_T0:-0}"
  if [[ -x "$SCRIPT_DIR/overnight-queue-sync.sh" ]]; then
    bash "$SCRIPT_DIR/overnight-queue-sync.sh" >/dev/null 2>&1 || true
  fi

  LAST_RC=$ITEM_RC
  TASK_SEC=$(( $(date +%s) - ${TASK_T0:-$(date +%s)} ))
  TASK_HMS="$(fmt_hms "$TASK_SEC")"
  if killed_by_signal "$ITEM_RC"; then
    announce "STOPPED  $ITEM  after $TASK_HMS"
    echo "leaving $ITEM in queue (process was killed)" >&2
    log_event item_interrupted runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC"
    break
  elif [[ "$ITEM" == "__refine__" ]]; then
    announce "REFINE  $LAST_COMPLETED  $TASK_HMS"
    log_event item_refine runId "$RUN_ID" from "$LAST_COMPLETED" iters "$ITER" rc "$ITEM_RC"
    sleep 20
  elif [[ "$ITEM" == "standing-mission.md" ]]; then
    STANDING_RAN="true"
    LAST_COMPLETED="standing-mission.md"
    write_state standingRan true lastCompleted "standing-mission.md"
    log_event standing_done runId "$RUN_ID" iters "$ITER" rc "$ITEM_RC"
    announce "✓ STANDING  $TASK_HMS"
  elif (( ITEM_RC == 0 )); then
    next_file="$(peek_next_after "$ITEM")"
    retire_queue_file "$ITEM" done
    LAST_COMPLETED="$ITEM"
    write_state lastCompleted "$ITEM"
    log_event item_done runId "$RUN_ID" item "$ITEM" iters "$ITER" seconds "$TASK_SEC"
    log_timing kind task item "$ITEM" seconds "$TASK_SEC" parts "$PART_SUMMARY"
    rm -f "$DROP/state/retries.$ITEM"
    if [[ -n "$next_file" ]]; then
      announce "✓ TASK  $ITEM  $TASK_HMS  ($PART_SUMMARY)  next: $next_file"
    else
      announce "✓ TASK  $ITEM  $TASK_HMS  ($PART_SUMMARY)"
    fi
  else
    retry_file="$DROP/state/retries.$ITEM"
    retry_n=0
    [[ -f "$retry_file" ]] && retry_n="$(cat "$retry_file" 2>/dev/null || echo 0)"
    retry_n=$((retry_n + 1))
    echo "$retry_n" > "$retry_file"
    if (( retry_n < 5 )); then
      announce "✗ PART  $ITEM  retry $retry_n/5  after $TASK_HMS so far"
      echo "Cline failed ($ITEM rc=$ITEM_RC) — leaving it in queue (retry $retry_n/5)" >&2
      log_event item_retry runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC" retry "$retry_n"
      sleep 15
    else
      next_file="$(peek_next_after "$ITEM")"
      retire_queue_file "$ITEM" failed
      rm -f "$retry_file"
      log_event item_fail runId "$RUN_ID" item "$ITEM" rc "$ITEM_RC" seconds "$TASK_SEC"
      announce "✗ TASK  $ITEM  failed after $TASK_HMS  ($PART_SUMMARY)" \
        "${next_file:+next: $next_file}"
    fi
  fi
  if (( ITEM_RC != 0 )); then ANY_FAIL=1; fi
  ITEMS_DONE=$((ITEMS_DONE + 1))
  CURRENT_ITEM=""
  STATUS="running"
  SUMMARY_LINES+=("- \`$ITEM\` ${TASK_HMS} (${PART_SUMMARY:-parts n/a}) rc=$ITEM_RC — \`overnight work/$(task_slug "$ITEM")/\`")
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
  echo "- work: \`overnight work/\` (one subfolder per queue job)"
  echo
  for line in "${SUMMARY_LINES[@]}"; do echo "$line"; done
  echo
  echo "Open \`/Users/Shared/2nd-Brain-Night/overnight work/\` or vault \`Notes/Overnight/overnight work/\`."
} > "$SUMMARY"
mkdir -p "$OVERNIGHT_WORK"
cp -f "$SUMMARY" "$OVERNIGHT_WORK/last-run.md" 2>/dev/null || true
if [[ -x "$SCRIPT_DIR/overnight-queue-sync.sh" ]]; then
  bash "$SCRIPT_DIR/overnight-queue-sync.sh" >/dev/null 2>&1 || true
fi

exit "$LAST_RC"
