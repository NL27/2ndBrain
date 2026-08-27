#!/usr/bin/env bash
# Put 01–05 into the vault production queue. Manual only — Start does not
# re-copy them (finished jobs stay in done/).
set -uo pipefail

VAULT="${SECOND_BRAIN_VAULT:-$HOME/Desktop/2nd Brain}"
PROD="/Users/Shared/2nd-Brain-Night"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$HERE/.." && pwd)/Resources/overnight-queue"
[[ -d "$src" ]] || exit 0

mkdir -p "$VAULT/Notes/Overnight/queue" \
  "$PROD/queue/done" "$PROD/queue/failed" "$PROD/queue/rejected"
rm -f "$VAULT/Notes/Overnight/queue/00-smoke.md" "$PROD/queue/00-smoke.md"

for n in 01-morning-brief.md 02-queue-gate.md 03-offer-privacy.md \
         04-system-improvements.md 05-holistic-health.md; do
  [[ -f "$src/$n" ]] || continue
  for bin in done failed rejected; do
    rm -f "$PROD/queue/$bin/$n" "$VAULT/Notes/Overnight/queue/$bin/$n"
  done
  cp -f "$src/$n" "$VAULT/Notes/Overnight/queue/$n"
  rm -f "$PROD/state/retries.$n"
done
echo "seeded 01–05 into $VAULT/Notes/Overnight/queue" >&2
