#!/usr/bin/env bash
# 2ⁿᵈ Brain bootstrap — installs every local engine and model the app needs, so
# that afterwards it runs entirely on this machine with no network.
#
# The app runs this on first launch and parses the STEP| lines below; it is also
# safe to run by hand. Every step is idempotent: already-installed pieces are
# detected and skipped. Downloads resume after a dropped connection (.part files,
# curl -C -, Hugging Face cache). Re-run setup to finish only what is still missing.
#
# Usage:
#   scripts/bootstrap.sh                 # install everything that's missing
#   scripts/bootstrap.sh --check         # report status only, install nothing
#   scripts/bootstrap.sh --only tiron    # run a subset (comma-separated ids)
#   scripts/bootstrap.sh --with-ollama   # Ollama + qwen3.5:4b + qwen2.5-coder:7b
#   scripts/bootstrap.sh --model small.en
#
# Machine-readable progress, one line per state change:
#   STEP|<id>|<checking|installing|ok|skipped|manual|failed>|<message>
#   DONE|<ok|incomplete>|<message>
set -uo pipefail   # deliberately not -e: an optional step failing must not abort

MODE="install"
ONLY=""
WITH_OLLAMA=0
MODEL=""
SUPPORT="$HOME/Library/Application Support/SecondBrain"
BIN_DIR="$SUPPORT/bin"
# Helper scripts sit beside this one, both in the repo and inside the app bundle.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_BRAIN_DIR="$HOME/Desktop/2nd Brain"
DESKTOP_SKILLS_DIR="$DESKTOP_BRAIN_DIR/Agent Skills"
DESKTOP_THINKING_DIR="$DESKTOP_SKILLS_DIR/thinking"
DESKTOP_WORKSPACE="$DESKTOP_BRAIN_DIR/2nd Brain.code-workspace"
LEGACY_DESKTOP_SKILLS="$HOME/Desktop/Second Brain Agent Skills"
LEGACY_DESKTOP_WORKSPACE="$HOME/Desktop/Second Brain.code-workspace"
MODELS_DIR="$SUPPORT/models"
HEED_DIR="$SUPPORT/heed"
HEED_URL="http://localhost:5170"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)       MODE="check"; shift;;
    --only)        ONLY="$2"; shift 2;;
    --with-ollama) WITH_OLLAMA=1; shift;;
    --model)       MODEL="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done

mkdir -p "$BIN_DIR" "$MODELS_DIR"

# Always ensure ~/Desktop/2nd Brain exists (even for --check or partial --only runs).
ensure_desktop_brain_dir() {
  mkdir -p \
    "$DESKTOP_BRAIN_DIR/Agent Skills/nextjs" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/nestjs" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/n8n" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/openrouter" \
    "$DESKTOP_THINKING_DIR/frameworks" \
    "$DESKTOP_THINKING_DIR/reasoning" \
    "$DESKTOP_THINKING_DIR/evaluation" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/mcp" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/cybersecurity" \
    "$DESKTOP_BRAIN_DIR/Agent Skills/automation"
  # Legacy: reasoning/evaluation used to be sibling folders — fold into thinking/.
  rm -rf "$DESKTOP_SKILLS_DIR/reasoning" "$DESKTOP_SKILLS_DIR/evaluation"
  if [[ -d "$LEGACY_DESKTOP_SKILLS" ]]; then
    if [[ -d "$LEGACY_DESKTOP_SKILLS/mcp" && ! -e "$DESKTOP_SKILLS_DIR/mcp/registry.json" ]]; then
      cp -R "$LEGACY_DESKTOP_SKILLS/mcp/." "$DESKTOP_SKILLS_DIR/mcp/" 2>/dev/null || true
    fi
    rm -rf "$LEGACY_DESKTOP_SKILLS"
  fi
  [[ -f "$LEGACY_DESKTOP_WORKSPACE" ]] && rm -f "$LEGACY_DESKTOP_WORKSPACE"
}
ensure_desktop_brain_dir

emit() { printf 'STEP|%s|%s|%s\n' "$1" "$2" "$3"; }
have() { command -v "$1" >/dev/null 2>&1; }
wanted() { [[ -z "$ONLY" ]] || [[ ",$ONLY," == *",$1,"* ]]; }
installing() { [[ "$MODE" == "install" ]]; }

FAILED=0
fail() { emit "$1" failed "$2"; FAILED=$((FAILED + 1)); }

# Homebrew lives in different places on Apple Silicon vs Intel and isn't on PATH
# when the app spawns us from Finder.
for candidate in "$BIN_DIR" /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/.bun/bin"; do
  [[ -d "$candidate" && ":$PATH:" != *":$candidate:"* ]] && PATH="$candidate:$PATH"
done
export PATH

# Network: wait, resume, retry. A dropped connection must not restart GB downloads
# or hang the installer until the user kills it.
DOWNLOADS_DIR="$SUPPORT/downloads"
mkdir -p "$DOWNLOADS_DIR"

net_online() {
  curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null \
    || curl -fsS -m 8 -o /dev/null https://huggingface.co 2>/dev/null
}

# Wait up to ~5 minutes. Then fail the current fetch so the user can re-run;
# already-finished steps stay on disk.
net_wait() {
  local n=0
  net_online && return 0
  echo "  Internet is down — waiting to resume (not starting over)…" >&2
  while (( n < 30 )); do
    sleep 10
    net_online && { echo "  Network is back." >&2; return 0; }
    n=$((n + 1))
  done
  echo "  Still offline after 5 minutes — this step will retry next time you run setup." >&2
  return 1
}

# Resume-capable GET. Writes dest only when the transfer finishes.
# Partial bytes stay in dest.part so the next run continues with -C -.
net_fetch() {
  local url="$1" dest="$2"
  local part="${dest}.part"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && ! -s "$part" ]]; then
    return 0
  fi
  net_wait || return 1
  local n=0
  while (( n < 8 )); do
    echo "  download (try $((n + 1))/8, resumes if partial) $url" >&2
    if curl -L --fail -C - \
        --connect-timeout 20 \
        --retry 0 \
        --speed-time 45 --speed-limit 256 \
        -o "$part" "$url" >&2; then
      mv -f "$part" "$dest"
      return 0
    fi
    n=$((n + 1))
    net_wait || true
    sleep $((n * 4))
  done
  return 1
}

file_min_bytes() {
  local path="$1" min="$2" size
  [[ -f "$path" ]] || return 1
  size="$(stat -f%z "$path" 2>/dev/null || echo 0)"
  (( size >= min ))
}

# --- requirements -----------------------------------------------------------
step_requirements() {
  emit requirements checking "Checking this Mac"
  local arch os cores mem_gb free_gb
  arch="$(uname -m)"
  os="$(sw_vers -productVersion)"
  cores="$(sysctl -n hw.physicalcpu)"
  mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"

  echo "  Mac: $arch, ${cores} cores, ${mem_gb} GB RAM, macOS $os, ${free_gb} GB free"

  local py_line="not found"
  if find_python 2>/dev/null; then
    py_line="$("$PY" --version 2>&1) at $PY"
  elif have python3; then
    py_line="$(python3 --version 2>&1) at $(command -v python3)"
  fi
  echo "  Python: $py_line"

  local major="${os%%.*}"
  if (( major < 14 )); then
    fail requirements "macOS 14 or newer required (found $os)"
    return 1
  fi
  if [[ "$arch" != "arm64" ]]; then
    emit requirements manual "Intel Mac: the Neural Engine engines are unavailable; whisper.cpp only · Python: $py_line"
    return 0
  fi
  if (( free_gb < 20 )); then
    emit requirements manual "Only ${free_gb} GB free — the engines and models need about 20 GB · Python: $py_line"
    return 0
  fi

  # Building heed's Neural Engine sidecar needs the Command Line Tools.
  if ! xcode-select -p >/dev/null 2>&1; then
    if installing; then
      echo "  Requesting Command Line Tools install (a system dialog will appear)…"
      xcode-select --install >/dev/null 2>&1 || true
    fi
    emit requirements manual "Install the Xcode Command Line Tools, then run setup again · Python: $py_line"
    return 0
  fi

  emit requirements ok "${arch}, ${mem_gb} GB RAM, macOS $os, ${free_gb} GB free · Python: $py_line"
}

# --- homebrew ---------------------------------------------------------------
step_brew() {
  emit brew checking "Looking for Homebrew"
  if have brew; then
    emit brew ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
    return 0
  fi
  # The Homebrew installer needs an admin password, which we can't supply from a
  # background process — so this one step stays in the user's hands.
  emit brew manual 'Install Homebrew first: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  FAILED=$((FAILED + 1))
  return 1
}

brew_ensure() {
  local formula="$1" binary="$2" n=0
  have "$binary" && return 0
  installing || return 1
  have brew || return 1
  net_wait || return 1
  echo "  brew install $formula"
  while (( n < 4 )); do
    brew install "$formula" >&2 && have "$binary" && return 0
    n=$((n + 1))
    echo "  brew install $formula failed (try $((n + 1))/4) — retrying without reinstalling what is already there" >&2
    net_wait || true
    sleep $((n * 5))
  done
  have "$binary"
}

# --- bun (heed's runtime) --------------------------------------------------
step_bun() {
  emit bun checking "Looking for Bun"
  if have bun; then
    emit bun ok "Bun $(bun --version 2>/dev/null)"
    return 0
  fi
  if [[ -x "$HOME/.bun/bin/bun" ]]; then
    export PATH="$HOME/.bun/bin:$PATH"
    emit bun ok "Bun $($HOME/.bun/bin/bun --version) at ~/.bun/bin"
    return 0
  fi
  if ! installing; then fail bun "Bun not installed"; return 1; fi
  emit bun installing "Installing Bun"
  net_wait || { fail bun "Offline — Bun will install when you re-run setup"; return 1; }
  local n=0
  while (( n < 4 )); do
    curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 4 https://bun.sh/install | bash >&2 && break
    n=$((n + 1))
    net_wait || true
    sleep $((n * 4))
  done
  export PATH="$HOME/.bun/bin:$PATH"
  if have bun; then
    ln -sf "$(command -v bun)" "$BIN_DIR/bun"
    emit bun ok "Bun $(bun --version)"
  else
    fail bun "Could not install Bun (heed needs it to run)"
  fi
}

# --- node (for heed's installer) -------------------------------------------
step_node() {
  emit node checking "Looking for Node"
  if have npx; then
    emit node ok "Node $(node --version 2>/dev/null)"
    return 0
  fi
  if ! installing; then fail node "Node not installed"; return 1; fi
  emit node installing "Installing Node"
  if brew_ensure node node; then
    emit node ok "Node $(node --version)"
  else
    fail node "Could not install Node (needed to install heed)"
  fi
}

# --- python 3.10–3.12 (heed + tiron) ---------------------------------------
PY=""
find_python() {
  local candidate minor
  for candidate in python3.12 python3.11 python3.10 python3; do
    have "$candidate" || continue
    minor="$("$candidate" -c 'import sys; print(sys.version_info[1])' 2>/dev/null)" || continue
    if [[ -n "$minor" ]] && (( minor >= 10 && minor <= 12 )); then
      PY="$(command -v "$candidate")"
      return 0
    fi
  done
  return 1
}

step_python() {
  emit python checking "Looking for Python 3.10–3.12"
  if find_python; then
    emit python ok "$("$PY" --version) at $PY"
    return 0
  fi
  if ! installing; then fail python "Python 3.10–3.12 not installed"; return 1; fi
  emit python installing "Installing Python 3.12"
  if have brew; then
    brew install python@3.12 >&2
    # brew keeps versioned pythons out of PATH; use the keg directly.
    for candidate in /opt/homebrew/opt/python@3.12/bin/python3.12 /usr/local/opt/python@3.12/bin/python3.12; do
      [[ -x "$candidate" ]] && PY="$candidate" && break
    done
  fi
  [[ -z "$PY" ]] && find_python
  if [[ -n "$PY" ]]; then
    emit python ok "$("$PY" --version) at $PY"
  else
    fail python "Need Python 3.10–3.12 (heed and Tiron don't run on newer versions yet)"
  fi
}

# --- ffmpeg (heed's capture pipeline) --------------------------------------
step_ffmpeg() {
  emit ffmpeg checking "Looking for ffmpeg"
  if have ffmpeg; then
    emit ffmpeg ok "ffmpeg present"
    return 0
  fi
  if ! installing; then fail ffmpeg "ffmpeg not installed"; return 1; fi
  emit ffmpeg installing "Installing ffmpeg"
  if brew_ensure ffmpeg ffmpeg; then
    emit ffmpeg ok "ffmpeg installed"
  else
    fail ffmpeg "Could not install ffmpeg (heed needs it to record)"
  fi
}

# --- whisper.cpp + a ggml model -------------------------------------------
pick_model() {
  [[ -n "$MODEL" ]] && { echo "$MODEL"; return; }
  # Follow whatever the app is set to, so setup and the menu agree.
  local pref; pref="$(defaults read com.dao.secondbrain whisperModel 2>/dev/null)"
  [[ -n "$pref" ]] && { echo "$pref"; return; }
  local mem_gb; mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  if   (( mem_gb >= 32 )); then echo "large-v3"
  elif (( mem_gb >= 16 )); then echo "medium.en"
  else                          echo "small.en"
  fi
}

existing_model() {
  local found size
  while IFS= read -r found; do
    [[ -n "$found" ]] || continue
    size="$(stat -f%z "$found" 2>/dev/null || echo 0)"
    (( size >= 40000000 )) || continue
    basename "$found"
    return 0
  done < <(find "$MODELS_DIR" -maxdepth 1 -name 'ggml-*.bin' ! -name '*.part' -print 2>/dev/null)
}

step_whisper() {
  emit whisper checking "Looking for whisper.cpp"
  local model file
  model="$(pick_model)"
  file="$MODELS_DIR/ggml-${model}.bin"

  local exe=""
  for candidate in whisper-cli whisper-cpp; do
    have "$candidate" && exe="$(command -v "$candidate")" && break
  done

  if [[ -z "$exe" ]]; then
    if ! installing; then fail whisper "whisper.cpp not installed"; return 1; fi
    emit whisper installing "Installing whisper.cpp"
    brew_ensure whisper-cpp whisper-cli >/dev/null
    for candidate in whisper-cli whisper-cpp; do
      have "$candidate" && exe="$(command -v "$candidate")" && break
    done
  fi
  [[ -n "$exe" ]] && ln -sf "$exe" "$BIN_DIR/whisper-cli"

  # A different model already on disk is just as offline-ready, and the app falls
  # back to it — no reason to spend another gigabyte.
  local present; present="$(existing_model)"
  if [[ ! -f "$file" && -n "$present" ]]; then
    emit whisper ok "whisper.cpp + $present ready"
    return 0
  fi

  if [[ ! -f "$file" ]] || ! file_min_bytes "$file" 40000000; then
    if ! installing; then fail whisper "no whisper model downloaded"; return 1; fi
    rm -f "$file"
    emit whisper installing "Downloading the $model model (about 1–3 GB — resumes if interrupted)"
    if ! net_fetch \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${model}.bin" \
        "$file"; then
      fail whisper "Could not download ggml-${model}.bin — re-run setup; the partial file is kept"
      return 1
    fi
    if ! file_min_bytes "$file" 40000000; then
      mv -f "$file" "${file}.part" 2>/dev/null || rm -f "$file"
      fail whisper "Download looked incomplete — re-run setup to resume"
      return 1
    fi
  fi

  if [[ -n "$exe" && -f "$file" ]]; then
    emit whisper ok "whisper.cpp + $model model ready"
  else
    fail whisper "whisper.cpp incomplete"
  fi
}

# --- tiron (multi-speaker meetings) ---------------------------------------
tiron_venv_python() {
  local venvs
  venvs="$(pipx environment --value PIPX_LOCAL_VENVS 2>/dev/null || echo "$HOME/.local/pipx/venvs")"
  echo "$venvs/tiron/bin/python"
}

# Both artifacts have to be on disk or Tiron reaches for the network mid-meeting:
# the checkpoint itself and the ECAPA encoder it links speakers with.
tiron_models_cached() {
  local py="$1"
  [[ -x "$py" ]] || return 1
  "$py" - <<'PY' >/dev/null 2>&1
import sys
from huggingface_hub import snapshot_download
try:
    for repo in ("Trelis/tiron", "speechbrain/spkrec-ecapa-voxceleb"):
        snapshot_download(repo, local_files_only=True)
except Exception:
    sys.exit(1)
PY
}

step_tiron() {
  emit tiron checking "Looking for Tiron"
  local venv_py; venv_py="$(tiron_venv_python)"

  if ! have tiron && [[ ! -x "$BIN_DIR/tiron" ]]; then
    if ! installing; then fail tiron "Tiron not installed"; return 1; fi
    emit tiron installing "Installing Tiron (downloads PyTorch — several minutes)"
    if ! have pipx; then brew_ensure pipx pipx >/dev/null; fi
    if ! have pipx; then
      fail tiron "Could not install pipx"
      return 1
    fi
    [[ -z "$PY" ]] && find_python
    local py_flag=()
    [[ -n "$PY" ]] && py_flag=(--python "$PY")
    net_wait || { fail tiron "Offline — Tiron will install when you re-run setup"; return 1; }
    local n=0
    while (( n < 4 )); do
      pipx install "${py_flag[@]}" "git+https://github.com/TrelisResearch/tiron" >&2 && break
      n=$((n + 1))
      net_wait || true
      sleep $((n * 5))
    done
    if ! have tiron && [[ ! -x "$HOME/.local/bin/tiron" ]]; then
      fail tiron "pipx could not install Tiron"
      return 1
    fi
    venv_py="$(tiron_venv_python)"
  fi

  local exe; exe="$(command -v tiron || echo "$HOME/.local/bin/tiron")"
  [[ -x "$exe" ]] && ln -sf "$exe" "$BIN_DIR/tiron"

  if tiron_models_cached "$venv_py"; then
    emit tiron ok "Tiron + models ready (offline)"
    return 0
  fi

  if ! installing; then fail tiron "Tiron models not downloaded"; return 1; fi
  emit tiron installing "Downloading the Tiron model (about 3 GB) + speaker encoder — resumes from Hugging Face cache"
  net_wait || { fail tiron "Offline — Tiron models will finish when you re-run setup"; return 1; }
  "$venv_py" - <<'PY' >&2
import time
from huggingface_hub import snapshot_download
for repo in ("Trelis/tiron", "speechbrain/spkrec-ecapa-voxceleb"):
    for attempt in range(6):
        print(f"[tiron] fetching {repo} (try {attempt + 1}/6)", flush=True)
        try:
            snapshot_download(repo)
            break
        except Exception as exc:
            print(exc, flush=True)
            if attempt == 5:
                raise
            time.sleep(8 * (attempt + 1))
    else:
        raise SystemExit(1)
PY
  if tiron_models_cached "$venv_py"; then
    emit tiron ok "Tiron + models ready (offline)"
  else
    fail tiron "Tiron installed but its models are not cached"
  fi
}

# --- heed (live transcription) -------------------------------------------
heed_healthy() { curl -fsS -m 3 "$HEED_URL/api/health" >/dev/null 2>&1; }

# create-heed finishes by starting heed and opening a floating panel, so once the
# server answers we stop the installer's foreground half. The server it spawned is
# detached (its own session), so it keeps running.
stop_group() {
  local pid="$1"
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -KILL -"$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

step_heed() {
  emit heed checking "Looking for heed"
  # Files on disk are enough. Do not wait for /api/health: create-heed starts a
  # capture process that triggers Screen Recording TCC, and that permission
  # only applies after the requesting app (often Terminal) is restarted — so
  # the installer process will never become healthy.
  if [[ -f "$HEED_DIR/package.json" && -d "$HEED_DIR/node_modules" ]]; then
    emit heed ok "heed installed at $HEED_DIR"
    return 0
  fi
  if ! installing; then fail heed "heed not installed"; return 1; fi
  if ! have npx; then
    fail heed "Node is required to install heed"
    return 1
  fi

  emit heed installing "Installing heed + Neural Engine models (this is the long one)"
  echo "If macOS asks for Screen Recording or system audio: click Allow and leave this terminal running. Do not quit it — 2ⁿᵈ Brain asks for those permissions later. Setup continues once the files are on disk. If the network drops, re-run setup — a finished heed folder is not downloaded again." >&2
  net_wait || { fail heed "Offline — heed will install when you re-run setup"; return 1; }
  # create-heed installs into ./heed, so run it from our support directory.
  set -m
  ( cd "$SUPPORT" && npx --yes create-heed@latest --yes --fast --engine=parakeet >&2 ) &
  local pid=$! waited=0 files_at=-1
  while (( waited < 2400 )); do
    if [[ -f "$HEED_DIR/package.json" && -d "$HEED_DIR/node_modules" ]]; then
      if (( files_at < 0 )); then files_at=$waited; fi
      heed_healthy && break
      # Models may still be fetching; after 5 minutes of files-on-disk without
      # a health answer (typical TCC stall), take the disk install and move on.
      if (( waited - files_at >= 300 )); then
        break
      fi
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 5; waited=$((waited + 5))
  done
  if kill -0 "$pid" 2>/dev/null; then stop_group "$pid"; fi
  set +m

  if [[ -d "$HEED_DIR/node_modules" ]]; then
    emit heed ok "heed installed at $HEED_DIR"
  else
    fail heed "heed setup did not complete — see the log above"
  fi
}

# --- ollama (optional, for local AI notes/answers) -----------------------
# Pinned local models used by Obsidian Local GPT, the app, and Cline/Roo:
#   qwen3.5:4b          — general / notes
#   qwen2.5-coder:7b    — coding / overnight
OLLAMA_MODELS=(qwen3.5:4b qwen2.5-coder:7b)

ollama_has() {
  local want="$1"
  python3 - "$want" <<'PY'
import json, subprocess, sys, urllib.request
want = sys.argv[1]
names = []
try:
    out = subprocess.check_output(["ollama", "list"], text=True, stderr=subprocess.DEVNULL, timeout=8)
    for line in out.splitlines()[1:]:
        part = line.split()
        if part:
            names.append(part[0])
except Exception:
    pass
try:
    with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2) as r:
        for m in json.load(r).get("models") or []:
            n = m.get("name") or ""
            if n:
                names.append(n)
except Exception:
    pass
for n in names:
    if n == want or n.startswith(want + ":") or n.startswith(want + "@"):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

ollama_ensure_running() {
  have ollama || return 1
  curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && return 0
  (ollama serve >/dev/null 2>&1 &)
  local n=0
  while (( n < 20 )); do
    curl -fsS -m 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && return 0
    sleep 0.5
    n=$((n + 1))
  done
  return 1
}

ollama_pull_one() {
  local model="$1" n=0
  ollama_has "$model" && return 0
  emit ollama installing "Pulling $model (resumes if interrupted)"
  net_wait || return 1
  while (( n < 4 )); do
    ollama pull "$model" >&2 && ollama_has "$model" && return 0
    n=$((n + 1))
    net_wait || true
    sleep $((n * 5))
  done
  return 1
}

step_ollama() {
  # Already-pulled Qwen models count as ready even on a --check without --with-ollama.
  local missing=1 model
  if have ollama; then
    missing=0
    for model in "${OLLAMA_MODELS[@]}"; do
      ollama_has "$model" || missing=1
    done
    if (( missing == 0 )); then
      emit ollama ok "Ollama + ${OLLAMA_MODELS[*]} ready"
      return 0
    fi
  fi
  # --only ollama still pulls even without --with-ollama.
  if (( WITH_OLLAMA == 0 )) && [[ -z "$ONLY" ]]; then
    if have ollama; then
      emit ollama skipped "Ollama is installed; turn Local AI on to pull Qwen 3.5 4B + Coder 7B"
    else
      emit ollama skipped "Skipped (local AI model not requested)"
    fi
    return 0
  fi
  emit ollama checking "Looking for Ollama + Qwen models"
  if ! have ollama; then
    if ! installing; then fail ollama "Ollama not installed"; return 1; fi
    emit ollama installing "Installing Ollama"
    brew_ensure ollama ollama >/dev/null
  fi
  if ! have ollama; then
    fail ollama "Could not install Ollama"
    return 1
  fi
  # Homebrew's own service (homebrew.mxcl.ollama), not a 2nd Brain LaunchAgent.
  brew services start ollama >/dev/null 2>&1 || true

  missing=0
  for model in "${OLLAMA_MODELS[@]}"; do
    ollama_has "$model" || missing=1
  done
  if (( missing == 0 )); then
    emit ollama ok "Ollama + ${OLLAMA_MODELS[*]} ready"
    return 0
  fi
  if ! installing; then fail ollama "Qwen models not pulled yet"; return 1; fi
  ollama_ensure_running || { fail ollama "Ollama is installed but not answering on :11434"; return 1; }
  for model in "${OLLAMA_MODELS[@]}"; do
    ollama_pull_one "$model" || { fail ollama "Could not pull $model — re-run setup to resume"; return 1; }
  done
  emit ollama ok "Ollama + ${OLLAMA_MODELS[*]} ready"
}

# --- oMLX (local LLM inference on Apple Silicon) ---------------------------
# Official install paths (https://github.com/jundot/omlx):
#   brew tap jundot/omlx && brew trust jundot/omlx && brew install jundot/omlx/omlx
#   or download the .dmg from GitHub Releases and drag oMLX.app to Applications.
install_omlx_dmg() {
  local tag dmg_url dmg_path mount_out mount_dir app_src
  tag="v0.6.0"
  if have curl; then
    tag="$(curl -fsSL "https://api.github.com/repos/jundot/omlx/releases/latest" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name','v0.6.0'))" 2>/dev/null \
      || echo "v0.6.0")"
  fi
  local ver="${tag#v}"
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ "$macos_major" -ge 26 ]]; then
    dmg_url="https://github.com/jundot/omlx/releases/download/${tag}/oMLX-${ver}-macos26-27.dmg"
  else
    dmg_url="https://github.com/jundot/omlx/releases/download/${tag}/oMLX-${ver}-macos15-sequoia.dmg"
  fi
  dmg_path="$DOWNLOADS_DIR/oMLX-${ver}.dmg"
  emit omlx installing "Downloading oMLX ${tag} from GitHub Releases (resumes if interrupted)"
  if ! net_fetch "$dmg_url" "$dmg_path"; then
    return 1
  fi
  mount_out="$(hdiutil attach "$dmg_path" -nobrowse -quiet 2>&1)" || return 1
  mount_dir="$(echo "$mount_out" | tail -1 | sed -E 's/^[^[:space:]]+[[:space:]]+([^[:space:]]+).*/\1/')"
  app_src=""
  for candidate in "$mount_dir"/oMLX.app "$mount_dir"/*.app; do
    [[ -d "$candidate" ]] || continue
    app_src="$candidate"
    break
  done
  if [[ -z "$app_src" ]]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
    return 1
  fi
  rm -rf "/Applications/oMLX.app"
  cp -R "$app_src" "/Applications/oMLX.app" >&2
  hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  rm -f "$dmg_path"
  [[ -d "/Applications/oMLX.app" ]]
}

step_omlx() {
  emit omlx checking "Looking for oMLX"
  if have omlx || [[ -d "/Applications/oMLX.app" ]]; then
    emit omlx ok "oMLX present"
    return 0
  fi
  if ! installing; then fail omlx "oMLX not installed"; return 1; fi
  if [[ "$(uname -m)" != "arm64" ]]; then
    emit omlx skipped "oMLX needs Apple Silicon"
    return 0
  fi
  local macos_major
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ "$macos_major" -lt 15 ]]; then
    emit omlx skipped "oMLX needs macOS 15+ (Sequoia)"
    return 0
  fi
  emit omlx installing "Installing oMLX (Apple Silicon LLM server)"
  if have brew; then
    brew tap jundot/omlx https://github.com/jundot/omlx >&2 || true
    brew trust jundot/omlx >&2 || true
    brew install jundot/omlx/omlx >&2 || true
  fi
  if ! have omlx && [[ ! -d "/Applications/oMLX.app" ]]; then
    install_omlx_dmg >&2 || true
  fi
  if have omlx || [[ -d "/Applications/oMLX.app" ]]; then
    emit omlx ok "oMLX installed"
  else
    fail omlx "Could not install oMLX — get the .dmg from https://github.com/jundot/omlx/releases"
  fi
}

# --- oMLX Interpreter (local coding agent on top of oMLX) ------------------
step_omlx_interpreter() {
  local dir="$SUPPORT/omlx-interpreter"
  emit omlx_interpreter checking "Looking for oMLX Interpreter"
  if [[ -d "$dir" && -f "$dir/setup.sh" ]]; then
    emit omlx_interpreter ok "oMLX Interpreter at $dir"
    return 0
  fi
  if ! installing; then fail omlx_interpreter "oMLX Interpreter not installed"; return 1; fi
  emit omlx_interpreter installing "Cloning and setting up oMLX Interpreter"
  if ! have git; then
    fail omlx_interpreter "git is required"
    return 1
  fi
  net_wait || { fail omlx_interpreter "Offline — clone will finish when you re-run setup"; return 1; }
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" pull --ff-only >&2 || true
  else
    rm -rf "$dir"
    local n=0
    while (( n < 4 )); do
      git clone --depth 1 https://github.com/fxops-ai/omlx-interpreter.git "$dir" >&2 && break
      n=$((n + 1))
      rm -rf "$dir"
      net_wait || true
      sleep $((n * 4))
    done
  fi
  if [[ ! -d "$dir" ]]; then
    fail omlx_interpreter "Could not clone https://github.com/fxops-ai/omlx-interpreter"
    return 1
  fi
  (
    cd "$dir"
    if [[ -x ./setup.sh ]]; then
      CI=1 NONINTERACTIVE=1 ./setup.sh >&2 || pip3 install -r requirements.txt >&2 || true
      command -v npm >/dev/null && npm install --legacy-peer-deps >&2 || true
    fi
  )
  if [[ -d "$dir" ]]; then
    emit omlx_interpreter ok "oMLX Interpreter at $dir"
  else
    fail omlx_interpreter "Clone succeeded but setup looks incomplete"
  fi
}

# --- resolve VS Code CLI ----------------------------------------------------
find_code_bin() {
  local candidate
  for candidate in \
      "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
      "/usr/local/bin/code" \
      "/opt/homebrew/bin/code" \
      "$BIN_DIR/code" \
      code; do
    if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
    if have "$candidate" 2>/dev/null; then command -v "$candidate"; return 0; fi
  done
  return 1
}

# Desktop workspace + startup folder so VS Code opens ~/Desktop/2nd Brain.
write_vscode_second_brain_workspace() {
  ensure_desktop_brain_dir
  # The vault is this same folder now, so the workspace has a single root.
  python3 - "$DESKTOP_WORKSPACE" "$DESKTOP_BRAIN_DIR" "$DESKTOP_SKILLS_DIR" <<'PY'
import json, sys
workspace_path, brain_dir, skills_dir = sys.argv[1:4]
doc = {
    "folders": [
        {"name": "2nd Brain", "path": brain_dir},
    ],
    "settings": {
        "files.dialog.defaultPath": skills_dir,
        "window.restoreWindows": "all",
        "files.exclude": {"**/.obsidian": True},
    },
    "extensions": {
        "recommendations": [
            "saoudrizwan.claude-dev",
            "rooveterinaryinc.roo-cline",
            "kilocode.kilo-code",
            "carlocardella.vscode-autogit",
        ]
    },
}
with open(workspace_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(workspace_path)
PY
}

write_vscode_user_settings() {
  python3 - "$DESKTOP_BRAIN_DIR" "$DESKTOP_SKILLS_DIR" <<'PY'
import json, os, sys
brain_dir, skills_dir = sys.argv[1:3]
settings_path = os.path.join(
    os.path.expanduser("~"), "Library/Application Support/Code/User/settings.json"
)
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
settings = {}
if os.path.isfile(settings_path):
    try:
        settings = json.load(open(settings_path, encoding="utf-8"))
    except Exception:
        settings = {}
settings["files.dialog.defaultPath"] = skills_dir
settings["window.restoreWindows"] = "all"
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(settings_path)
PY
}

vscode_is_running() {
  pgrep -f "/Visual Studio Code.app/Contents/MacOS/Electron" >/dev/null 2>&1
}

seed_vscode_startup_folder() {
  vscode_is_running && return 0
  write_vscode_second_brain_workspace || return 0
  python3 - "$DESKTOP_BRAIN_DIR" "$DESKTOP_WORKSPACE" <<'PY'
import json, os, sys
from pathlib import Path

brain_dir, workspace_path = sys.argv[1:3]
storage_path = os.path.join(
    os.path.expanduser("~"),
    "Library/Application Support/Code/User/globalStorage/storage.json",
)
if not os.path.isfile(storage_path):
    raise SystemExit(0)

folder_uri = Path(brain_dir).resolve().as_uri()
workspace_uri = Path(workspace_path).resolve().as_uri()

try:
    data = json.load(open(storage_path, encoding="utf-8"))
except Exception:
    raise SystemExit(0)

backup = data.setdefault("backupWorkspaces", {})
folders = backup.setdefault("folders", [])
workspaces = backup.setdefault("workspaces", [])

# Prefer ~/Desktop/2nd Brain; keep workspace entry too when present.
folders = [f for f in folders if f.get("folderUri") != folder_uri]
folders.insert(0, {"folderUri": folder_uri})
backup["folders"] = folders[:5]

if os.path.isfile(workspace_path):
    workspaces = [w for w in workspaces if w.get("workspaceUri") != workspace_uri]
    workspaces.insert(0, {"workspaceUri": workspace_uri})
    backup["workspaces"] = workspaces[:5]

backup["emptyWindows"] = []

with open(storage_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(storage_path)
PY
}

install_code_cli_wrapper() {
  local real_code="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  [[ -x "$real_code" ]] || return 0

  cat > "$BIN_DIR/code" <<EOF
#!/usr/bin/env bash
# 2ⁿᵈ Brain — open ~/Desktop/2nd Brain when \`code\` is run with no args.
REAL_CODE="$real_code"
WORKSPACE="$DESKTOP_WORKSPACE"
BRAIN="$DESKTOP_BRAIN_DIR"
if [[ \$# -eq 0 ]]; then
  if [[ -f "\$WORKSPACE" ]]; then
    exec "\$REAL_CODE" "\$WORKSPACE"
  elif [[ -d "\$BRAIN" ]]; then
    exec "\$REAL_CODE" "\$BRAIN"
  fi
fi
exec "\$REAL_CODE" "\$@"
EOF
  chmod +x "$BIN_DIR/code"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$BIN_DIR/code" "$HOME/.local/bin/code"
}

configure_vscode_second_brain() {
  write_vscode_second_brain_workspace || true
  write_vscode_user_settings || true
  write_vscode_agent_rules || true
  write_vscode_ai_profiles || true
  write_kilo_omlx_config || true
  patch_kilo_openrouter_profiles || true
  install_code_cli_wrapper || true
  seed_vscode_startup_folder || true
}

# Cline, Roo & Kilo — always route through thinking-model-router first.
write_vscode_agent_rules() {
  local canonical="$HOME/.agents/skills/thinking-model-router/SKILL.md"
  local router_rule="$DESKTOP_BRAIN_DIR/.clinerules/00-thinking-model-router.md"
  install_openrouter_router_skill || true
  mkdir -p \
    "$DESKTOP_BRAIN_DIR/.clinerules" \
    "$DESKTOP_BRAIN_DIR/.roo/rules" \
    "$DESKTOP_BRAIN_DIR/.kilo/rules" \
    "$HOME/.agents"

  cat > "$router_rule" <<'EOF'
# Always start with thinking-model-router

Before any non-trivial analysis, planning, design, or implementation:

1. **Load the `thinking-model-router` skill** (`~/.agents/skills/thinking-model-router/SKILL.md`).
2. Run its procedure — return NONE, one primary skill, or at most three complementary skills.
3. Load only the routed skill(s), then act.

Skill library lives under `Agent Skills/thinking/`:
- `frameworks/` — mental models, design thinking, planning
- `reasoning/` — logic, Socratic inquiry, probabilistic inference
- `evaluation/` — trade-offs, pre-mortems, quality assessment

Do not skip the router for habit or speed on ambiguous or high-stakes work.
EOF
  cp -f "$router_rule" "$DESKTOP_BRAIN_DIR/.roo/rules/00-thinking-model-router.md"
  cp -f "$router_rule" "$DESKTOP_BRAIN_DIR/.kilo/rules/00-thinking-model-router.md"

  local or_rule="$DESKTOP_BRAIN_DIR/.clinerules/01-openrouter-model-selection.md"
  cat > "$or_rule" <<'EOF'
# OpenRouter model selection (free first, Auto on retry)

When using OpenRouter (cloud):

1. **Load `using-openrouter-model-selection`** (`Agent Skills/openrouter/using-openrouter-model-selection/`).
2. **First attempt — always a pinned free model** (default: **Laguna S 2.1 free**). All pinned free profiles are in Cline / Roo / Kilo — see `free-tool-agent-models.md`.
3. **User unhappy with output** (asks to redo, improve, or says quality is bad): switch to **OpenRouter Auto** (`openrouter/auto`) and **rerun the same task** with the same prompt/context. Tell the user you are retrying on Auto.
4. **Do not use Auto on the first attempt** unless the user explicitly asks for it.

Local **oMLX** remains a separate profile for on-device inference.
EOF
  cp -f "$or_rule" "$DESKTOP_BRAIN_DIR/.roo/rules/01-openrouter-model-selection.md"
  cp -f "$or_rule" "$DESKTOP_BRAIN_DIR/.kilo/rules/01-openrouter-model-selection.md"

  cat > "$DESKTOP_BRAIN_DIR/AGENTS.md" <<'EOF'
# 2nd Brain — VS Code agents (Cline, Roo, Kilo)

## Mandatory first step: thinking-model-router

For every task that involves judgment, planning, design, debugging strategy, or non-trivial implementation:

1. Read and follow **`thinking-model-router`** (`Agent Skills/thinking/frameworks/thinking-model-router` or `~/.agents/skills/thinking-model-router/`).
2. Apply its route (NONE | one skill | up to three complementary skills).
3. Then load only the chosen skill(s) from `Agent Skills/thinking/`.

## OpenRouter model selection (free first, Auto on retry)

For cloud inference via OpenRouter:

1. Read and follow **`using-openrouter-model-selection`** (`Agent Skills/openrouter/using-openrouter-model-selection`).
2. **First attempt — always a pinned free model** (default: **`poolside/laguna-s-2.1:free`**). All pinned models are preconfigured in Cline, Roo & Kilo — see **`free-tool-agent-models.md`**.
3. **If the user dislikes the output:** switch to **OpenRouter Auto** (`openrouter/auto`) and **rerun the same task** (same instructions/context). Say you are retrying on Auto.
4. **Do not use Auto first** unless the user explicitly requests it.
5. **Local option:** **Ollama Qwen Coder 7B** (`qwen2.5-coder:7b`) or **Ollama Qwen 3.5 4B** (`qwen3.5:4b`) on `127.0.0.1:11434`, or **oMLX Local** on `:8000`.

## Skill layout

| Path | Use for |
|------|---------|
| `Agent Skills/thinking/frameworks/` | Frameworks, design thinking, planning, meta-thinking |
| `Agent Skills/thinking/reasoning/` | Reasoning, argumentation, inference |
| `Agent Skills/thinking/evaluation/` | Evaluation, trade-offs, quality checks |
| `Agent Skills/n8n/` | n8n workflows — start with `using-n8n-skills-official` |
| `Agent Skills/openrouter/` | **`free-tool-agent-models.md`** — pinned free models first; **Auto rerun** if user dislikes output |

## n8n MCP

Multiple n8n instances: edit `Agent Skills/mcp/registry.json`, tokens in `local.env`, run `sync-mcp.sh`.
EOF

  cp -f "$DESKTOP_BRAIN_DIR/AGENTS.md" "$HOME/.agents/AGENTS.md"

  cat > "$DESKTOP_BRAIN_DIR/kilo.jsonc" <<'EOF'
{
  "$schema": "https://app.kilo.ai/config.json",
  "model": "openrouter/poolside/laguna-s-2.1:free",
  "instructions": [
    ".kilo/rules/00-thinking-model-router.md",
    ".kilo/rules/01-openrouter-model-selection.md",
    "AGENTS.md"
  ]
}
EOF

  # Roo custom instructions export (import in Roo Code settings if needed).
  python3 - "$SUPPORT/vscode/roo-code-settings.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
doc = {}
if path.is_file():
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except Exception:
        doc = {}
router = (
    "Always load thinking-model-router first for non-trivial work. "
    "OpenRouter: always start with a pinned FREE model (default Laguna S 2.1 free). "
    "If the user dislikes the output, switch to OpenRouter Auto and rerun the same task. "
    "See AGENTS.md and free-tool-agent-models.md."
)
doc["customInstructions"] = router
doc.setdefault("_secondBrainNote", "Import in Roo Code settings → Import Settings")
with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

  mkdir -p "$HOME/Documents/Cline/Rules" 2>/dev/null || true
  cp -f "$router_rule" "$HOME/Documents/Cline/Rules/00-thinking-model-router.md" 2>/dev/null || true
  cp -f "$or_rule" "$HOME/Documents/Cline/Rules/01-openrouter-model-selection.md" 2>/dev/null || true
  echo "$DESKTOP_BRAIN_DIR/AGENTS.md"
}

# Seed Cline (~/.cline/data/settings/providers.json) and Roo import profiles
# (oMLX local + OpenRouter cloud). API keys come from OPENROUTER_API_KEY when set.
write_vscode_ai_profiles() {
  local openrouter_key="${OPENROUTER_API_KEY:-}"
  local free_models_json
  free_models_json=$(printf '%s\n' "${OPENROUTER_FREE_AGENT_MODEL_IDS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  python3 - "$openrouter_key" "$SUPPORT" "$free_models_json" <<'PY'
import json, os, sys
from datetime import datetime, timezone

openrouter_key, support, free_models_json = sys.argv[1:4]
free_models = json.loads(free_models_json)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
PRIMARY = free_models[0] if free_models else "poolside/laguna-s-2.1:free"

def cline_entry(provider, model, base_url=None, api_key=None):
    settings = {"provider": provider, "model": model}
    if provider == "openai-compatible":
        settings["client"] = "openai-compatible"
    if base_url:
        settings["baseUrl"] = base_url
    if api_key:
        settings["apiKey"] = api_key
    return {"settings": settings, "updatedAt": now, "tokenSource": "manual"}

def cline_key(model_id, index):
    if index == 0:
        return "openrouter-laguna-free"
    slug = model_id.replace("/", "-").replace(":", "-").replace(".", "-")
    return f"openrouter-free-{slug}"[:64]

def roo_label(model_id):
    tail = model_id.split("/", 1)[-1].replace(":free", "")
    return f"OpenRouter Free · {tail}"[:72]

def roo_profile(api_provider, model_id, base_url=None, api_key=None):
    p = {"apiProvider": api_provider}
    if api_provider == "openrouter":
        p["openRouterModelId"] = model_id
        if api_key:
            p["openRouterApiKey"] = api_key
    elif api_provider == "openai":
        p["openAiModelId"] = model_id
        if base_url:
            p["openAiBaseUrl"] = base_url
        if api_key:
            p["openAiApiKey"] = api_key
    elif api_provider == "ollama":
        p["ollamaModelId"] = model_id
        p["ollamaBaseUrl"] = base_url or "http://127.0.0.1:11434"
    return p

# --- Cline -----------------------------------------------------------------
cline_dir = os.path.join(os.path.expanduser("~"), ".cline", "data", "settings")
os.makedirs(cline_dir, exist_ok=True)
cline_path = os.path.join(cline_dir, "providers.json")

existing = {"version": 1, "providers": {}}
if os.path.isfile(cline_path):
    try:
        existing = json.load(open(cline_path, encoding="utf-8"))
    except Exception:
        pass
if existing.get("version") != 1:
    existing = {"version": 1, "providers": existing.get("providers") or {}}
providers = dict(existing.get("providers") or {})

seed = {
    "omlx-local": cline_entry(
        "openai-compatible", "qwen3-coder-next",
        base_url="http://127.0.0.1:8000/v1", api_key="omlx",
    ),
    "ollama-qwen35": cline_entry(
        "ollama", "qwen3.5:4b",
        base_url="http://127.0.0.1:11434",
    ),
    "ollama-qwen-coder": cline_entry(
        "ollama", "qwen2.5-coder:7b",
        base_url="http://127.0.0.1:11434",
    ),
    "openrouter-auto": cline_entry("openrouter", "openrouter/auto", api_key=openrouter_key or None),
    "openrouter-free-router": cline_entry("openrouter", "openrouter/free", api_key=openrouter_key or None),
}
for i, model_id in enumerate(free_models):
    seed[cline_key(model_id, i)] = cline_entry(
        "openrouter", model_id, api_key=openrouter_key or None,
    )
for name, entry in seed.items():
    providers[name] = entry  # always refresh pinned profiles
existing["providers"] = providers
primary_cline = cline_key(PRIMARY, 0)
# Keep the human's last Cline pick. New machines default to local Qwen 3.5.
if not existing.get("lastUsedProvider"):
    existing["lastUsedProvider"] = "ollama-qwen35"
existing["_secondBrainOpenRouterDefault"] = PRIMARY
existing["_secondBrainOpenRouterPrimaryCline"] = primary_cline
with open(cline_path, "w", encoding="utf-8") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

# --- Roo Code --------------------------------------------------------------
vscode_dir = os.path.join(support, "vscode")
os.makedirs(vscode_dir, exist_ok=True)
roo_import = os.path.join(vscode_dir, "roo-code-settings.json")

api_configs = {
    "oMLX Local": roo_profile(
        "openai", "qwen3-coder-next",
        base_url="http://127.0.0.1:8000/v1", api_key="omlx",
    ),
    "Ollama Qwen 3.5 4B": roo_profile(
        "ollama", "qwen3.5:4b",
        base_url="http://127.0.0.1:11434",
    ),
    "Ollama Qwen Coder 7B": roo_profile(
        "ollama", "qwen2.5-coder:7b",
        base_url="http://127.0.0.1:11434",
    ),
    "OpenRouter Auto (retry)": roo_profile(
        "openrouter", "openrouter/auto", api_key=openrouter_key or None,
    ),
    "OpenRouter Free Router": roo_profile(
        "openrouter", "openrouter/free", api_key=openrouter_key or None,
    ),
}
for i, model_id in enumerate(free_models):
    api_configs[roo_label(model_id)] = roo_profile(
        "openrouter", model_id, api_key=openrouter_key or None,
    )

primary_roo = roo_label(PRIMARY)
roo_doc = {
    "providerProfiles": {
        "currentApiConfigName": primary_roo,
        "apiConfigs": api_configs,
    },
    "_secondBrainNote": (
        "Import in Roo Code settings → Import Settings. "
        f"Default: pinned free model ({PRIMARY}). "
        "If user dislikes output, switch to OpenRouter Auto (retry) and rerun same task. "
        "Set OPENROUTER_API_KEY or paste key into OpenRouter profiles."
    ),
    "_secondBrainOpenRouterDefault": PRIMARY,
}
with open(roo_import, "w", encoding="utf-8") as f:
    json.dump(roo_doc, f, indent=2)
    f.write("\n")
print(cline_path)
print(roo_import)
PY
}

# Point Kilo Code at local oMLX (OpenAI-compatible).
write_kilo_omlx_config() {
  local kilo_dir="$HOME/.config/kilo"
  local kilo_cfg="$kilo_dir/kilo.jsonc"
  mkdir -p "$kilo_dir"
  if [[ -f "$kilo_cfg" ]] && grep -qiE 'omlx|8000/v1|openai-compatible' "$kilo_cfg"; then
    return 0
  fi
  if [[ -f "$kilo_cfg" && ! -f "$kilo_cfg.secondbrain.bak" ]]; then
    cp "$kilo_cfg" "$kilo_cfg.secondbrain.bak"
  fi
  cat > "$kilo_cfg" <<'EOF'
{
  "$schema": "https://app.kilo.ai/config.json",
  "model": "openrouter/poolside/laguna-s-2.1:free",
  "provider": {
    "openai-compatible": {
      "options": {
        "apiKey": "omlx",
        "baseURL": "http://127.0.0.1:8000/v1"
      },
      "models": {
        "omlx-local": {
          "name": "oMLX (local)",
          "tool_call": true,
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    },
    "openrouter": {
      "options": {
        "apiKey": "{env:OPENROUTER_API_KEY}"
      },
      "models": {
        "openrouter-auto": {
          "name": "OpenRouter Auto (best for prompt)",
          "tool_call": true
        },
        "openrouter-free": {
          "name": "OpenRouter Free (free models only)",
          "tool_call": true
        }
      }
    }
  }
}
EOF
}

# Merge OpenRouter auto/free into an existing Kilo config without clobbering oMLX.
patch_kilo_openrouter_profiles() {
  local free_models_json
  free_models_json=$(printf '%s\n' "${OPENROUTER_FREE_AGENT_MODEL_IDS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  python3 - "$free_models_json" <<'PY'
import json, sys
from pathlib import Path

free_models = json.loads(sys.argv[1])
PRIMARY = free_models[0] if free_models else "poolside/laguna-s-2.1:free"

def kilo_label(model_id):
    tail = model_id.split("/", 1)[-1].replace(":free", "")
    return f"OpenRouter Free · {tail}"[:72]

cfg_path = Path.home() / ".config/kilo/kilo.jsonc"
if not cfg_path.is_file():
    raise SystemExit(0)
try:
    data = json.loads(cfg_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
provider = data.setdefault("provider", {})
orouter = provider.setdefault("openrouter", {})
orouter.setdefault("options", {})["apiKey"] = "{env:OPENROUTER_API_KEY}"
models = orouter.setdefault("models", {})
models["openrouter/auto"] = {"name": "OpenRouter Auto (retry)", "tool_call": True}
models["openrouter/free"] = {"name": "OpenRouter Free Router", "tool_call": True}
for model_id in free_models:
    models[model_id] = {"name": kilo_label(model_id), "tool_call": True}
data["model"] = f"openrouter/{PRIMARY}"
data["_secondBrainOpenRouterDefault"] = PRIMARY
cfg_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(cfg_path)
PY
}

# Agent skills — Next.js, NestJS, and official n8n (via MCP).
MCP_REGISTRY_DIR="$SUPPORT/mcp"

NESTJS_SKILLS=(
  nestjs-best-practices
  nestjs-production-api-contracts
  nestjs-workers-transports-ops
  nestjs-patterns
  nestjs-code-review
  nestjs
)
# xirothedev/skills — YAML bug in abstract field; installed via git + fix below
XIRO_NESTJS_MANUAL=(nestjs-production-api-contracts nestjs-workers-transports-ops)
NEXTJS_SKILLS=(
  nextjs-best-practices
  nextjs-secure-bff
  nextjs-production-platform
  nextjs-cache-components-runtime
  nextjs-nestjs-integration
)
# Source: https://github.com/n8n-io/skills (pair with instance-level n8n MCP)
N8N_SKILLS=(
  using-n8n-skills-official
  n8n-agents-official
  n8n-binary-and-data-official
  n8n-code-nodes-official
  n8n-credentials-and-security-official
  n8n-data-tables-official
  n8n-debugging-official
  n8n-error-handling-official
  n8n-expressions-official
  n8n-extending-mcp-official
  n8n-loops-official
  n8n-node-configuration-official
  n8n-subworkflows-official
  n8n-workflow-lifecycle-official
)
# Source: https://github.com/OpenRouterTeam/skills — model discovery & benchmark-backed selection
OPENROUTER_SKILLS=(
  using-openrouter-model-selection
  openrouter-models
  openrouter-benchmarks
)
# Curated priority for free models with tools + reliable agent/skill use (validated against OpenRouter API).
OPENROUTER_FREE_AGENT_MODEL_IDS=(
  poolside/laguna-s-2.1:free
  nvidia/nemotron-3-ultra-550b-a55b:free
  nvidia/nemotron-3-super-120b-a12b:free
  z-ai/glm-5.2:free
  nvidia/nemotron-3.5-lightning:free
  cohere/north-mini-code:free
  openai/gpt-oss-20b:free
  google/gemma-4-31b-it:free
  nvidia/nemotron-3-nano-30b-a3b:free
  poolside/laguna-xs-2.1:free
)
# Source: https://github.com/tjboudreaux/cc-thinking-skills (installed via --skill '*')
CC_THINKING_SKILLS=(
  thinking-bounded-rationality
  thinking-circle-of-competence
  thinking-cynefin
  thinking-effectuation
  thinking-first-principles
  thinking-five-whys-plus
  thinking-jobs-to-be-done
  thinking-kepner-tregoe
  thinking-lindy-effect
  thinking-map-territory
  thinking-margin-of-safety
  thinking-model-combination
  thinking-model-router
  thinking-ooda
  thinking-opportunity-cost
  thinking-pre-mortem
  thinking-probabilistic
  thinking-red-team
  thinking-reversibility
  thinking-scientific-method
  thinking-second-order
  thinking-socratic
  thinking-steel-manning
  thinking-systems
  thinking-theory-of-constraints
  thinking-thought-experiment
  thinking-triz
  thinking-via-negativa
)
# Frameworks, planning & meta-thinking (Desktop: thinking/)
THINKING_SKILLS=(
  thinking-circle-of-competence
  thinking-cynefin
  thinking-effectuation
  thinking-first-principles
  thinking-five-whys-plus
  thinking-jobs-to-be-done
  thinking-lindy-effect
  thinking-margin-of-safety
  thinking-model-combination
  thinking-model-router
  thinking-ooda
  thinking-opportunity-cost
  thinking-reversibility
  thinking-systems
  thinking-theory-of-constraints
  thinking-triz
  thinking-via-negativa
  ux-design-thinking
  design
  thinking-partner
  collision-zone-thinking
  planning-with-files
  planning-and-task-breakdown
  launch-planning
  planning-cadence
  defining-product-strategy
)
# Logical reasoning, argumentation & structured inference (Desktop: thinking/reasoning/)
REASONING_SKILLS=(
  thinking-socratic
  thinking-steel-manning
  thinking-scientific-method
  thinking-probabilistic
  thinking-red-team
  thinking-second-order
  thinking-thought-experiment
  thinking-bounded-rationality
  thinking-map-territory
  critical-thinking-logical-reasoning
  scientific-critical-thinking
  sequential-thinking
  good-thinking
  thought-based-reasoning
  recall-reasoning
)
# Assessment, trade-offs & quality judgment (Desktop: thinking/evaluation/)
EVALUATION_SKILLS=(
  thinking-pre-mortem
  thinking-kepner-tregoe
  evaluating-trade-offs
  high-stakes-decisions
  evaluation-methodology
  agent-self-evaluation
  scholar-evaluation
  heuristic-evaluation
)
AGENT_SKILLS=("${NESTJS_SKILLS[@]}" "${NEXTJS_SKILLS[@]}" "${N8N_SKILLS[@]}" \
  "${OPENROUTER_SKILLS[@]}" \
  "${THINKING_SKILLS[@]}" "${REASONING_SKILLS[@]}" "${EVALUATION_SKILLS[@]}")

sync_agent_skill_dirs() {
  local canonical="$HOME/.agents/skills"
  [[ -d "$canonical" ]] || return 0
  local agent_dir skill_dir skill_name
  for agent_dir in \
      "$HOME/.cursor/skills" \
      "$HOME/.cline/skills" \
      "$HOME/.roo/skills" \
      "$HOME/.kilocode/skills" \
      "$HOME/.config/opencode/skills"; do
    mkdir -p "$agent_dir"
    for skill_dir in "$canonical"/*; do
      [[ -d "$skill_dir" && -f "$skill_dir/SKILL.md" ]] || continue
      skill_name="$(basename "$skill_dir")"
      if [[ ! -f "$agent_dir/$skill_name/SKILL.md" ]]; then
        rm -rf "$agent_dir/$skill_name"
        cp -R "$skill_dir" "$agent_dir/$skill_name"
      fi
    done
  done
}

# openrouter/auto and openrouter/free are provider profiles (not installable skills).
# Write browsable reference stubs beside the OpenRouter skills on Desktop.
refresh_openrouter_free_agent_models() {
  local out_md="$DESKTOP_SKILLS_DIR/openrouter/free-tool-agent-models.md"
  local out_json="$SUPPORT/openrouter/free-tool-agent-models.json"
  local skill_ref="$HOME/.agents/skills/using-openrouter-model-selection/references"
  mkdir -p "$DESKTOP_SKILLS_DIR/openrouter" "$SUPPORT/openrouter" "$skill_ref"
  python3 - "$out_md" "$out_json" "$skill_ref/free-tool-agent-models.md" "${OPENROUTER_FREE_AGENT_MODEL_IDS[@]}" <<'PY'
import json, subprocess, sys
from datetime import date
from pathlib import Path

out_md, out_json, skill_ref = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
curated = sys.argv[4:]

CURATED_NOTES = {
    "poolside/laguna-s-2.1:free": "Best free pick for agent skills + MCP — coding/agent model, 1M context",
    "nvidia/nemotron-3-ultra-550b-a55b:free": "Largest free MoE; strong general agent fallback",
    "nvidia/nemotron-3-super-120b-a12b:free": "Large MoE; good for multi-step skills",
    "z-ai/glm-5.2:free": "1M context + reasoning params; planning-heavy skills",
    "nvidia/nemotron-3.5-lightning:free": "Fast Nemotron; tool-capable",
    "cohere/north-mini-code:free": "Code-oriented; lighter skill chains",
    "openai/gpt-oss-20b:free": "20B open-weight; general coding",
    "google/gemma-4-31b-it:free": "31B instruct; balanced free option",
    "nvidia/nemotron-3-nano-30b-a3b:free": "30B; smaller agent tasks",
    "poolside/laguna-xs-2.1:free": "Smaller Laguna; simple tool loops only",
}

AVOID_SMALL = {
    "liquid/lfm-2.5-2.6b:free",
    "nvidia/nemotron-nano-9b-v2:free",
    "nvidia/nemotron-nano-12b-v2-vl:free",
}

def fetch_models():
    try:
        raw = subprocess.check_output(
            ["curl", "-sf", "https://openrouter.ai/api/v1/models?supported_parameters=tools"],
            text=True,
            timeout=30,
        )
        return json.loads(raw).get("data") or []
    except Exception:
        return []

def is_free(m):
    pid = m.get("id", "")
    p = m.get("pricing") or {}
    prompt = float(p.get("prompt") or 0)
    completion = float(p.get("completion") or 0)
    return (prompt == 0 and completion == 0) or pid.endswith(":free") or "(free)" in (m.get("name") or "").lower()

models = fetch_models()
by_id = {m["id"]: m for m in models if "tools" in (m.get("supported_parameters") or []) and is_free(m)}

PRIMARY = curated[0] if curated else "poolside/laguna-s-2.1:free"

recommended, also_capable, unavailable = [], [], []
for mid in curated:
    note = CURATED_NOTES.get(mid, "Curated for tools + agent skills")
    if mid in by_id:
        m = by_id[mid]
        recommended.append({
            "id": mid,
            "name": m.get("name"),
            "context_length": m.get("context_length"),
            "note": note,
            "tier": "recommended",
        })
    else:
        unavailable.append({"id": mid, "note": note, "status": "not in live API (may be deprecated)"})

for mid, m in sorted(by_id.items(), key=lambda x: x[1].get("context_length") or 0, reverse=True):
    if mid in curated or mid in AVOID_SMALL:
        continue
    also_capable.append({
        "id": mid,
        "name": m.get("name"),
        "context_length": m.get("context_length"),
        "note": "Tool-capable free model — verify skill adherence for your task",
        "tier": "also_capable",
    })

doc = {
    "generated": date.today().isoformat(),
    "requirements": ["supported_parameters includes tools", "zero pricing or :free variant", "suitable for agent skills + MCP"],
    "default_profile": PRIMARY,
    "pinned_first_choice": recommended[0]["id"] if recommended else PRIMARY,
    "fallback_profile": "openrouter/auto",
    "workflow": [
        "First attempt: always use pinned free model (default Laguna S 2.1 free)",
        "User dislikes output: switch to openrouter/auto and rerun the same task",
        "Do not use Auto on first attempt unless user explicitly asks",
    ],
    "fallback_when": [
        "User asks to redo, improve, or says they dislike the free-model output",
        "No pinned free model is available or endpoints are degraded",
        "Agent drops tool calls or MCP fails on free model after user-approved retry path",
    ],
    "recommended": recommended,
    "also_capable": also_capable,
    "avoid_for_complex_skills": sorted(AVOID_SMALL),
    "unavailable_curated": unavailable,
}

out_json.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")

lines = [
    "# Free OpenRouter models — tools + agent skills",
    "",
    f"_Generated {doc['generated']} from OpenRouter `supported_parameters=tools` API + 2ⁿᵈ Brain curation._",
    "",
    "## Requirements",
    "",
    "- **`tools`** in `supported_parameters` (function/tool calling for Cline / Roo / Kilo MCP)",
    "- **$0** pricing or `:free` variant",
    "- **Reliable skills** — large enough to follow `thinking-model-router` and multi-step skill procedures",
    "",
    "## Selection order",
    "",
    "1. **First attempt:** pinned free model **`" + PRIMARY + "`** (default in Cline / Roo / Kilo)",
    "2. **All pinned free models** are preconfigured — pick another from the table to compare",
    "3. **User dislikes output:** switch to **`openrouter/auto`** and **rerun the same task** (same prompt/context)",
    "4. **Do not use Auto first** unless the user explicitly asks",
    "",
    f"See [openrouter-auto/PROFILE.md](openrouter-auto/PROFILE.md) for the Auto retry profile.",
    "",
    "## Recommended (tools + skills) — all pinned in agents",
    "",
    "| Priority | Model ID | Context | Notes |",
    "|----------|----------|---------|-------|",
]
for i, m in enumerate(recommended, 1):
    lines.append(f"| {i} | `{m['id']}` | {m.get('context_length', '?')} | {m['note']} |")

if unavailable:
    lines += ["", "## Curated but currently unavailable", ""]
    for u in unavailable:
        lines.append(f"- `{u['id']}` — {u['note']}")

if also_capable:
    lines += [
        "",
        "## Also tool-capable (verify for your task)",
        "",
        "| Model ID | Context | Notes |",
        "|----------|---------|-------|",
    ]
    for m in also_capable:
        lines.append(f"| `{m['id']}` | {m.get('context_length', '?')} | {m['note']} |")

lines += [
    "",
    "## Avoid for complex skill chains",
    "",
    "Too small or narrow for reliable multi-skill agent work:",
    "",
]
for mid in doc["avoid_for_complex_skills"]:
    lines.append(f"- `{mid}`")

lines += [
    "",
    "## Fallback: OpenRouter Auto (retry)",
    "",
    "When the **user dislikes the free-model output**, switch to **`openrouter/auto`** and rerun:",
    "",
]
for w in doc.get("workflow", []):
    lines.append(f"- {w}")
lines += ["", "Also use Auto when:", ""]
for w in doc["fallback_when"]:
    lines.append(f"- {w}")

lines += [
    "",
    "## Refresh live list",
    "",
    "```bash",
    "curl -s 'https://openrouter.ai/api/v1/models?supported_parameters=tools' | jq '[.data[] | select(.pricing.prompt==\"0\") | .id]'",
    "```",
    "",
    "Or re-run 2ⁿᵈ Brain setup (`agent_skills` step) to regenerate this file.",
    "",
]

md = "\n".join(lines) + "\n"
out_md.write_text(md, encoding="utf-8")
skill_ref.write_text(md, encoding="utf-8")
print(out_md)
PY
}

write_desktop_openrouter_profile_refs() {
  local base="$DESKTOP_SKILLS_DIR/openrouter"
  mkdir -p "$base/openrouter-free" "$base/openrouter-auto"
  cat > "$base/README.md" <<'EOF'
# OpenRouter

| Entry | Type | Purpose |
|-------|------|---------|
| `using-openrouter-model-selection/` | Skill | **Load first** — when to use Free vs Auto vs a specific model |
| `openrouter-models/` | Skill | Live catalog: price, context, latency, modalities |
| `openrouter-benchmarks/` | Skill | Benchmark-backed rankings by task type |
| `openrouter-free/` | **Profile** | **Default** — model ID `openrouter/free` (free models only) |
| `openrouter-auto/` | **Profile** | **Fallback** — model ID `openrouter/auto` when free models are insufficient |
| `free-tool-agent-models.md` | **List** | All pinned free models + Auto retry workflow |
| `pinned/` | **Profiles** | One folder per pinned free model |

**Profiles** are configured in Cline, Roo & Kilo (not copied to `~/.agents/skills/`).
Switch profiles in the agent UI or read `PROFILE.md` in each profile folder.
EOF
  refresh_openrouter_free_agent_models || true
  local mid slug dir
  mkdir -p "$base/pinned"
  for mid in "${OPENROUTER_FREE_AGENT_MODEL_IDS[@]}"; do
    slug="${mid//\//-}"
    slug="${slug//:/-}"
    slug="${slug//./-}"
    dir="$base/pinned/$slug"
    mkdir -p "$dir"
    cat > "$dir/PROFILE.md" <<EOF
# Pinned free model

| | |
|---|---|
| **Model ID** | \`$mid\` |
| **Default** | $([ "$mid" = "${OPENROUTER_FREE_AGENT_MODEL_IDS[0]}" ] && echo "Yes — first attempt" || echo "No — manual switch") |
| **Cline** | \`openrouter-free-${slug}\` (first: \`openrouter-laguna-free\`) |
| **Roo** | OpenRouter Free · ${mid#*/} |
| **Kilo** | \`openrouter/$mid\` |

Use **OpenRouter Auto (retry)** if the user dislikes output — rerun the same task on \`openrouter/auto\`.
EOF
  done
  cat > "$base/openrouter-free/PROFILE.md" <<'EOF'
# OpenRouter Free Router (random free + tools)

| | |
|---|---|
| **Model ID** | `openrouter/free` |
| **Cline provider** | `openrouter-free-router` |
| **Use for** | Random free model — **not the default** |

**2ⁿᵈ Brain default** is the **pinned** free models (start with `pinned/` → Laguna S 2.1).
If the user dislikes output, switch to **`openrouter-auto/`** and rerun the same task.
EOF
  cat > "$base/openrouter-auto/PROFILE.md" <<'EOF'
# OpenRouter Auto (retry profile)

| | |
|---|---|
| **Model ID** | `openrouter/auto` |
| **Cline provider** | `openrouter-auto` |
| **Roo profile** | OpenRouter Auto (retry) |
| **Kilo model** | `openrouter/openrouter/auto` |
| **Use for** | **After** the user dislikes free-model output — rerun the **same task** |

Do not use on first attempt unless the user explicitly asks for Auto.
EOF
}

setup_desktop_skills_library() {
  local canonical="$HOME/.agents/skills"
  [[ -d "$canonical" ]] || return 0

  ensure_desktop_brain_dir
  local category name skill_path link_path
  mkdir -p "$DESKTOP_SKILLS_DIR/nextjs" "$DESKTOP_SKILLS_DIR/nestjs" "$DESKTOP_SKILLS_DIR/n8n" \
    "$DESKTOP_SKILLS_DIR/openrouter" "$DESKTOP_SKILLS_DIR/cybersecurity" \
    "$DESKTOP_THINKING_DIR/frameworks" "$DESKTOP_THINKING_DIR/reasoning" "$DESKTOP_THINKING_DIR/evaluation"
  rm -rf "$DESKTOP_SKILLS_DIR/reasoning" "$DESKTOP_SKILLS_DIR/evaluation"
  find "$DESKTOP_THINKING_DIR" -maxdepth 1 -type l -delete 2>/dev/null || true
  local cat_dir
  for cat_dir in nextjs nestjs n8n openrouter; do
    find "$DESKTOP_SKILLS_DIR/$cat_dir" -maxdepth 1 -type l -delete 2>/dev/null || true
  done
  for cat_dir in frameworks reasoning evaluation; do
    find "$DESKTOP_THINKING_DIR/$cat_dir" -maxdepth 1 -type l -delete 2>/dev/null || true
  done

  for name in "${NEXTJS_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_SKILLS_DIR/nextjs/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${NESTJS_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_SKILLS_DIR/nestjs/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${N8N_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_SKILLS_DIR/n8n/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${OPENROUTER_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_SKILLS_DIR/openrouter/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${THINKING_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_THINKING_DIR/frameworks/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${REASONING_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_THINKING_DIR/reasoning/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  for name in "${EVALUATION_SKILLS[@]}"; do
    skill_path="$canonical/$name"
    [[ -d "$skill_path" ]] || continue
    link_path="$DESKTOP_THINKING_DIR/evaluation/$name"
    ln -sfn "$skill_path" "$link_path"
  done
  if [[ -d "$canonical/thinking-model-router" ]]; then
    ln -sfn "$canonical/thinking-model-router" "$DESKTOP_THINKING_DIR/thinking-model-router"
  fi

  write_desktop_openrouter_profile_refs

  cat > "$DESKTOP_SKILLS_DIR/README.md" <<'EOF'
# Agent Skills

Browseable library of agent skills installed by **2ⁿᵈ Brain** setup. Each subfolder
symlinks to the canonical copy in `~/.agents/skills/` (synced to Cursor, Cline, Roo & Kilo).

Open **`~/Desktop/2nd Brain`** in VS Code — this folder lives inside it.

| Folder | Skills |
|--------|--------|
| `nextjs/` | App Router 16, secure BFF, production platform, cache components |
| `nestjs/` | Best practices, API contracts, workers/transports, patterns, code review, Drizzle ORM |
| `n8n/` | Official n8n workflow skills — load `using-n8n-skills-official` first when using n8n MCP |
| `openrouter/` | Model skills + profiles; **`free-tool-agent-models.md`**; default Free, fallback Auto |
| `thinking/` | **Start with `thinking-model-router`** — then `frameworks/`, `reasoning/`, `evaluation/` |
| `mcp/` | MCP server registry — connect multiple n8n instances and other MCP servers |
| `cybersecurity/` | host: `mac-defend`, `mac-network-guard`, `overnight-sandbox`, `persistence-hygiene`, `vault-exposure`; data: `secrets-hygiene`, `data-boundary`, `prompt-injection-guard`, `mcp-trust`, `agent-hard-limits`; plus `security-review`, `skill-auditor`, `n8n-credentials-and-security-official` |
| `automation/` | `overnight-ops`, `autonomous-loop`, `caldav-local`, plus thinking/skill routers, planning/eval, n8n lifecycle/loops/agents, OpenRouter selection |

**n8n automations:** enable instance-level MCP in each n8n (Settings → Instance-level MCP),
add the instance in `mcp/registry.json`, put bearer tokens in `mcp/local.env`, then run
`mcp/sync-mcp.sh` to refresh Cursor & VS Code configs.
EOF

  cat > "$DESKTOP_BRAIN_DIR/README.md" <<'EOF'
# 2nd Brain

Desktop home for your **2ⁿᵈ Brain** agent setup, and the Obsidian vault root.

One folder, two views: VS Code shows the folder tree, Obsidian shows the same
files as a tag graph.

## Knowledge vault

| Path | Contents |
|------|----------|
| `Inbox/` | Quick captures waiting to be filed |
| `Notes/` | Lasting notes |
| `Daily/` | Daily notes (Periodic Notes + Calendar) |
| `Meetings/` | Meeting transcripts with speakers |
| `Captures/` | Screenshots and OCR text from the app |
| `Recordings/` | Screen and audio recordings, with their transcripts |
| `Attachments/` | PDFs and other files |
| `Templates/` | Templater templates |

The 2nd Brain app writes into `Captures/`, `Recordings/` and `Meetings/`
automatically, each item paired with a tagged markdown note so it shows up in
the Obsidian graph.

## Agent setup

| Path | Contents |
|------|----------|
| `Agent Skills/` | Next.js, NestJS, n8n, OpenRouter model selection, thinking (`frameworks/`, `reasoning/`, `evaluation/`), MCP |
| `AGENTS.md` | VS Code agent instructions — **always start with `thinking-model-router`** |
| `2nd Brain.code-workspace` | VS Code workspace |

`Agent Skills/` is excluded from Obsidian's search and graph so the skill docs
don't drown out your own notes.

VS Code is configured to start here. Double-click **`2nd Brain.code-workspace`** or run `code` with no arguments.

Search and graph tools: **engraph** (`engraph serve` MCP), indexed over this
folder. Continuous screen memory: **Screenpipe** (opt-in).
EOF

  mkdir -p "$DESKTOP_SKILLS_DIR/mcp"
  if [[ -f "$MCP_REGISTRY_DIR/registry.json" ]]; then
    cp -f "$MCP_REGISTRY_DIR/registry.json" "$DESKTOP_SKILLS_DIR/mcp/registry.json"
  fi
  [[ -f "$MCP_REGISTRY_DIR/local.env.example" ]] && \
    cp -f "$MCP_REGISTRY_DIR/local.env.example" "$DESKTOP_SKILLS_DIR/mcp/local.env.example"
  [[ -x "$MCP_REGISTRY_DIR/sync-mcp.sh" ]] && \
    cp -f "$MCP_REGISTRY_DIR/sync-mcp.sh" "$DESKTOP_SKILLS_DIR/mcp/sync-mcp.sh"
  [[ -f "$MCP_REGISTRY_DIR/sync-mcp-registry.py" ]] && \
    cp -f "$MCP_REGISTRY_DIR/sync-mcp-registry.py" "$DESKTOP_SKILLS_DIR/mcp/sync-mcp-registry.py"
  [[ -f "$MCP_REGISTRY_DIR/README.md" ]] && \
    cp -f "$MCP_REGISTRY_DIR/README.md" "$DESKTOP_SKILLS_DIR/mcp/README.md"
}

agent_skills_ready() {
  local canonical="$HOME/.agents/skills" name
  for name in "${AGENT_SKILLS[@]}"; do
    [[ -f "$canonical/$name/SKILL.md" ]] || return 1
  done
  return 0
}

# xirothedev NestJS skills with colons in YAML abstract (skills CLI skips them).
install_xirothedev_nestjs_manual_skills() {
  if ! have git; then
    return 0
  fi
  python3 - "${XIRO_NESTJS_MANUAL[@]}" <<'PY'
import re, shutil, subprocess, sys, tempfile
from pathlib import Path

names = sys.argv[1:]
canonical = Path.home() / ".agents/skills"
canonical.mkdir(parents=True, exist_ok=True)

tmpdir = Path(tempfile.mkdtemp(prefix="secondbrain-skills-"))
try:
    subprocess.run(
        ["git", "clone", "--depth", "1", "https://github.com/xirothedev/skills.git", str(tmpdir / "repo")],
        check=True,
        capture_output=True,
    )
    repo = tmpdir / "repo" / "skills"
    for name in names:
        src = repo / name
        if not (src / "SKILL.md").is_file():
            continue
        dst = canonical / name
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
        text = (dst / "SKILL.md").read_text(encoding="utf-8")
        text = re.sub(r"^(  abstract: )(Focused.*)$", r'\1"\2"', text, flags=re.M)
        (dst / "SKILL.md").write_text(text, encoding="utf-8")
        print(name)
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
PY
}

install_openrouter_router_skill() {
  local dest="$HOME/.agents/skills/using-openrouter-model-selection"
  mkdir -p "$dest/references"
  cat > "$dest/SKILL.md" <<'EOF'
---
name: using-openrouter-model-selection
description: Use when choosing an OpenRouter model for a task, comparing models, picking a Cline/Roo/Kilo profile, or deciding between openrouter/auto, openrouter/free, and a specific model ID. Load this before openrouter-models or openrouter-benchmarks.
---

# OpenRouter Model Selection

Read **`references/free-tool-agent-models.md`** (or `Agent Skills/openrouter/free-tool-agent-models.md`) for the live curated list.

## Workflow (mandatory)

1. **First attempt:** always use the **default pinned free model** (`poolside/laguna-s-2.1:free` — preconfigured in Cline / Roo / Kilo).
2. **User dislikes output** (redo, improve, quality bad): switch to **`openrouter/auto`**, tell the user, and **rerun the same task** with the same prompt/context.
3. **Do not use Auto first** unless the user explicitly requests it.
4. **Manual switch:** user can pick any other **pinned free** profile from `free-tool-agent-models.md` before asking for Auto.

## Built-in profiles

| Model ID | Profile | Use when |
|----------|---------|----------|
| `poolside/laguna-s-2.1:free` | **Default pinned free** | Every first attempt |
| Other IDs in `free-tool-agent-models.md` | **Pinned free** (preconfigured) | User wants a different free model |
| `openrouter/auto` | **OpenRouter Auto (retry)** | User disliked free output — rerun same task |
| `openrouter/free` | Free router (random) | Optional — not the default |

## Procedure

1. Confirm cloud/OpenRouter is in use; load thinking skills as usual.
2. **Run on pinned free default** — do not start on Auto.
3. If the user is unhappy with the result → **switch to Auto and rerun** (same instructions).
4. Use **openrouter-models** to verify availability if a pinned model errors.
5. Never switch to Auto silently on the first attempt.

Set `OPENROUTER_API_KEY` for provider access.
EOF
  # Copy list if already generated on Desktop
  if [[ -f "$DESKTOP_SKILLS_DIR/openrouter/free-tool-agent-models.md" ]]; then
    cp -f "$DESKTOP_SKILLS_DIR/openrouter/free-tool-agent-models.md" "$dest/references/free-tool-agent-models.md"
  fi
}

install_agent_skills() {
  if ! have npx; then
    emit agent_skills skipped "Node/npx required for skill packs"
    return 0
  fi
  skill_missing() {
    local name
    for name in "$@"; do
      [[ -f "$HOME/.agents/skills/$name/SKILL.md" ]] || return 0
    done
    return 1
  }
  run_npx_pack() {
    net_wait || return 1
    local n=0
    while (( n < 4 )); do
      if "$@"; then return 0; fi
      n=$((n + 1))
      net_wait || true
      sleep $((n * 4))
    done
    return 1
  }
  local agents=(--agent cursor --agent cline --agent roo --agent kilo --agent opencode)
  local npx_web npx_n8n npx_nest npx_think name

  if skill_missing nestjs-best-practices "${NEXTJS_SKILLS[@]}"; then
    npx_web=(npx --yes skills add xirothedev/skills --global -y --copy --skill nestjs-best-practices)
    for name in "${NEXTJS_SKILLS[@]}"; do
      npx_web+=(--skill "$name")
    done
    npx_web+=("${agents[@]}")
    run_npx_pack "${npx_web[@]}" >&2 || true
  fi

  if skill_missing "${XIRO_NESTJS_MANUAL[@]}"; then
    install_xirothedev_nestjs_manual_skills >&2 || true
  fi

  if skill_missing nestjs-patterns; then
    npx_nest=(npx --yes skills add affaan-m/ecc --global -y --copy --skill nestjs-patterns)
    npx_nest+=("${agents[@]}")
    run_npx_pack "${npx_nest[@]}" >&2 || true
  fi

  if skill_missing nestjs nestjs-code-review; then
    npx_nest=(npx --yes skills add giuseppe-trisciuoglio/developer-kit --global -y --copy \
      --skill nestjs --skill nestjs-code-review)
    npx_nest+=("${agents[@]}")
    run_npx_pack "${npx_nest[@]}" >&2 || true
  fi

  if skill_missing thinking-model-router; then
    npx_think=(npx --yes skills add tjboudreaux/cc-thinking-skills --global -y --copy --skill '*')
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing ux-design-thinking; then
    npx_think=(npx --yes skills add asgard-ai-platform/skills --global -y --copy --skill ux-design-thinking)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing design; then
    npx_think=(npx --yes skills add neurofoo/agent-skills --global -y --copy --skill design)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing critical-thinking-logical-reasoning; then
    npx_think=(npx --yes skills add sammcj/agentic-coding --global -y --copy \
      --skill critical-thinking-logical-reasoning)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing scientific-critical-thinking; then
    npx_think=(npx --yes skills add k-dense-ai/scientific-agent-skills --global -y --copy \
      --skill scientific-critical-thinking)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing good-thinking; then
    npx_think=(npx --yes skills add jwynia/agent-skills --global -y --copy --skill good-thinking)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing thinking-partner; then
    npx_think=(npx --yes skills add mattnowdev/thinking-partner --global -y --copy --skill thinking-partner)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing sequential-thinking; then
    npx_think=(npx --yes skills add mrgoonie/claudekit-skills --global -y --copy --skill sequential-thinking)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing collision-zone-thinking; then
    npx_think=(npx --yes skills add obra/superpowers-skills --global -y --copy --skill "collision-zone thinking")
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing planning-with-files; then
    npx_think=(npx --yes skills add othmanadi/planning-with-files --global -y --copy --skill planning-with-files)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing planning-and-task-breakdown; then
    npx_think=(npx --yes skills add addyosmani/agent-skills --global -y --copy --skill planning-and-task-breakdown)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing evaluating-trade-offs high-stakes-decisions launch-planning planning-cadence defining-product-strategy; then
    npx_think=(npx --yes skills add refoundai/lenny-skills --global -y --copy \
      --skill evaluating-trade-offs --skill high-stakes-decisions \
      --skill launch-planning --skill planning-cadence --skill defining-product-strategy)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing thought-based-reasoning; then
    npx_think=(npx --yes skills add neolabhq/context-engineering-kit --global -y --copy --skill thought-based-reasoning)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing recall-reasoning; then
    npx_think=(npx --yes skills add parcadei/continuous-claude-v3 --global -y --copy --skill recall-reasoning)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing evaluation-methodology; then
    npx_think=(npx --yes skills add wshobson/agents --global -y --copy --skill evaluation-methodology)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing agent-self-evaluation scholar-evaluation; then
    npx_think=(npx --yes skills add affaan-m/ecc --global -y --copy \
      --skill agent-self-evaluation --skill scholar-evaluation)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing heuristic-evaluation; then
    npx_think=(npx --yes skills add owl-listener/designer-skills --global -y --copy --skill heuristic-evaluation)
    npx_think+=("${agents[@]}")
    run_npx_pack "${npx_think[@]}" >&2 || true
  fi

  if skill_missing "${N8N_SKILLS[@]}"; then
    npx_n8n=(npx --yes skills add n8n-io/skills --global -y --copy)
    for name in "${N8N_SKILLS[@]}"; do
      npx_n8n+=(--skill "$name")
    done
    npx_n8n+=("${agents[@]}")
    run_npx_pack "${npx_n8n[@]}" >&2 || true
  fi

  install_openrouter_router_skill >&2 || true

  if skill_missing openrouter-models openrouter-benchmarks; then
    local npx_or
    npx_or=(npx --yes skills add openrouterteam/skills --global -y --copy)
    for name in openrouter-models openrouter-benchmarks; do
      npx_or+=(--skill "$name")
    done
    npx_or+=("${agents[@]}")
    run_npx_pack "${npx_or[@]}" >&2 || true
  fi

  refresh_openrouter_free_agent_models || true
  sync_agent_skill_dirs
}

ensure_openrouter_skills() {
  local canonical="$HOME/.agents/skills" name missing=0
  for name in "${OPENROUTER_SKILLS[@]}"; do
    [[ -f "$canonical/$name/SKILL.md" ]] || missing=1
  done
  [[ "$missing" -eq 0 ]] && return 0
  installing || return 1
  if ! have npx; then
    return 1
  fi
  local agents=(--agent cursor --agent cline --agent roo --agent kilo --agent opencode)
  install_openrouter_router_skill >&2 || true
  local npx_or
  npx_or=(npx --yes skills add openrouterteam/skills --global -y --copy \
    --skill openrouter-models --skill openrouter-benchmarks)
  npx_or+=("${agents[@]}")
  "${npx_or[@]}" >&2 || true
  refresh_openrouter_free_agent_models || true
  sync_agent_skill_dirs
}

step_agent_skills() {
  emit agent_skills checking "Looking for Next.js, NestJS, n8n, OpenRouter, thinking, reasoning & evaluation skills"
  if agent_skills_ready; then
    ensure_openrouter_skills || true
    sync_agent_skill_dirs
    seed_mcp_registry || true
    apply_mcp_registry || true
    setup_desktop_skills_library
    write_vscode_agent_rules || true
    emit agent_skills ok "Skills library on Desktop + MCP registry ready"
    return 0
  fi
  if ! installing; then
    fail agent_skills "Next.js/NestJS/n8n/OpenRouter/thinking/reasoning/evaluation skills not installed"
    return 1
  fi
  emit agent_skills installing "Installing Next.js, NestJS, n8n, OpenRouter, thinking, reasoning & evaluation skills"
  install_agent_skills
  seed_mcp_registry || true
  apply_mcp_registry || true
  setup_desktop_skills_library
  write_vscode_agent_rules || true
  if agent_skills_ready; then
    emit agent_skills ok "Desktop skills library + n8n MCP registry ready"
  else
    fail agent_skills "Could not install all skill packs"
  fi
}

# MCP registry — one manifest for multiple n8n instances + other MCP servers.
# Tokens live in $MCP_REGISTRY_DIR/local.env (never in registry.json on Desktop).
seed_mcp_registry() {
  local vault="${SECOND_BRAIN_VAULT:-$DESKTOP_BRAIN_DIR}"
  local cursor_mcp="$HOME/.cursor/mcp.json"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$MCP_REGISTRY_DIR" "$DESKTOP_SKILLS_DIR/mcp"
  cp -f "$script_dir/sync-mcp-registry.py" "$MCP_REGISTRY_DIR/sync-mcp-registry.py"
  chmod +x "$MCP_REGISTRY_DIR/sync-mcp-registry.py"
  python3 - "$MCP_REGISTRY_DIR" "$cursor_mcp" "$vault" <<'PY'
import json, os, re, sys

reg_dir, cursor_path, vault = sys.argv[1:4]
reg_path = os.path.join(reg_dir, "registry.json")
env_example = os.path.join(reg_dir, "local.env.example")
local_env = os.path.join(reg_dir, "local.env")

def load_json(path):
    if not os.path.isfile(path):
        return {}
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"(?m)^\s*//.*?$", "", text)
    text = re.sub(r",\s*}", "}", text)
    text = re.sub(r",\s*]", "]", text)
    try:
        return json.loads(text)
    except Exception:
        return {}

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    s = re.sub(r"^n8n[-_]", "", s)
    return s or "instance"

def token_env_name(inst_id):
    base = inst_id.upper().replace("-", "_")
    if not base.startswith("N8N_"):
        base = f"N8N_{base}"
    if not base.endswith("_MCP_TOKEN"):
        base = f"{base}_MCP_TOKEN"
    return base

def extract_bearer(val):
    if isinstance(val, dict):
        headers = val.get("headers") or {}
        auth = headers.get("Authorization") or headers.get("authorization") or ""
        if auth.lower().startswith("bearer "):
            return auth[7:].strip(), "http"
        url = val.get("url") or ""
        if url:
            return None, "http"
    args = val.get("args") if isinstance(val, dict) else None
    if args:
        for i, a in enumerate(args):
            if isinstance(a, str) and a.lower().startswith("authorization:bearer "):
                return a.split(" ", 1)[1].strip(), "supergateway"
            if a == "--streamableHttp" and i + 1 < len(args):
                pass
    return None, "supergateway"

def mcp_url(val):
    if isinstance(val, dict):
        if val.get("url"):
            return val["url"]
        args = val.get("args") or []
        for i, a in enumerate(args):
            if a in ("--streamableHttp", "--streamable-http") and i + 1 < len(args):
                return args[i + 1]
    return ""

if os.path.isfile(reg_path):
    registry = load_json(reg_path)
else:
    registry = {
        "version": 1,
        "n8n_instances": [],
        "servers": [
            {
                "id": "engraph",
                "label": "Engraph vault search",
                "enabled": True,
                "transport": "stdio",
                "command": "engraph",
                "args": ["serve"],
                "env": {"ENGRAPH_VAULT": vault},
            },
            {
                "id": "screenpipe",
                "label": "Screenpipe screen memory",
                "enabled": True,
                "transport": "stdio",
                "command": "npx",
                "args": ["-y", "screenpipe-mcp@latest"],
            },
        ],
    }

    cursor = load_json(cursor_path)
    seen_urls = set()
    env_lines = []
    existing_env = {}
    if os.path.isfile(local_env):
        for line in open(local_env, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                existing_env[k.strip()] = v.strip()

    for key, val in (cursor.get("mcpServers") or cursor.get("servers") or {}).items():
        if "n8n" not in key.lower():
            continue
        url = mcp_url(val)
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)
        token, transport = extract_bearer(val)
        inst_id = slug(key) or slug(url.split("//")[-1].split("/")[0])
        token_env = token_env_name(inst_id)
        registry["n8n_instances"].append({
            "id": inst_id,
            "label": key,
            "url": url,
            "transport": transport,
            "token_env": token_env,
            "enabled": True,
        })
        if token and token_env not in existing_env:
            env_lines.append(f"{token_env}={token}")

    if not registry["n8n_instances"]:
        registry["n8n_instances"].append({
            "id": "n8n-example",
            "label": "My n8n instance",
            "url": "https://your-instance.app.n8n.cloud/mcp-server/http",
            "transport": "http",
            "token_env": "N8N_EXAMPLE_MCP_TOKEN",
            "enabled": False,
        })

    with open(reg_path, "w", encoding="utf-8") as f:
        json.dump(registry, f, indent=2)
        f.write("\n")

    example = ["# Bearer tokens for n8n MCP (Settings → Instance-level MCP in n8n)", ""]
    for inst in registry["n8n_instances"]:
        example.append(f"# {inst.get('label', inst['id'])}")
        example.append(f"{inst['token_env']}=")
        example.append("")
    with open(env_example, "w", encoding="utf-8") as f:
        f.write("\n".join(example))

    if env_lines:
        with open(local_env, "a", encoding="utf-8") as f:
            if os.path.getsize(local_env) > 0:
                f.write("\n")
            f.write("\n".join(env_lines) + "\n")
        os.chmod(local_env, 0o600)

print(reg_path)
PY

  cat > "$MCP_REGISTRY_DIR/sync-mcp.sh" <<'SYNC'
#!/usr/bin/env bash
# Refresh MCP configs from the registry (multiple n8n instances + other servers).
set -euo pipefail
REG_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$REG_DIR/local.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
export MCP_REGISTRY_DIR="$REG_DIR"
export SECOND_BRAIN_VAULT="${SECOND_BRAIN_VAULT:-$DESKTOP_BRAIN_DIR}"
exec python3 "$REG_DIR/sync-mcp-registry.py" "$REG_DIR"
SYNC
  chmod +x "$MCP_REGISTRY_DIR/sync-mcp.sh"

  cat > "$MCP_REGISTRY_DIR/README.md" <<'EOF'
# MCP Registry

One manifest drives **multiple n8n instances** (and other MCP servers) for Cursor, Cline, Roo, and Kilo.

## Add an n8n instance

1. In n8n: **Settings → Instance-level MCP** → enable and copy the bearer token.
2. Edit `registry.json` — add an entry under `n8n_instances`:
   ```json
   {
     "id": "n8n-acme",
     "label": "Acme n8n Cloud",
     "url": "https://acme.app.n8n.cloud/mcp-server/http",
     "transport": "http",
     "token_env": "N8N_ACME_MCP_TOKEN",
     "enabled": true
   }
   ```
3. Put the token in `local.env`:
   ```
   N8N_ACME_MCP_TOKEN=your-bearer-token
   ```
4. Run `./sync-mcp.sh`, then merge `~/Library/Application Support/SecondBrain/mcp/cursor-mcp.generated.json`
   into `~/.cursor/mcp.json` (or paste individual server blocks).

## Other MCP servers

Add objects under `servers` in `registry.json` (stdio command or extend the sync script for HTTP).

Use official n8n skills from the Desktop `n8n/` folder — start with `using-n8n-skills-official`.
EOF
  cp -f "$MCP_REGISTRY_DIR/README.md" "$DESKTOP_SKILLS_DIR/mcp/README.md" 2>/dev/null || true
}

apply_mcp_registry() {
  local vault="${SECOND_BRAIN_VAULT:-$DESKTOP_BRAIN_DIR}"
  mkdir -p "$MCP_REGISTRY_DIR"
  [[ -f "$MCP_REGISTRY_DIR/registry.json" ]] || seed_mcp_registry
  if [[ -f "$MCP_REGISTRY_DIR/local.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$MCP_REGISTRY_DIR/local.env"
    set +a
  fi
  MCP_REGISTRY_DIR="$MCP_REGISTRY_DIR" SECOND_BRAIN_VAULT="$vault" \
    python3 "$MCP_REGISTRY_DIR/sync-mcp-registry.py" "$MCP_REGISTRY_DIR"
}

write_vscode_mcp_config() {
  seed_mcp_registry || true
  apply_mcp_registry || true
}

step_mcp() {
  emit mcp checking "Syncing MCP registry (n8n instances + engraph + screenpipe)"
  seed_mcp_registry || true
  if apply_mcp_registry; then
    setup_desktop_skills_library 2>/dev/null || true
    emit mcp ok "MCP configs synced from registry"
  else
    fail mcp "Could not apply MCP registry"
  fi
}

# --- VS Code + Cline + Roo Code + Kilo Code + AutoGit -----------------------
step_vscode() {
  emit vscode checking "Looking for VS Code + Cline + Roo Code + Kilo Code + AutoGit"
  local code_bin=""
  code_bin="$(find_code_bin || true)"

  vscode_has() {
    echo "$1" | grep -qiE "^$2$"
  }

  vscode_install_ext() {
    local id="$1" label="$2"
    local attempt out rc=0
    for attempt in 1 2 3; do
      if out="$("$code_bin" --install-extension "$id" --force 2>&1)"; then
        echo "$out" >&2
        exts="$("$code_bin" --list-extensions 2>/dev/null || true)"
        if vscode_has "$exts" "${id//./\\.}"; then
          return 0
        fi
      else
        rc=$?
        echo "$out" >&2
      fi
      sleep 2
    done
    emit vscode failed "Could not install $label ($id)"
    return "$rc"
  }

  local exts=""
  if [[ -n "$code_bin" && -x "$code_bin" ]]; then
    exts="$("$code_bin" --list-extensions 2>/dev/null || true)"
  fi

  local has_cline=0 has_roo=0 has_kilo=0 has_autogit=0
  vscode_has "$exts" 'saoudrizwan\.claude-dev' && has_cline=1
  vscode_has "$exts" 'rooveterinaryinc\.roo-cline' && has_roo=1
  vscode_has "$exts" 'kilocode\.kilo-code' && has_kilo=1
  vscode_has "$exts" 'carlocardella\.vscode-autogit' && has_autogit=1

  if [[ -n "$code_bin" && "$has_cline" -eq 1 && "$has_roo" -eq 1 && "$has_kilo" -eq 1 && "$has_autogit" -eq 1 ]]; then
    write_vscode_ai_profiles || true
    write_kilo_omlx_config || true
    write_vscode_mcp_config || true
    install_agent_skills || true
    configure_vscode_second_brain || true
    emit vscode ok "VS Code + Cline + Roo Code + Kilo Code + AutoGit ready (opens ~/Desktop/2nd Brain)"
    return 0
  fi
  if ! installing; then
    if [[ -z "$code_bin" ]]; then fail vscode "VS Code not installed"
    elif [[ "$has_cline" -eq 0 ]]; then fail vscode "Need Cline extension (saoudrizwan.claude-dev)"
    elif [[ "$has_roo" -eq 0 ]]; then fail vscode "Need Roo Code extension (RooVeterinaryInc.roo-cline)"
    elif [[ "$has_kilo" -eq 0 ]]; then fail vscode "Need Kilo Code extension (kilocode.kilo-code)"
    else fail vscode "Need AutoGit extension"
    fi
    return 1
  fi

  if [[ -z "$code_bin" || ! -x "$code_bin" ]]; then
    emit vscode installing "Installing Visual Studio Code"
    if have brew; then
      brew install --cask visual-studio-code >&2
    fi
    code_bin="$(find_code_bin || true)"
  fi
  if [[ -z "$code_bin" || ! -x "$code_bin" ]]; then
    code_bin="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  fi
  if [[ ! -x "$code_bin" ]]; then
    fail vscode "VS Code installed but the 'code' CLI is missing"
    return 1
  fi

  emit vscode installing "Installing Cline, Roo Code, Kilo Code, AutoGit (+ Primer optional)"
  vscode_install_ext saoudrizwan.claude-dev "Cline" || true
  vscode_install_ext RooVeterinaryInc.roo-cline "Roo Code" || true
  vscode_install_ext kilocode.Kilo-Code "Kilo Code" || true
  vscode_install_ext carlocardella.vscode-autogit "AutoGit" || true
  # Primer is helpful but not required for readiness.
  "$code_bin" --install-extension digitarald.primer-vscode --pre-release --force >&2 \
    || "$code_bin" --install-extension digitarald.primer-vscode --force >&2 || true
  write_vscode_ai_profiles || true
  write_kilo_omlx_config || true
  write_vscode_mcp_config || true
  install_agent_skills || true
  configure_vscode_second_brain || true

  exts="$("$code_bin" --list-extensions 2>/dev/null || true)"
  has_cline=0; has_roo=0; has_kilo=0; has_autogit=0
  vscode_has "$exts" 'saoudrizwan\.claude-dev' && has_cline=1
  vscode_has "$exts" 'rooveterinaryinc\.roo-cline' && has_roo=1
  vscode_has "$exts" 'kilocode\.kilo-code' && has_kilo=1
  vscode_has "$exts" 'carlocardella\.vscode-autogit' && has_autogit=1

  if [[ "$has_cline" -eq 1 && "$has_roo" -eq 1 && "$has_kilo" -eq 1 && "$has_autogit" -eq 1 ]]; then
    emit vscode ok "VS Code + Cline + Roo Code + Kilo Code + AutoGit ready (opens ~/Desktop/2nd Brain)"
  elif [[ "$has_cline" -eq 1 && "$has_roo" -eq 1 && "$has_kilo" -eq 1 ]]; then
    emit vscode ok "VS Code + Cline + Roo Code + Kilo Code ready (AutoGit incomplete)"
  elif [[ "$has_cline" -eq 1 && "$has_roo" -eq 1 ]]; then
    emit vscode ok "VS Code + Cline + Roo Code ready (Kilo Code incomplete)"
  elif [[ "$has_cline" -eq 1 ]]; then
    emit vscode ok "VS Code + Cline ready (Roo Code / Kilo Code incomplete)"
  else
    fail vscode "VS Code is installed but Cline could not be added"
  fi
}

# --- Screenpipe (continuous screen + audio memory) -------------------------
step_screenpipe() {
  emit screenpipe checking "Looking for Screenpipe"
  local sp_dir="$SUPPORT/screenpipe"
  mkdir -p "$sp_dir"

  if have screenpipe \
      || [[ -x "$BIN_DIR/screenpipe" ]] \
      || [[ -x "$BIN_DIR/screenpipe-start" ]] \
      || [[ -d "$HOME/.screenpipe" ]] \
      || [[ -d "/Applications/Screenpipe.app" ]]; then
    emit screenpipe ok "Screenpipe present"
    return 0
  fi
  if ! installing; then
    fail screenpipe "Screenpipe not installed"
    return 1
  fi

  emit screenpipe installing "Pulling Screenpipe CLI (npx) for continuous local memory"
  if have npm; then
    # Prefetch the package so later `npx -y screenpipe` / MCP is offline-friendly.
    npm pack screenpipe@latest --pack-destination "$sp_dir" >&2 || true
  fi
  if have npx; then
    # Smoke-fetch the binary; do NOT start recording during setup.
    if npx -y screenpipe@latest --version >&2; then
      cat > "$BIN_DIR/screenpipe-start" <<'EOF'
#!/usr/bin/env bash
# Start continuous local screen+audio memory (opt-in; not auto-launched by 2ⁿᵈ Brain).
exec npx -y screenpipe@latest record "$@"
EOF
      chmod +x "$BIN_DIR/screenpipe-start"
      emit screenpipe ok "Screenpipe CLI ready (run $BIN_DIR/screenpipe-start to record)"
      return 0
    fi
  fi
  # Optional always-on memory — don't block the rest of setup.
  emit screenpipe skipped "Install later from https://screenpi.pe/onboarding (or rerun setup)"
}



# --- Local TTS (Piper) -----------------------------------------------------
step_tts() {
  emit tts checking "Looking for local TTS"
  if have piper || have piper-tts || [[ -x "$BIN_DIR/piper" ]]; then
    emit tts ok "Piper TTS present"
    return 0
  fi
  # macOS always has `say`; treat as acceptable baseline in check mode.
  if ! installing; then
    if have say; then
      emit tts ok "System TTS (say) available — Piper optional"
      return 0
    fi
    fail tts "No TTS found"
    return 1
  fi

  emit tts installing "Installing Piper TTS (local neural voices)"
  if have brew; then
    brew install piper-tts >&2 || brew install rhasspy/piper/piper >&2 || true
  fi
  if have piper || have piper-tts; then
    emit tts ok "Piper TTS installed"
    return 0
  fi

  # Fallback: pip install into support venv
  if find_python 2>/dev/null || have python3; then
    local py="${PY:-$(command -v python3)}"
    local venv="$SUPPORT/tts-venv"
    "$py" -m venv "$venv" >&2 || true
    if [[ -x "$venv/bin/pip" ]]; then
      "$venv/bin/pip" install -U pip piper-tts >&2 || true
      if [[ -x "$venv/bin/piper" ]] || "$venv/bin/python" -c "import piper" 2>/dev/null; then
        ln -sf "$venv/bin/piper" "$BIN_DIR/piper" 2>/dev/null || true
        emit tts ok "Piper TTS in $venv"
        return 0
      fi
    fi
  fi

  if have say; then
    emit tts ok "System TTS (say) — Piper install skipped"
  else
    fail tts "Could not install Piper TTS"
  fi
}

# --- Knowledge vault + engraph (graph / hybrid search MCP) -----------------
step_brain() {
  local vault="${SECOND_BRAIN_VAULT:-$DESKTOP_BRAIN_DIR}"
  emit brain checking "Looking for knowledge vault + engraph"
  # Capitalised to match how Obsidian displays them; the app writes here too.
  mkdir -p "$vault"/{Inbox,Notes,Daily,Meetings,Captures,Recordings,Attachments,Templates}

  local has_engraph=0
  have engraph && has_engraph=1

  if [[ "$has_engraph" -eq 1 && -d "$vault" ]]; then
    write_vscode_mcp_config || true
    emit brain ok "Vault at $vault + engraph"
    return 0
  fi
  if ! installing; then
    if [[ -d "$vault" ]]; then
      if [[ "$has_engraph" -eq 1 ]]; then
        emit brain ok "Vault at $vault + engraph"
      else
        emit brain ok "Vault at $vault (engraph not installed yet)"
      fi
      return 0
    fi
    fail brain "Vault missing at $vault"
    return 1
  fi

  emit brain installing "Installing engraph (local knowledge graph + MCP)"
  # Prefer a prebuilt release binary — Homebrew often builds from source (Rust/LLVM).
  if ! have engraph && [[ ! -x "$BIN_DIR/engraph" ]]; then
    local arch url tmp bin
    arch="$(uname -m)"
    tmp="$(mktemp -d)"
    if [[ "$arch" == "arm64" ]]; then
      url="https://github.com/devwhodevs/engraph/releases/latest/download/engraph-macos-arm64.tar.gz"
    else
      url=""
    fi
    local tarball="$DOWNLOADS_DIR/engraph-macos-${arch}.tgz"
    if [[ -n "$url" ]] && net_fetch "$url" "$tarball"; then
      tar -xzf "$tarball" -C "$tmp" >&2 || true
      bin="$(find "$tmp" -type f -name engraph | head -1)"
      if [[ -n "$bin" ]]; then
        cp "$bin" "$BIN_DIR/engraph"
        chmod +x "$BIN_DIR/engraph"
      fi
    fi
    # If the fixed URL missed, resolve the right asset from the GitHub API.
    if [[ ! -x "$BIN_DIR/engraph" ]]; then
      python3 - "$tmp" "$arch" "$BIN_DIR" <<'PY' >&2 || true
import json, os, sys, urllib.request, tarfile, zipfile
tmpdir, arch, bindir = sys.argv[1:4]
api = "https://api.github.com/repos/devwhodevs/engraph/releases/latest"
with urllib.request.urlopen(api, timeout=30) as r:
    rel = json.load(r)
for asset in rel.get("assets", []):
    name = asset["name"].lower()
    if "macos" not in name and "darwin" not in name and "apple" not in name:
        continue
    if arch == "arm64" and not any(x in name for x in ("arm64", "aarch64")):
        continue
    if arch != "arm64" and not any(x in name for x in ("x86_64", "amd64", "x64")):
        continue
    print(f"Downloading {asset['name']}…")
    data = urllib.request.urlopen(asset["browser_download_url"], timeout=120).read()
    path = os.path.join(tmpdir, asset["name"])
    open(path, "wb").write(data)
    if name.endswith((".tar.gz", ".tgz")):
        with tarfile.open(path) as tf:
            tf.extractall(tmpdir)
    elif name.endswith(".zip"):
        with zipfile.ZipFile(path) as zf:
            zf.extractall(tmpdir)
    for root, _, files in os.walk(tmpdir):
        for f in files:
            if f == "engraph":
                dest = os.path.join(bindir, "engraph")
                open(dest, "wb").write(open(os.path.join(root, f), "rb").read())
                os.chmod(dest, 0o755)
                print(dest)
                raise SystemExit(0)
print("No matching engraph macOS asset found", file=sys.stderr)
PY
    fi
    rm -rf "$tmp"
  fi

  if have engraph || [[ -x "$BIN_DIR/engraph" ]]; then
    # Expose on PATH for MCP clients and terminals.
    mkdir -p "$HOME/.local/bin"
    if [[ -x "$BIN_DIR/engraph" ]]; then
      ln -sf "$BIN_DIR/engraph" "$HOME/.local/bin/engraph"
    fi
    # Best-effort first index (non-fatal if models still downloading)
    (engraph index "$vault" >&2 || "$BIN_DIR/engraph" index "$vault" >&2) || true
    write_vscode_mcp_config || true
    # Snippet for Cursor — do not rewrite ~/.cursor/mcp.json (may contain comments).
    mkdir -p "$SUPPORT"
    cat > "$SUPPORT/cursor-engraph-mcp.snippet.json" <<EOF
{
  "engraph": {
    "command": "engraph",
    "args": ["serve"],
    "env": { "ENGRAPH_VAULT": "$vault" }
  }
}
EOF
    emit brain ok "Vault at $vault + engraph"
  else
    # Vault alone is still useful
    emit brain ok "Vault at $vault (engraph install failed — search via filesystem until fixed)"
  fi
}

# --- Obsidian (graph view over the same vault) ------------------------------
step_obsidian() {
  local vault="${SECOND_BRAIN_VAULT:-$DESKTOP_BRAIN_DIR}"
  local helper="$SCRIPT_DIR/obsidian-setup.sh"

  if [[ ! -f "$helper" ]]; then
    emit obsidian failed "obsidian-setup.sh is missing next to bootstrap.sh"
    FAILED=$((FAILED + 1))
    return 1
  fi

  local args=(--vault "$vault")
  installing || args+=(--check)

  # The helper emits its own STEP|obsidian| lines, so just let them through.
  if bash "$helper" "${args[@]}"; then
    return 0
  fi
  FAILED=$((FAILED + 1))
  return 1
}

# --- Local CalDAV (Radicale, loopback only) --------------------------------
step_caldav() {
  local helper="$SCRIPT_DIR/caldav-setup.sh"
  if [[ ! -f "$helper" ]]; then
    emit caldav failed "caldav-setup.sh is missing next to bootstrap.sh"
    FAILED=$((FAILED + 1))
    return 1
  fi
  local args=()
  installing || args+=(--check)
  if bash "$helper" "${args[@]}"; then
    return 0
  fi
  FAILED=$((FAILED + 1))
  return 1
}
step_defend() {
  local helper="$SCRIPT_DIR/defend-setup.sh"
  if [[ ! -f "$helper" ]]; then
    emit defend failed "defend-setup.sh is missing next to bootstrap.sh"
    FAILED=$((FAILED + 1))
    return 1
  fi
  local args=()
  installing || args+=(--check)
  if bash "$helper" "${args[@]}"; then
    return 0
  fi
  # manual (admin password later) is not a hard fail
  return 0
}

# --- run --------------------------------------------------------------------
for step in requirements brew node bun python ffmpeg whisper tiron heed omlx omlx_interpreter vscode agent_skills screenpipe tts brain obsidian caldav defend ollama; do
  wanted "$step" || continue
  "step_$step"
done

if (( FAILED == 0 )); then
  DONE_MSG="Everything 2ⁿᵈ Brain needs is installed locally."
  [[ "$MODE" == "check" ]] && DONE_MSG="All local engines and models are present."
  printf 'DONE|ok|%s\n' "$DONE_MSG"
else
  printf 'DONE|incomplete|%d step(s) still need attention — run setup again; finished pieces are kept.\n' "$FAILED"
fi
