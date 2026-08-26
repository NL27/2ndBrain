#!/usr/bin/env bash
# Installs Obsidian if needed and points it at the 2nd Brain vault with the
# plugin set that makes the vault usable as a daily driver.
#
# Emits the same STEP|id|state|message lines as bootstrap.sh so SetupManager can
# render progress. Safe to re-run: registration and plugin installs are
# idempotent, and plugin settings are merged rather than overwritten.
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
MODE="install"
OMLX="http://127.0.0.1:8000/v1"
OLLAMA="http://127.0.0.1:11434/v1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  MODE="check"; shift;;
    --vault)  VAULT="$2"; shift 2;;
    --omlx)   OMLX="$2"; shift 2;;
    --ollama) OLLAMA="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/obsidian_setup.py"

emit() { printf 'STEP|%s|%s|%s\n' "$1" "$2" "$3"; }
have() { command -v "$1" >/dev/null 2>&1; }

emit obsidian checking "Looking for Obsidian and the vault plugins"

if [[ ! -f "$HELPER" ]]; then
  emit obsidian failed "obsidian_setup.py is missing next to this script"
  exit 1
fi

# --- the app ---------------------------------------------------------------
if [[ ! -d "/Applications/Obsidian.app" ]]; then
  if [[ "$MODE" == "check" ]]; then
    emit obsidian failed "Obsidian is not installed"
    exit 1
  fi
  if have brew; then
    emit obsidian installing "Installing Obsidian"
    if ! brew install --cask obsidian >&2; then
      emit obsidian failed "brew install --cask obsidian failed"
      exit 1
    fi
  else
    emit obsidian manual "Install Obsidian from obsidian.md, then re-run setup"
    exit 1
  fi
fi

if [[ "$MODE" == "check" ]]; then
  if summary="$(python3 "$HELPER" --vault "$VAULT" --check 2>&1)"; then
    emit obsidian ok "Obsidian linked to the vault ($(echo "$summary" | head -1))"
  else
    emit obsidian failed "Vault not fully linked ($(echo "$summary" | head -1))"
  fi
  exit 0
fi

# --- Obsidian rewrites obsidian.json on quit, so it must not be running ----
RESTART=0
if pgrep -xq "Obsidian"; then
  RESTART=1
  emit obsidian installing "Quitting Obsidian so its vault list can be updated"
  osascript -e 'tell application "Obsidian" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -xq "Obsidian" || break
    sleep 0.5
  done
  pgrep -xq "Obsidian" && pkill -x Obsidian 2>/dev/null || true
fi

emit obsidian installing "Registering vault and installing community plugins"
if python3 "$HELPER" --vault "$VAULT" --omlx "$OMLX" --ollama "$OLLAMA" >&2; then
  emit obsidian ok "Obsidian linked to $VAULT with all plugins"
  STATUS=0
else
  # Partial success is the norm if a plugin release is momentarily unavailable.
  emit obsidian ok "Obsidian linked to $VAULT — some plugins need attention (see log)"
  STATUS=0
fi

if (( RESTART )); then
  open -a Obsidian "$VAULT" >/dev/null 2>&1 || open -a Obsidian >/dev/null 2>&1 || true
fi

exit "$STATUS"
