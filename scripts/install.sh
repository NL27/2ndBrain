#!/usr/bin/env bash
# Snapture installer — builds the app, installs it to /Applications, and
# optionally sets up local transcription engines + models.
#
# Usage:
#   scripts/install.sh                      # build + install the app only
#   scripts/install.sh --with-whisper       # also install whisper.cpp (brew) + model
#   scripts/install.sh --with-whisperx      # also install WhisperX (pipx) for diarization
#   scripts/install.sh --model small.en     # choose the whisper model to download
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WITH_WHISPER=0
WITH_WHISPERX=0
MODEL="base.en"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-whisper)  WITH_WHISPER=1; shift;;
    --with-whisperx) WITH_WHISPERX=1; shift;;
    --model)         MODEL="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

SUPPORT="$HOME/Library/Application Support/Snapture"
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
echo "==> Building app…"
bash "$ROOT/scripts/build.sh" release

echo "==> Installing to /Applications…"
rm -rf "/Applications/Snapture.app"
cp -R "$ROOT/dist/Snapture.app" "/Applications/Snapture.app"

# --- 3. Optional: whisper.cpp + model ---------------------------------------
if [[ "$WITH_WHISPER" -eq 1 ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "!! Homebrew not found. Install from https://brew.sh then re-run with --with-whisper." >&2
  else
    echo "==> Installing whisper.cpp via Homebrew…"
    brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
    # Symlink the CLI into Snapture's bin dir for reliable discovery.
    WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
    [[ -n "$WHISPER_BIN" ]] && ln -sf "$WHISPER_BIN" "$BIN_DIR/whisper-cli"
  fi

  MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
  if [[ ! -f "$MODEL_FILE" ]]; then
    echo "==> Downloading whisper model: $MODEL"
    curl -L --fail -o "$MODEL_FILE" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"
  else
    echo "==> Model already present: $MODEL_FILE"
  fi
fi

# --- 4. Optional: WhisperX (diarization) ------------------------------------
if [[ "$WITH_WHISPERX" -eq 1 ]]; then
  if ! command -v pipx >/dev/null 2>&1; then
    echo "==> Installing pipx…"
    command -v brew >/dev/null 2>&1 && brew install pipx && pipx ensurepath
  fi
  echo "==> Installing WhisperX (this can take a while)…"
  pipx install whisperx || pip3 install --user whisperx
  WX_BIN="$(command -v whisperx || true)"
  [[ -n "$WX_BIN" ]] && ln -sf "$WX_BIN" "$BIN_DIR/whisperx"
  echo "    Note: speaker diarization needs a Hugging Face token in the HF_TOKEN env var."
fi

# --- 5. Launch ---------------------------------------------------------------
echo "==> Launching Snapture…"
open "/Applications/Snapture.app"

cat <<'EOF'

✅ Snapture installed.

Grant permissions on first use:
  • System Settings → Privacy & Security → Screen Recording → enable Snapture
  • System Settings → Privacy & Security → Microphone → enable Snapture

Default hotkeys:
  ⌃⌥4  Capture area to clipboard
  ⌃⌥5  OCR region to clipboard
  ⌃⌥6  Record screen + audio
  ⌃⌥V  Clipboard history

Look for the camera icon in the menu bar.
EOF
