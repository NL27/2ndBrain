#!/usr/bin/env bash
# Copy vault overnight queues into the Shared drop folders and route
# `env: development` frontmatter out of the production queue.
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
PROD_VAULT="$VAULT/Notes/Overnight/queue"
DEV_VAULT="$VAULT/Notes/Overnight/dev-queue"
PROD_DROP="/Users/Shared/2nd-Brain-Night"
DEV_DROP="/Users/Shared/2nd-Brain-Dev"

mkdir -p "$PROD_VAULT" "$DEV_VAULT" \
  "$PROD_DROP/queue" "$DEV_DROP/queue" \
  "$VAULT/Notes/Overnight"

python3 - "$PROD_VAULT" "$DEV_VAULT" <<'PY'
import pathlib, re, sys
prod, dev = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dev.mkdir(parents=True, exist_ok=True)
pat = re.compile(r"(?im)^env:\s*development\s*$")
if not prod.is_dir():
    raise SystemExit(0)
for path in list(prod.iterdir()):
    if path.suffix.lower() not in {".md", ".txt"} or not path.is_file():
        continue
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        continue
    if pat.search(text[:800]):
        dest = dev / path.name
        path.replace(dest)
PY

if command -v rsync >/dev/null; then
  rsync -a --delete --exclude done/ --exclude rejected/ --exclude failed/ --exclude README.md --exclude readme.md \
    "$PROD_VAULT/" "$PROD_DROP/queue/" 2>/dev/null || true
  rsync -a --delete --exclude done/ --exclude rejected/ --exclude failed/ --exclude README.md --exclude readme.md \
    "$DEV_VAULT/" "$DEV_DROP/queue/" 2>/dev/null || true
else
  cp -R "$PROD_VAULT/." "$PROD_DROP/queue/" 2>/dev/null || true
  cp -R "$DEV_VAULT/." "$DEV_DROP/queue/" 2>/dev/null || true
fi

# Standing mission lives beside the queues so rsync --delete cannot eat it.
if [[ -f "$VAULT/Notes/Overnight/standing-mission.md" ]]; then
  cp -f "$VAULT/Notes/Overnight/standing-mission.md" "$PROD_DROP/queue/standing-mission.md"
fi

# Human STOP: vault file wins. Remove it to let agents run until the next Stop.
if [[ -f "$VAULT/Notes/Overnight/STOP" ]]; then
  printf 'stop\n' > "$PROD_DROP/STOP"
  printf 'stop\n' > "$DEV_DROP/STOP"
else
  rm -f "$PROD_DROP/STOP" "$DEV_DROP/STOP" "$PROD_DROP/state/stop" "$DEV_DROP/state/stop"
fi

if [[ -f "$PROD_DROP/work/last-run.md" ]]; then
  cp -f "$PROD_DROP/work/last-run.md" "$VAULT/Notes/Overnight/last-run.md"
fi
if [[ -f "$DEV_DROP/work/last-run.md" ]]; then
  cp -f "$DEV_DROP/work/last-run.md" "$VAULT/Notes/Overnight/last-run-dev.md"
fi

# Production writes keepers under work/vault-out/Notes/ (cannot write the Desktop vault).
# Copy into the vault without --delete so human edits stay.
VAULT_OUT="$PROD_DROP/work/vault-out/Notes"
OVERNIGHT_WORK="$PROD_DROP/overnight work"
VAULT_OVERNIGHT_WORK="$VAULT/Notes/Overnight/overnight work"
mkdir -p "$PROD_DROP/work/vault-out/Notes/Health" \
  "$PROD_DROP/work/vault-out/Notes/Overnight/ideas" \
  "$OVERNIGHT_WORK" \
  "$VAULT/Notes/Health" \
  "$VAULT/Notes/Overnight/ideas" \
  "$VAULT_OVERNIGHT_WORK"
if [[ -d "$VAULT_OUT" ]]; then
  if command -v rsync >/dev/null; then
    rsync -a "$VAULT_OUT/" "$VAULT/Notes/"
  else
    cp -R "$VAULT_OUT/." "$VAULT/Notes/" 2>/dev/null || true
  fi
fi
if [[ -d "$OVERNIGHT_WORK" ]]; then
  if command -v rsync >/dev/null; then
    rsync -a "$OVERNIGHT_WORK/" "$VAULT_OVERNIGHT_WORK/"
  else
    cp -R "$OVERNIGHT_WORK/." "$VAULT_OVERNIGHT_WORK/" 2>/dev/null || true
  fi
fi
