#!/usr/bin/env bash
# 2ⁿᵈ Brain installer — builds the app and installs it to /Applications.
#
# The app installs its local engines and models itself on first launch (a setup
# window walks through it), so this script only needs to place the app. The flags
# below just do that engine install up front instead.
#
# Usage:
#   scripts/install.sh                        # build + install the app
#   scripts/install.sh --with-engines         # also install every engine + model now
#   scripts/install.sh --only tiron,heed      # install only these (see bootstrap.sh)
#   scripts/install.sh --with-engines --with-ollama   # include a local LLM
#   scripts/install.sh --model small.en       # which whisper model to download
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_ENGINES=0
BOOTSTRAP_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-engines)  WITH_ENGINES=1; shift;;
    --only)          WITH_ENGINES=1; BOOTSTRAP_ARGS+=(--only "$2"); shift 2;;
    --with-ollama)   WITH_ENGINES=1; BOOTSTRAP_ARGS+=(--with-ollama); shift;;
    --model)         BOOTSTRAP_ARGS+=(--model "$2"); shift 2;;
    # Kept working for anyone with the old commands in their shell history.
    --with-whisper)  WITH_ENGINES=1; BOOTSTRAP_ARGS+=(--only whisper); shift;;
    --with-tiron)    WITH_ENGINES=1; BOOTSTRAP_ARGS+=(--only tiron); shift;;
    --with-heed)     WITH_ENGINES=1; BOOTSTRAP_ARGS+=(--only heed); shift;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

SUPPORT="$HOME/Library/Application Support/SecondBrain"
for LEGACY in \
  "$HOME/Library/Application Support/CaptureKit" \
  "$HOME/Library/Application Support/Snapture"
do
  if [[ ! -d "$SUPPORT" && -d "$LEGACY" ]]; then
    echo "==> Moving existing data from $(basename "$LEGACY") to SecondBrain…"
    mv "$LEGACY" "$SUPPORT"
    break
  fi
done
MODELS_DIR="$SUPPORT/models"
BIN_DIR="$SUPPORT/bin"
mkdir -p "$MODELS_DIR" "$BIN_DIR"

# --- 1. System check ---------------------------------------------------------
ARCH="$(uname -m)"
MEM_BYTES="$(sysctl -n hw.memsize)"
MEM_GB=$(( MEM_BYTES / 1073741824 ))
echo "==> System: $ARCH, ${MEM_GB} GB RAM, macOS $(sw_vers -productVersion)"
if [[ "$ARCH" == "arm64" && "$MEM_GB" -ge 16 ]]; then
  echo "    Recommended whisper model: medium.en or large-v3 (plenty of resources)."
elif [[ "$ARCH" == "arm64" ]]; then
  echo "    Recommended whisper model: small.en."
else
  echo "    Intel Mac detected: base.en recommended; cloud AI suggested."
fi

# --- 2. Build + install the app ---------------------------------------------
echo "==> Ensuring stable signing identity (so permissions persist)…"
bash "$ROOT/scripts/create-signing-cert.sh" || \
  echo "    (Could not create a signing identity; falling back to ad-hoc.)"

echo "==> Building app…"
bash "$ROOT/scripts/build.sh" release

# A running instance keeps executing the old binary, and `open` would simply
# re-activate it — so the freshly built version would never actually start.
if pgrep -x SecondBrain >/dev/null 2>&1 || pgrep -x CaptureKit >/dev/null 2>&1; then
  echo "==> Quitting the running app…"
  osascript -e 'tell application "2nd Brain" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "2ⁿᵈ Brain" to quit' >/dev/null 2>&1 || true
  osascript -e 'tell application "CaptureKit" to quit' >/dev/null 2>&1 || true
  pkill -x SecondBrain >/dev/null 2>&1 || true
  pkill -x CaptureKit >/dev/null 2>&1 || true
  sleep 1
fi

echo "==> Installing to /Applications…"
rm -rf "/Applications/2nd Brain.app" "/Applications/CaptureKit.app"
cp -R "$ROOT/dist/2nd Brain.app" "/Applications/2nd Brain.app"

# --- 3. Optional: every local engine + model now ------------------------------
if [[ "$WITH_ENGINES" -eq 1 ]]; then
  echo "==> Installing local engines and models (this downloads several GB)…"
  bash "$ROOT/scripts/bootstrap.sh" "${BOOTSTRAP_ARGS[@]+"${BOOTSTRAP_ARGS[@]}"}" || \
    echo "    (Some engines need attention — the app's setup window shows which.)"
fi

# --- 4. Launch ---------------------------------------------------------------
echo "==> Launching 2ⁿᵈ Brain…"
open "/Applications/2nd Brain.app"

cat <<'EOF'

✅ 2ⁿᵈ Brain installed.

On first launch a setup window offers to download every local engine and model
(whisper.cpp, Tiron, heed and their models). After that the app transcribes with
the network off. You can reopen it any time: menu bar ▸ Local Engines & Models…

Grant permissions on first use:
  • System Settings → Privacy & Security → Screen Recording → enable 2ⁿᵈ Brain
  • System Settings → Privacy & Security → Microphone → enable 2ⁿᵈ Brain

Default hotkeys:
  ⌃⌥4  Capture area to clipboard
  ⌃⌥5  OCR region to clipboard
  ⌃⌥6  Record screen + audio
  ⌃⌥T  Live transcription (starts the local engine by itself)
  ⌃⌥V  Clipboard history

Transcription engines:
  • Recordings  → menu → Settings → Transcription Engine
                  (whisper.cpp, mlx-whisper, or Tiron for multi-speaker meetings)
  • Live (⌃⌥T)  → heed on the Neural Engine, then Tiron labels the speakers
                  once the session ends

To have 2ⁿᵈ Brain run automatically after you log in:
  menu bar icon → Settings → Start at Login

Look for the brain icon in the menu bar.
EOF
